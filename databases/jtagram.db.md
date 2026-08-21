# Despliegue consolidado de bases de datos en microk8s (servidor pcbox)

Motor: **PostgreSQL**, mismo criterio que `auth-db`/`pcbox-db`/`ticket-hub-db`
(ver `auth-db.md`, `pcbox-db.md`, `ticket-hub-db.md`). A diferencia de esos
tres documentos — un Pod de Postgres por base, cada uno en el namespace de su
propia app —, acá **un solo Pod** de Postgres sirve las tres bases
(`iam`, `pcbox`, `ticket-hub`) como bases lógicas separadas dentro de la
misma instancia, en un namespace propio y dedicado: `databases`.

La base de `auth-api` se llama `iam` acá, no `auth` — es un renombre solo
del nombre de la base dentro de este Pod consolidado, no de la app ni del
Pod viejo (`auth-db.md`, la app `auth-api`, y su Secret
`auth-db-credentials` siguen llamándose igual que siempre).

El motivo es de gestión, no de arquitectura de datos: dejar de tener un Pod
de Postgres por cada base (con su propio PVC, su propio Secret, su propio
ciclo de vida) para tener un único punto de administración de base de datos
para todo el ecosistema — lo que además simplifica cómo la ticketera
(`ticket-hub-api` + `pcbox-api`, ver `pcbox-db.md` y
`ticket-hub-db.md` §12) ejecuta SQL contra un target: un solo host y un solo
Secret de credenciales a mantener en la allowlist, en vez de tres.

Esto **no reemplaza** los tres Pods `auth-db`/`pcbox-db`/`ticket-hub-db` que
ya están corriendo con datos reales — este documento cubre únicamente el
aprovisionamiento del Pod consolidado nuevo, vacío, en el namespace
`databases`. Migrar los datos existentes hacia acá y decomisionar los tres
Pods viejos es un paso posterior, deliberadamente fuera de este documento.

Igual que en `auth-db`/`pcbox-db`/`ticket-hub-db`: no hay ningún paso de
migración con la CLI de TypeORM en todo este flujo — cada API corre con
`synchronize: false` y nunca altera su propio esquema en tiempo de
ejecución. El DDL de abajo es la única fuente de verdad para las tablas de
las tres bases; cualquier cambio posterior al primer despliegue es un paso
manual y documentado de `ALTER TABLE`, siguiendo el mismo precedente que ya
usan los otros tres documentos.

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

Saltá este paso si `auth-db.md`/`pcbox-db.md`/`ticket-hub-db.md` ya
corrieron alguno de ellos — el `StorageClass` `microk8s-hostpath` que esto
crea es a nivel de cluster, no por namespace.

## 2. Crear el namespace `databases`

```bash
microk8s kubectl create namespace databases
```

A diferencia de `auth-db`/`pcbox-db` (que comparten namespace con su propia
app) y de `ticket-hub-db` (namespace dedicado pero acoplado 1:1 a
`ticket-hub-api`), `databases` no es el namespace de ninguna app — es un
namespace de infraestructura, dueño únicamente de este Pod de Postgres, al
que las apps se conectan desde sus propios namespaces (`auth-api`,
`pcbox-api`, `ticket-hub`) cruzando el DNS interno del cluster.

## 3. Crear el Secret con el usuario y la contraseña

```bash
microk8s kubectl create secret generic postgres-credentials \
  -n databases \
  --from-literal=POSTGRES_USER=usuario_db \
  --from-literal=POSTGRES_PASSWORD=clave_segura
```

Una única credencial para toda la instancia: el usuario queda como dueño de
las tres bases (`iam`, `pcbox`, `ticket-hub`), no de una sola — mismo
usuario que después usa cada app, y el mismo que la ticketera usa como
target en la allowlist de `pcbox-api`.

> **Nota:** igual que en los otros tres documentos, esta es la única vez que
> la credencial se escribe a mano en la línea de comandos — rotala después
> desde el Dashboard de microk8s (`pcbox.microk8s-setup.md`, paso 3 →
> Secrets → namespace `databases`) y reiniciá el Pod, ya que Kubernetes no
> vuelve a inyectar variables de entorno en un contenedor que ya está
> corriendo.

