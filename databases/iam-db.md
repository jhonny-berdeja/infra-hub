# Despliegue de la base de datos `iam-db` en microk8s (servidor pcbox)

Motor: **PostgreSQL**, mismo criterio que `ticket-hub-db`/`pcbox-db` (ver
`ticket-hub-db.md`, la plantilla que
sigue este documento). Corre como un Pod dentro del cluster de microk8s, con
sus datos en un volumen persistente y sus credenciales en un Secret de
Kubernetes.

Mismo patrón que `pcbox-db`: `iam-db` comparte su namespace (`iam-api`)
con la propia app `iam-api`, en lugar de tener su propio namespace
dedicado como sí lo tienen `ticket-hub-db`/`ticket-hub`. Los tres documentos
de aprovisionamiento de base de datos del ecosistema (`iam-db.md`,
`pcbox-db.md`, `ticket-hub-db.md`) están centralizados acá, en
`infra-hub/databases/`, en vez de vivir cada uno en la carpeta
`documentation/` de su propio repo de app — mismo motivo de gobernanza por
el que los manifiestos de Kubernetes de cada app viven centralizados en
`infra-hub/apps/<name>/` en lugar de estar dispersos por los repos de cada
app (ver `jtagram/.claude/infra/ci-cd-conventions.md`, sección "Por qué los
manifests de Kubernetes no viven en el repo de la app"): separa quién puede
tocar el aprovisionamiento de infraestructura de quién trabaja el código de
la app día a día, bajo la misma gobernanza (`CODEOWNERS` + branch
protection) que ya rige el resto de `infra-hub`.

No hay ningún paso de migración con la CLI de TypeORM en todo este flujo —
`iam-api`, igual que `ticket-hub-api`/`pcbox-api`, corre con
`synchronize: false` y nunca altera su propio esquema en tiempo de
ejecución. El DDL de abajo es la única fuente de verdad para las tablas de
`iam-db`; cualquier cambio posterior al primer despliegue es un paso
manual y documentado de `ALTER TABLE` (ver §7 para el precedente que sigue
esto).

## 0. Punto de partida

Esta guía asume que `pcbox.bootstrap.md` (pasos 1–4) y
`pcbox.microk8s-setup.md` ya están completos. Conectate al servidor por SSH
sobre la IP de Tailscale (secreto `SSH_HOST`):

```bash
ssh -i deploy_key jhon@IP_TAILSCALE
```

Todos los comandos de este documento corren desde esa sesión.

## 1. Habilitar almacenamiento persistente en microk8s (si aún no está habilitado)

```bash
microk8s enable hostpath-storage
```

Saltá este paso si `ticket-hub-db-deploy.md`/`pcbox-db-deploy.md` ya
corrieron — el `StorageClass` `microk8s-hostpath` que esto crea es a nivel
de cluster, no por namespace.

## 2. Crear el namespace (si todavía no existe)

```bash
microk8s kubectl create namespace iam-api
```

Si `iam-api` (la app) ya fue desplegada antes que su base de datos, esto
falla con "already exists" — no es un error, el namespace ya existe;
continuá con el paso 3.

## 3. Crear el Secret con el usuario y la contraseña

```bash
microk8s kubectl create secret generic iam-db-credentials \
  -n iam-api \
  --from-literal=POSTGRES_USER=usuario_db \
  --from-literal=POSTGRES_PASSWORD=clave_segura
```

> **Nota:** igual que `ticket-hub-db-credentials`/`pcbox-db-credentials`,
> esta es la única vez que la credencial se escribe a mano en la línea de
> comandos — rotala después desde el Dashboard de microk8s
> (`pcbox.microk8s-setup.md`, paso 3 → Secrets → namespace `iam-api`) y
> reiniciá el Pod, ya que Kubernetes no vuelve a inyectar variables de
> entorno en un contenedor que ya está corriendo.

## 4. Definir el esquema inicial como un ConfigMap

```bash
sudo nano ~/iam-db-init.yaml
```

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: iam-db-init
  namespace: iam-api
data:
  init.sql: |
    CREATE TABLE apps_applications (
      id SERIAL PRIMARY KEY,
      name VARCHAR(15) NOT NULL,
      description VARCHAR(200) NOT NULL
    );

    CREATE TABLE apps_users (
      id SERIAL PRIMARY KEY,
      cliente_id VARCHAR(15) NOT NULL UNIQUE,
      cliente_secret VARCHAR(60) NOT NULL,
      name VARCHAR(20) NOT NULL,
      description VARCHAR(200) NOT NULL
    );

    CREATE TABLE apps_roles (
      id SERIAL PRIMARY KEY,
      application_id INTEGER NOT NULL REFERENCES apps_applications(id),
      name VARCHAR(20) NOT NULL,
      description VARCHAR(200) NOT NULL
    );

    CREATE TABLE apps_users_applications (
      id SERIAL PRIMARY KEY,
      app_user_id INTEGER NOT NULL REFERENCES apps_users(id),
      application_id INTEGER NOT NULL REFERENCES apps_applications(id),
      UNIQUE (app_user_id, application_id)
    );

    CREATE TABLE apps_users_roles (
      id SERIAL PRIMARY KEY,
      app_user_id INTEGER NOT NULL REFERENCES apps_users(id),
      application_id INTEGER NOT NULL REFERENCES apps_applications(id),
      role_id INTEGER NOT NULL REFERENCES apps_roles(id),
      UNIQUE (app_user_id, role_id)
    );

    CREATE TABLE internal_users (
      id SERIAL PRIMARY KEY,
      name VARCHAR(15) NOT NULL,
      lastname VARCHAR(15) NOT NULL,
      email VARCHAR(30) NOT NULL UNIQUE,
      password VARCHAR(60) NOT NULL
    );

    CREATE TABLE internal_users_applications (
      id SERIAL PRIMARY KEY,
      internal_user_id INTEGER NOT NULL REFERENCES internal_users(id),
      application_id INTEGER NOT NULL REFERENCES apps_applications(id),
      UNIQUE (internal_user_id, application_id)
    );

    CREATE TABLE internal_users_roles (
      id SERIAL PRIMARY KEY,
      internal_user_id INTEGER NOT NULL REFERENCES internal_users(id),
      application_id INTEGER NOT NULL REFERENCES apps_applications(id),
      role_id INTEGER NOT NULL REFERENCES apps_roles(id),
      UNIQUE (internal_user_id, role_id)
    );
```

```bash
microk8s kubectl apply -f ~/iam-db-init.yaml
```

> **Notas sobre el esquema:**
>
> - `apps_users.cliente_id` es `UNIQUE`: es el valor por el que `iam-api`
>   busca al hacer login (`AppUsersRepository.findByClienteId`), mismo
>   razonamiento que `ticket-hub-db.users.email` teniendo `UNIQUE` — es el
>   campo que identifica la fila para la autenticación.
> - `apps_users.name` (`VARCHAR(20)`, mismo ancho que `apps_roles.name`) es
>   el nombre corto y legible del usuario-aplicación (ej. `pcbox-api`), lo
>   provee el caller en la creación. No reemplaza a `cliente_id` (que sigue
>   siendo la credencial opaca y estable usada para autenticar) ni a
>   `description` (que sigue siendo el texto largo explicativo) — separa el
>   rol de "identificador buscable/legible" del rol de "credencial" y del
>   rol de "explicación", mismo patrón `name`/`description` que ya usan
>   `apps_applications` y `apps_roles`.
> - `apps_users.cliente_secret` es `VARCHAR(60)`, no el secreto en texto
>   plano — es un hash bcrypt, y los digests de bcrypt siempre tienen
>   exactamente 60 caracteres. `iam-api` devuelve el secreto en texto
>   plano al llamador exactamente una vez, en el momento de la creación, y
>   nunca lo persiste — ver el comentario de documentación de
>   `AppUserEntity` en el propio repo de la app.
> - `apps_roles.application_id` y `apps_users_roles.app_user_id`/
>   `apps_users_roles.role_id` tienen todos `REFERENCES` (claves foráneas):
>   mismo razonamiento que `ticket-hub-db.roles.id_user`/
>   `tickets.creator` — sin ellas, Postgres permitiría insertar una
>   referencia a una fila que no existe.
> - `apps_users_roles.application_id` está **desnormalizado
>   intencionalmente** — duplica `apps_roles.application_id` para el
>   `role_id` de la fila, únicamente por conveniencia en las consultas
>   (filtrar los roles de un usuario por aplicación sin un join). Las
>   restricciones CHECK de Postgres no pueden garantizar consistencia entre
>   tablas (eso necesita una subconsulta, que CHECK no soporta), así que no
>   hay ninguna protección a nivel de base de datos que mantenga esta copia
>   sincronizada. Cualquier código que inserte en esta tabla es responsable
>   de copiar `application_id` desde la fila referenciada de `apps_roles`,
>   sin aceptarlo de forma independiente desde el llamador — ver el
>   comentario de documentación de `UserRoleEntity` en el propio repo de
>   `iam-api` para la justificación completa.
> - Todas las columnas son `NOT NULL`: cada fila acá solo se escribe
>   después de que la app ya validó/generó todos los campos (mismo
>   razonamiento que `pcbox-db.administrations` — no hay ningún caso de
>   fila parcial que representar, a diferencia de
>   `ticket-hub-db.tickets.assignee`).
> - `internal_users` guarda a los usuarios humanos del ecosistema (a
>   diferencia de `apps_users`, que son clientes OAuth-style, no
>   personas). `email` es `UNIQUE` por el mismo motivo que `cliente_id`
>   en `apps_users`: es el campo por el que se busca la fila al hacer
>   login.
> - `internal_users.name`/`lastname` son `VARCHAR(15)` cada uno — mismo
>   ancho exacto que `ticket-hub-db.users.name`/`lastname` (ver
>   `ticket-hub-db.md`), el
>   precedente ya establecido en el ecosistema para nombre/apellido de una
>   persona humana.
> - `internal_users.password` es `VARCHAR(60)`, igual ancho y mismo
>   motivo que `apps_users.cliente_secret`: guarda el hash bcrypt, nunca
>   el password en texto plano — los digests de bcrypt siempre miden
>   exactamente 60 caracteres.
> - `internal_users_roles` es al `internal_users` lo que `apps_users_roles`
>   es a `apps_users` — mismo shape, mismas razones: FKs con `REFERENCES`
>   hacia `internal_users`/`apps_applications`/`apps_roles`, y
>   `application_id` **desnormalizado intencionalmente** (duplica
>   `apps_roles.application_id` del `role_id` de la fila, sin garantía a
>   nivel DB — el código que inserta es responsable de copiarlo
>   correctamente, mismo caveat que `apps_users_roles.application_id`
>   arriba).
> - `apps_users_applications`/`internal_users_applications` son tablas
>   nuevas, separadas de `apps_users_roles`/`internal_users_roles`: un
>   usuario puede tener **acceso a una aplicación** sin todavía tener
>   ningún rol asignado ahí — son dos gestiones distintas sobre el
>   usuario. No podían vivir en la misma tabla que los roles porque
>   `apps_users_roles.role_id`/`internal_users_roles.role_id` son
>   `NOT NULL`: no hay forma de representar "tiene acceso, sin rol
>   todavía" en esa tabla.
> - `UNIQUE (app_user_id, application_id)` /
>   `UNIQUE (internal_user_id, application_id)` en las tablas de acceso, y
>   `UNIQUE (app_user_id, role_id)` / `UNIQUE (internal_user_id, role_id)`
>   en las de roles: evitan asignar la misma aplicación o el mismo rol dos
>   veces al mismo usuario. En la de roles alcanza con `(usuario, role_id)`
>   — `application_id` ya está implícito en el rol (es su
>   `apps_roles.application_id` copiado), no hace falta incluirlo en el
>   `UNIQUE`.

## 5. Crear el volumen persistente, el Deployment y el Service

```bash
sudo nano ~/iam-db.yaml
```

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: iam-db-pvc
  namespace: iam-api
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: microk8s-hostpath
  resources:
    requests:
      storage: 2Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: iam-db
  namespace: iam-api
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: iam-db
  template:
    metadata:
      labels:
        app: iam-db
    spec:
      containers:
        - name: postgres
          image: postgres:16-alpine
          ports:
            - containerPort: 5432
          env:
            - name: POSTGRES_DB
              value: iam-db
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
          envFrom:
            - secretRef:
                name: iam-db-credentials
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
            - name: init-script
              mountPath: /docker-entrypoint-initdb.d
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: iam-db-pvc
        - name: init-script
          configMap:
            name: iam-db-init
---
apiVersion: v1
kind: Service
metadata:
  name: iam-db
  namespace: iam-api
spec:
  selector:
    app: iam-db
  ports:
    - port: 5432
      targetPort: 5432
```

> **Nota sobre `PGDATA`:** apunta a un subdirectorio (`/pgdata`), no
> directamente a la raíz del volumen: mismo workaround conocido que
> `ticket-hub-db`/`pcbox-db` — la raíz de un volumen `hostPath` viene con un
> `lost+found` creado por el sistema de archivos, y Postgres se niega a
> inicializar un directorio de datos que no esté completamente vacío.

```bash
microk8s kubectl apply -f ~/iam-db.yaml
```

## 6. Verificar

```bash
microk8s kubectl get pods -n iam-api
```

`iam-db-...` debería mostrar `Running` (junto al Pod de la app
`iam-api`, una vez que también esté desplegada). Revisá los logs de
arranque (confirma que `init.sql` corrió):

```bash
microk8s kubectl logs -n iam-api deployment/iam-db
```

Confirmá que se crearon las ocho tablas:

```bash
microk8s kubectl exec -it -n iam-api deployment/iam-db -- psql -U usuario_db -d iam-db -c '\dt'
```

Debería listar `apps_applications`, `apps_users`, `apps_roles`,
`apps_users_applications`, `apps_users_roles`, `internal_users`,
`internal_users_applications` e `internal_users_roles`.

```bash
microk8s kubectl exec -it -n iam-api deployment/iam-db -- psql -U usuario_db -d iam-db -c '\d apps_users'
```

`cliente_id` debería mostrar una restricción `UNIQUE`; todas las columnas
deberían mostrar `not null`.

Dentro del cluster, cualquier otro Pod (la propia `iam-api`, o un futuro
consumidor) accede a esta base de datos en
`iam-db.iam-api.svc.cluster.local:5432`, usando el usuario y la
contraseña del Secret `iam-db-credentials`.

## 7. Agregar una columna más adelante (precedente para futuras migraciones)

Esta app todavía no tiene cambios de esquema, pero si alguna vez se
necesita uno después de que esta base de datos ya esté en producción,
seguí exactamente el precedente de `ticket-hub-db` (ver
`ticket-hub-db.md`, paso 7): el
ConfigMap `init.sql` del paso 4 de arriba **no** se vuelve a ejecutar
contra un volumen que ya tiene datos, así que cualquier cambio posterior se
aplica a mano, una sola vez, con `ALTER TABLE`:

```bash
microk8s kubectl exec -it -n iam-api deployment/iam-db -- bash
```

Dentro del contenedor:

```bash
psql -U "$POSTGRES_USER" -d iam-db
```

Y en el prompt de `psql`, por ejemplo (ajustá según el cambio real
necesario):

```sql
ALTER TABLE apps_users ADD COLUMN example_column VARCHAR(50);
```

Si la columna nueva tiene que terminar siendo `NOT NULL` en una tabla que
puede que ya tenga filas, seguí el mismo patrón de cuatro pasos que usó
`tickets.number`: `ADD COLUMN` sin `NOT NULL` primero, `UPDATE` para
completar las filas existentes, y recién después
`ALTER COLUMN ... SET NOT NULL` (y `ADD CONSTRAINT ... UNIQUE` si hace
falta) una vez que todas las filas tengan un valor.

## 8. Datos producidos por este proceso

| Dato | Qué es | Qué paso lo produjo | Para qué sirve |
|---|---|---|---|
| Secret `iam-db-credentials` (namespace `iam-api`) | `POSTGRES_USER`/`POSTGRES_PASSWORD` para `iam-db` | Paso 3 (creado con `kubectl create secret`, editable después desde el Dashboard) | Credenciales de conexión; cualquier rotación se hace editando este Secret desde el Dashboard, no por SSH |
| Host interno `iam-db.iam-api.svc.cluster.local:5432` | DNS interno del cluster que apunta al Service de la base de datos | Paso 5 (`Service` `iam-db`) | Cadena de conexión que `iam-api` (`DATABASE_HOST`) usa para llegar a Postgres |
| Tablas `apps_applications`, `apps_users`, `apps_roles`, `apps_users_applications`, `apps_users_roles`, `internal_users`, `internal_users_applications`, `internal_users_roles` | El esquema de `iam-db` | Paso 4 (`ConfigMap` `iam-db-init`, aplicado por el mecanismo `docker-entrypoint-initdb.d` de la imagen de Postgres) | Almacenamiento para `ApplicationEntity`/`AppUserEntity`/`RoleEntity`/`UserAppEntity`/`UserRoleEntity`/`InternalUserEntity`/`InternalUserAppEntity`/`InternalUserRoleEntity` de `iam-api` (`synchronize: false` — este DDL es la única fuente de verdad del esquema) |
