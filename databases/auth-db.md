# Despliegue de la base de datos `auth-db` en microk8s (servidor pcbox)

Motor: **PostgreSQL**, mismo criterio que `ticket-hub-db`/`pcbox-db` (ver
`pcbox-api/documentation/pcbox.ticket-hub-db-deploy.md`, la plantilla que
sigue este documento). Corre como un Pod dentro del cluster de microk8s, con
sus datos en un volumen persistente y sus credenciales en un Secret de
Kubernetes.

Mismo patrón que `pcbox-db`: `auth-db` comparte su namespace (`auth-api`)
con la propia app `auth-api`, en lugar de tener su propio namespace
dedicado como sí lo tienen `ticket-hub-db`/`ticket-hub`. Este documento vive
en `infra-hub` (no en el repo propio de `auth-api`) porque, a diferencia de
`ticket-hub-api`/`pcbox-api`, el doc de aprovisionamiento de la base de
`auth-api` todavía no tiene una carpeta `documentation/` equivalente propia
— `infra-hub` es donde ya viven los manifiestos de Kubernetes de todas las
apps (`apps/<name>/`), así que este es el lugar más cercano para el doc de
infra de un servicio nuevo hasta que (o a menos que) `auth-api` desarrolle
su propia carpeta `documentation/` siguiendo el ejemplo de `pcbox-api`.

No hay ningún paso de migración con la CLI de TypeORM en todo este flujo —
`auth-api`, igual que `ticket-hub-api`/`pcbox-api`, corre con
`synchronize: false` y nunca altera su propio esquema en tiempo de
ejecución. El DDL de abajo es la única fuente de verdad para las tablas de
`auth-db`; cualquier cambio posterior al primer despliegue es un paso
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
microk8s kubectl create namespace auth-api
```

Si `auth-api` (la app) ya fue desplegada antes que su base de datos, esto
falla con "already exists" — no es un error, el namespace ya existe;
continuá con el paso 3.

## 3. Crear el Secret con el usuario y la contraseña

```bash
microk8s kubectl create secret generic auth-db-credentials \
  -n auth-api \
  --from-literal=POSTGRES_USER=usuario_db \
  --from-literal=POSTGRES_PASSWORD=clave_segura
```

> **Nota:** igual que `ticket-hub-db-credentials`/`pcbox-db-credentials`,
> esta es la única vez que la credencial se escribe a mano en la línea de
> comandos — rotala después desde el Dashboard de microk8s
> (`pcbox.microk8s-setup.md`, paso 3 → Secrets → namespace `auth-api`) y
> reiniciá el Pod, ya que Kubernetes no vuelve a inyectar variables de
> entorno en un contenedor que ya está corriendo.

## 4. Definir el esquema inicial como un ConfigMap

```bash
sudo nano ~/auth-db-init.yaml
```

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: auth-db-init
  namespace: auth-api
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

    CREATE TABLE apps_users_roles (
      id SERIAL PRIMARY KEY,
      app_user_id INTEGER NOT NULL REFERENCES apps_users(id),
      application_id INTEGER NOT NULL REFERENCES apps_applications(id),
      role_id INTEGER NOT NULL REFERENCES apps_roles(id)
    );
```

```bash
microk8s kubectl apply -f ~/auth-db-init.yaml
```

> **Notas sobre el esquema:**
>
> - `apps_users.cliente_id` es `UNIQUE`: es el valor por el que `auth-api`
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
>   exactamente 60 caracteres. `auth-api` devuelve el secreto en texto
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
>   `auth-api` para la justificación completa.
> - Todas las columnas son `NOT NULL`: cada fila acá solo se escribe
>   después de que la app ya validó/generó todos los campos (mismo
>   razonamiento que `pcbox-db.administrations` — no hay ningún caso de
>   fila parcial que representar, a diferencia de
>   `ticket-hub-db.tickets.assignee`).

## 5. Crear el volumen persistente, el Deployment y el Service