## 4. Definir las tres bases como un ConfigMap, un archivo `.sql` por base

La imagen oficial de Postgres ejecuta automáticamente, en orden alfabético,
cualquier `.sql` que encuentre en `/docker-entrypoint-initdb.d/` la primera
vez que arranca con el volumen de datos vacío — cada archivo corre con
`psql` contra la base por defecto de la instancia, así que cada uno empieza
con su propio `CREATE DATABASE` seguido de `\c` (el meta-comando de `psql`
para cambiar de base dentro del mismo script) antes de crear sus tablas.
Por eso son tres archivos, no uno: cada base necesita su propio bloque
`CREATE DATABASE` + `\c` + DDL, y el orden alfabético en el que corren
(`iam.sql`, `pcbox.sql`, `ticket-hub.sql`) no importa porque las tres bases
son independientes entre sí — ninguna referencia a otra con una foreign key
cruzada (Postgres no lo permite entre bases distintas de la misma
instancia).

El DDL de cada archivo es el esquema **actual** de cada base — no el
esquema original de su primer despliegue, sino el resultado de aplicarle
todas las migraciones ya documentadas en `auth-db.md`/`pcbox-db.md`/
`ticket-hub-db.md` hasta hoy. Un despliegue nuevo desde este ConfigMap
arranca directamente en el estado final, sin tener que repetir a mano cada
`ALTER TABLE` histórico.

```bash
mkdir -p ~/postgres-init
sudo nano ~/postgres-init/iam.sql
```

```sql
CREATE DATABASE iam;

\c iam

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

Esquema calcado de `auth-db.md` paso 4 — hasta hoy esa base no tiene
ninguna migración posterior aplicada, así que su esquema original y su
esquema actual son el mismo.

```bash
sudo nano ~/postgres-init/pcbox.sql
```

```sql
CREATE DATABASE pcbox;

\c pcbox

CREATE TABLE administrations (
  id SERIAL PRIMARY KEY,
  ticket_number INTEGER NOT NULL,
  department VARCHAR(15) NOT NULL,
  approver VARCHAR(100) NOT NULL,
  informer VARCHAR(30) NOT NULL,
  status VARCHAR(15) NOT NULL,
  file_content TEXT NOT NULL
);
```

`approver VARCHAR(100)`, `informer VARCHAR(30)` y `file_content TEXT` ya
reflejan las migraciones de `pcbox-db.md` §7 y §8 (ensanchado desde
`VARCHAR(15)` y `VARCHAR(500)` respectivamente) — no el `VARCHAR(15)`/
`VARCHAR(500)` del esquema original de esa base.

```bash
sudo nano ~/postgres-init/ticket-hub.sql
```

```sql
CREATE DATABASE "ticket-hub";

\c "ticket-hub"