```bash
sudo nano ~/auth-db.yaml
```

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: auth-db-pvc
  namespace: auth-api
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
  name: auth-db
  namespace: auth-api
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: auth-db
  template:
    metadata:
      labels:
        app: auth-db
    spec:
      containers:
        - name: postgres
          image: postgres:16-alpine
          ports:
            - containerPort: 5432
          env:
            - name: POSTGRES_DB
              value: auth-db
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
          envFrom:
            - secretRef:
                name: auth-db-credentials
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
            - name: init-script
              mountPath: /docker-entrypoint-initdb.d
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: auth-db-pvc
        - name: init-script
          configMap:
            name: auth-db-init
---
apiVersion: v1
kind: Service
metadata:
  name: auth-db
  namespace: auth-api
spec:
  selector:
    app: auth-db
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
microk8s kubectl apply -f ~/auth-db.yaml
```

## 6. Verificar

```bash
microk8s kubectl get pods -n auth-api
```

`auth-db-...` debería mostrar `Running` (junto al Pod de la app
`auth-api`, una vez que también esté desplegada). Revisá los logs de
arranque (confirma que `init.sql` corrió):

```bash
microk8s kubectl logs -n auth-api deployment/auth-db
```

Confirmá que se crearon las cuatro tablas:

```bash
microk8s kubectl exec -it -n auth-api deployment/auth-db -- psql -U usuario_db -d auth-db -c '\dt'
```

Debería listar `apps_applications`, `apps_users`, `apps_roles` y
`apps_users_roles`.

```bash
microk8s kubectl exec -it -n auth-api deployment/auth-db -- psql -U usuario_db -d auth-db -c '\d apps_users'
```

`cliente_id` debería mostrar una restricción `UNIQUE`; todas las columnas
deberían mostrar `not null`.

Dentro del cluster, cualquier otro Pod (la propia `auth-api`, o un futuro
consumidor) accede a esta base de datos en
`auth-db.auth-api.svc.cluster.local:5432`, usando el usuario y la
contraseña del Secret `auth-db-credentials`.

## 7. Agregar una columna más adelante (precedente para futuras migraciones)

Esta app todavía no tiene cambios de esquema, pero si alguna vez se
necesita uno después de que esta base de datos ya esté en producción,
seguí exactamente el precedente de `ticket-hub-db` (ver
`pcbox-api/documentation/pcbox.ticket-hub-db-deploy.md`, paso 7): el
ConfigMap `init.sql` del paso 4 de arriba **no** se vuelve a ejecutar
contra un volumen que ya tiene datos, así que cualquier cambio posterior se
aplica a mano, una sola vez, con `ALTER TABLE`:

```bash
microk8s kubectl exec -it -n auth-api deployment/auth-db -- bash
```

Dentro del contenedor:

```bash
psql -U "$POSTGRES_USER" -d auth-db
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
| Secret `auth-db-credentials` (namespace `auth-api`) | `POSTGRES_USER`/`POSTGRES_PASSWORD` para `auth-db` | Paso 3 (creado con `kubectl create secret`, editable después desde el Dashboard) | Credenciales de conexión; cualquier rotación se hace editando este Secret desde el Dashboard, no por SSH |
| Host interno `auth-db.auth-api.svc.cluster.local:5432` | DNS interno del cluster que apunta al Service de la base de datos | Paso 5 (`Service` `auth-db`) | Cadena de conexión que `auth-api` (`DATABASE_HOST`) usa para llegar a Postgres |
| Tablas `apps_applications`, `apps_users`, `apps_roles`, `apps_users_roles` | El esquema de `auth-db` | Paso 4 (`ConfigMap` `auth-db-init`, aplicado por el mecanismo `docker-entrypoint-initdb.d` de la imagen de Postgres) | Almacenamiento para `ApplicationEntity`/`AppUserEntity`/`RoleEntity`/`UserRoleEntity` de `auth-api` (`synchronize: false` — este DDL es la única fuente de verdad del esquema) |