CREATE TABLE tickets (
  id SERIAL PRIMARY KEY,
  number INTEGER NOT NULL UNIQUE,
  creator INTEGER NOT NULL,
  assignee VARCHAR(100),
  department VARCHAR(25) NOT NULL,
  subject VARCHAR(100) NOT NULL,
  status VARCHAR(20) NOT NULL,
  description VARCHAR(200) NOT NULL,
  code_ansible VARCHAR(500),
  response TEXT,
  informer VARCHAR(30),
  ticket_type VARCHAR(10) NOT NULL,
  db_namespace VARCHAR(63),
  db_deployment VARCHAR(63),
  db_name VARCHAR(63),
  operation_type VARCHAR(10),
  sql_code VARCHAR(5000)
);
```

`"ticket-hub"` va entre comillas dobles en el `CREATE DATABASE` y en el
`\c` porque el guión no es válido en un identificador SQL sin comillar —
mismo motivo por el que la base vieja se llamó `ticket-hub-db` y no
`ticket-hub`, aunque el driver de Postgres (y TypeORM) no tiene problema
con el nombre una vez que ya existe.

Esta única tabla `tickets` es el resultado final de encadenar
`ticket-hub-db.md` §7 (`number`), §8 (`response`), §11 (`creator` deja de
tener FK y pasa a ser el `sub` de `auth-api`; `assignee` deja de ser FK y
pasa a `VARCHAR(100)` de texto libre; se agrega `informer`; se eliminan
`users`/`roles`) y §12 (`ticket_type` + las cinco columnas `db_*`/
`operation_type`/`sql_code` del ticket tipo `DATABASE`). Por eso acá no
aparecen las tablas `users`/`roles` del esquema original: ya no tienen
ningún consumidor.

Con los tres archivos listos, crear el ConfigMap a partir de ellos —
mismo comando que se usa hoy para las apps, adaptado a las tres bases de
este ecosistema y al namespace `databases`:

```bash
microk8s kubectl create configmap postgres-init \
  --from-file=iam.sql=$HOME/postgres-init/iam.sql \
  --from-file=pcbox.sql=$HOME/postgres-init/pcbox.sql \
  --from-file=ticket-hub.sql=$HOME/postgres-init/ticket-hub.sql \
  -n databases
```

## 5. Crear el volumen persistente, el Deployment y el Service

```bash
sudo nano ~/postgres.yaml
```

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-pvc
  namespace: databases
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: microk8s-hostpath
  resources:
    requests:
      storage: 4Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
  namespace: databases
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
        - name: postgres
          image: postgres:16-alpine
          ports:
            - containerPort: 5432
          env:
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
          envFrom:
            - secretRef:
                name: postgres-credentials
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
            - name: init-script
              mountPath: /docker-entrypoint-initdb.d
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: postgres-pvc
        - name: init-script
          configMap:
            name: postgres-init
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: databases
spec:
  selector:
    app: postgres
  ports:
    - port: 5432
      targetPort: 5432
```

Dos diferencias respecto de los tres Deployments individuales:

- **Sin `POSTGRES_DB`**: los otros tres Deployments lo fijan porque cada
  Pod sirve una única base con ese nombre. Acá ninguna app se conecta a la
  base por defecto de la instancia — las tres bases reales las crean los
  scripts del paso 4 — así que se omite y la imagen cae en su default
  (una base con el mismo nombre que `POSTGRES_USER`, que queda sin uso;
  no molesta a nadie).
- **`storage: 4Gi`, no `2Gi`**: una sola instancia ahora aloja lo que antes
  eran tres volúmenes de `2Gi` cada uno.

> **Nota sobre `PGDATA`:** mismo workaround que `auth-db`/`pcbox-db`/
> `ticket-hub-db` — apunta a un subdirectorio porque la raíz de un volumen
> `hostPath` viene con un `lost+found` creado por el sistema de archivos, y
> Postgres se niega a inicializar un directorio de datos que no esté
> completamente vacío.

```bash
microk8s kubectl apply -f ~/postgres.yaml
```

## 6. Verificar

```bash
microk8s kubectl get pods -n databases
```

`postgres-...` debería mostrar `Running`. Revisá los logs de arranque
(confirma que los tres `.sql` corrieron, en orden alfabético):

```bash
microk8s kubectl logs -n databases deployment/postgres
```

Confirmá que las tres bases existen:

```bash
microk8s kubectl exec -it -n databases deployment/postgres -- \
  psql -U usuario_db -d postgres -c '\l'
```

Debería listar `iam`, `pcbox` y `ticket-hub` además de las bases internas
de Postgres (`postgres`, `template0`, `template1`).

```bash
microk8s kubectl exec -it -n databases deployment/postgres -- \
  psql -U usuario_db -d iam -c '\dt'
microk8s kubectl exec -it -n databases deployment/postgres -- \
  psql -U usuario_db -d pcbox -c '\dt'
microk8s kubectl exec -it -n databases deployment/postgres -- \
  psql -U usuario_db -d "ticket-hub" -c '\dt'
```

Debería listar las ocho tablas de `iam`, `administrations` en `pcbox`, y
`tickets` en `ticket-hub`.

Desde cualquier otro namespace del cluster (`auth-api`, `pcbox-api`,
`ticket-hub`), la instancia se ve en
`postgres.databases.svc.cluster.local:5432` — el DNS interno de Kubernetes
no distingue namespace de origen, solo el del Service (`databases`), así
que las tres apps llegan ahí sin importar en qué namespace corren ellas
mismas.

## 7. Agregar una columna más adelante (precedente para futuras migraciones)

Igual que en los tres documentos por app: el ConfigMap `postgres-init` del
paso 4 **no** se vuelve a ejecutar contra un volumen que ya tiene datos, así
que cualquier cambio de esquema posterior a este primer despliegue se aplica
a mano, una sola vez, con `ALTER TABLE` — conectando al Pod y eligiendo la
base con `-d`:

```bash
microk8s kubectl exec -it -n databases deployment/postgres -- \
  psql -U usuario_db -d iam
```

(o `-d pcbox` / `-d "ticket-hub"` según cuál base cambie). Seguí desde ahí
el mismo patrón de cuatro pasos que ya usaron `tickets.number` y
`tickets.ticket_type` (ver `ticket-hub-db.md` §7 y §12) si la columna nueva
tiene que terminar siendo `NOT NULL` en una tabla que puede que ya tenga
filas: `ADD COLUMN` sin `NOT NULL` primero, `UPDATE` para completar las
filas existentes, y recién después `ALTER COLUMN ... SET NOT NULL`.

## 8. Datos producidos por este proceso

| Dato | Qué es | Qué paso lo produjo | Para qué sirve |
|---|---|---|---|
| Namespace `databases` | Namespace de infraestructura, dueño del Pod de Postgres consolidado | Paso 2 | Aísla el ciclo de vida de las bases del ciclo de vida de las apps que las consumen |
| Secret `postgres-credentials` (namespace `databases`) | `POSTGRES_USER`/`POSTGRES_PASSWORD`, dueño de las tres bases | Paso 3 (creado con `kubectl create secret`, editable después desde el Dashboard) | Credencial única de conexión a las tres bases; cualquier rotación se hace editando este Secret desde el Dashboard, no por SSH |
| ConfigMap `postgres-init` (namespace `databases`) | Tres scripts (`iam.sql`, `pcbox.sql`, `ticket-hub.sql`), uno por base | Paso 4 | Aplicado por el mecanismo `docker-entrypoint-initdb.d` de la imagen de Postgres al primer arranque con el volumen vacío |
| Bases `iam`, `pcbox`, `ticket-hub` | Las tres bases lógicas de la instancia, cada una con el esquema final documentado en `auth-db.md`/`pcbox-db.md`/`ticket-hub-db.md` (`iam` = la base de `auth-api`, renombrada) | Paso 4 (ejecutado al arrancar el Pod, paso 5) | Almacenamiento para `auth-api`, `pcbox-api` y `ticket-hub-api` respectivamente |
| Host interno `postgres.databases.svc.cluster.local:5432` | DNS interno del cluster que apunta al Service de la instancia consolidada | Paso 5 (`Service` `postgres`) | Cadena de conexión que cada app usará (`DATABASE_HOST`) una vez migrada — ver nota abajo |

> **Pendiente, fuera de este documento:** ninguna app apunta todavía a este
> Pod — `auth-api`, `pcbox-api` y `ticket-hub-api` siguen conectadas a sus
> tres Pods viejos (`auth-db`, `pcbox-db`, `ticket-hub-db`), que siguen
> corriendo con sus datos reales. Migrar esos datos (`pg_dump`/`pg_restore`
> de cada base vieja hacia acá), actualizar `DATABASE_HOST`/`DATABASE_NAME`
> de cada app en `infra-hub/apps/<app>/` y recién después decomisionar los
> tres Pods viejos es un cambio aparte, a documentar cuando se decida
> ejecutar el corte.
