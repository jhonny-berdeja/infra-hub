# Despliegue consolidado de bases de datos en microk8s (servidor pcbox)

Motor: **PostgreSQL**. Este es el único documento de despliegue de bases de
datos del ecosistema: **un solo Pod** de Postgres sirve las tres bases
(`iam`, `pcbox`, `ticket-hub`) como bases lógicas separadas dentro de la
misma instancia, en un namespace propio y dedicado: `databases`. Los tres
Pods viejos, uno por app (`auth-db`, `pcbox-db`, `ticket-hub-db`), ya fueron
decomisionados — este documento cubre el estado final.

La base de `auth-api` se llama `iam` acá, no `auth` — es un renombre solo
del nombre de la base dentro de este Pod consolidado, no de la app (`auth-api`
y su Secret `auth-db-credentials` siguen llamándose igual que siempre).

El motivo es de gestión, no de arquitectura de datos: un único punto de
administración de base de datos para todo el ecosistema, en vez de un Pod por
base — lo que además simplifica cómo la ticketera (`ticket-hub-api` +
`pcbox-api`) ejecuta SQL contra un target: un solo host y un solo Secret de
credenciales a mantener en la allowlist, en vez de tres.

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

Saltá este paso si ya está habilitado — el `StorageClass`
`microk8s-hostpath` que esto crea es a nivel de cluster, no por namespace.

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

El DDL de cada archivo es el esquema **actual** de cada base — el estado
final tras todas las migraciones aplicadas hasta hoy. Un despliegue nuevo
desde este ConfigMap arranca directamente en ese estado final, sin tener
que repetir a mano cada `ALTER TABLE` histórico.

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

Esta base no tiene ninguna migración posterior aplicada desde su primer
despliegue, así que su esquema original y su esquema actual son el mismo.

```bash
sudo nano ~/postgres-init/pcbox.sql
```

```sql
CREATE DATABASE pcbox;

\c pcbox

CREATE TABLE datacenter_register (
  id SERIAL PRIMARY KEY,
  ticket_number INTEGER NOT NULL,
  department VARCHAR(15) NOT NULL,
  approver VARCHAR(100) NOT NULL,
  informer VARCHAR(30) NOT NULL,
  status VARCHAR(15) NOT NULL,
  file_content TEXT NOT NULL,
  response TEXT
);

CREATE TABLE database_register (
  id SERIAL PRIMARY KEY,
  ticket_number INTEGER NOT NULL,
  department VARCHAR(15) NOT NULL,
  approver VARCHAR(100) NOT NULL,
  informer VARCHAR(30) NOT NULL,
  database VARCHAR(30) NOT NULL,
  status VARCHAR(15) NOT NULL,
  sql_content TEXT NOT NULL,
  response TEXT
);

CREATE TABLE kubernetes_register (
  id SERIAL PRIMARY KEY,
  ticket_number INTEGER NOT NULL,
  department VARCHAR(15) NOT NULL,
  approver VARCHAR(100) NOT NULL,
  informer VARCHAR(30) NOT NULL,
  status VARCHAR(15) NOT NULL,
  file_content TEXT NOT NULL,
  response TEXT
);
```

La antigua tabla única `administrations` (compartida por los flavors ANSIBLE
y DATABASE) queda reemplazada por estas tres: `datacenter_register` para
ANSIBLE (vía el módulo `pcbox`), `database_register` para DATABASE (vía el
módulo `database`), y `kubernetes_register` para KUBERNETES (vía el módulo
`kubernetes`) — la tabla misma es el discriminador. `database_register`
suma la columna `database` (el `dbName` del target contra el que corrió el
SQL); `namespace`/`deployment` no se persisten en ninguna tabla — pcbox-api
los sigue necesitando como input transitorio para `DbTargetValidator`/
`SqlPlaybookBuilder`, pero nunca se guardan. `kubernetes_register` es la más
chica de las tres: mismas columnas que `datacenter_register` (mismo
`fileContent TEXT`, el manifiesto YAML de pie, sin transformar), sin ninguna
columna propia — a diferencia de `database_register`, no necesita un target
estructurado aparte porque el namespace/kind de cada recurso ya viene
adentro del propio YAML. Las tres suman `response TEXT`, nullable, para la
respuesta de la ejecución.

```bash
sudo nano ~/postgres-init/ticket-hub.sql
```

```sql
CREATE DATABASE "ticket-hub";

\c "ticket-hub"

CREATE TABLE datacenter_tickets (
  id SERIAL PRIMARY KEY,
  number INTEGER NOT NULL UNIQUE,
  informer VARCHAR(30) NOT NULL,
  assignee VARCHAR(100),
  department VARCHAR(25) NOT NULL,
  subject VARCHAR(100) NOT NULL,
  status VARCHAR(20) NOT NULL,
  description VARCHAR(200) NOT NULL,
  code_ansible VARCHAR(5000),
  response TEXT
);

CREATE TABLE database_tickets (
  id SERIAL PRIMARY KEY,
  number INTEGER NOT NULL UNIQUE,
  informer VARCHAR(30) NOT NULL,
  assignee VARCHAR(100),
  department VARCHAR(25) NOT NULL,
  subject VARCHAR(100) NOT NULL,
  status VARCHAR(20) NOT NULL,
  description VARCHAR(200) NOT NULL,
  response TEXT,
  db_namespace VARCHAR(63),
  db_deployment VARCHAR(63),
  db_name VARCHAR(63),
  sql_code VARCHAR(5000)
);

CREATE TABLE kubernetes_tickets (
  id SERIAL PRIMARY KEY,
  number INTEGER NOT NULL UNIQUE,
  informer VARCHAR(30) NOT NULL,
  assignee VARCHAR(100),
  department VARCHAR(25) NOT NULL,
  subject VARCHAR(100) NOT NULL,
  status VARCHAR(20) NOT NULL,
  description VARCHAR(200) NOT NULL,
  code_yaml VARCHAR(5000),
  response TEXT
);
```

`"ticket-hub"` va entre comillas dobles en el `CREATE DATABASE` y en el
`\c` porque el guión no es válido en un identificador SQL sin comillar —
mismo motivo por el que la base vieja se llamó `ticket-hub-db` y no
`ticket-hub`, aunque el driver de Postgres (y TypeORM) no tiene problema
con el nombre una vez que ya existe.

La antigua tabla única `tickets` (discriminada por la columna `ticket_type`)
queda reemplazada por estas tres: `datacenter_tickets` para ANSIBLE,
`database_tickets` para DATABASE, y `kubernetes_tickets` para KUBERNETES —
la tabla misma es el discriminador, así que ni `ticket_type` ni `creator`
sobreviven (tampoco tienen consumidor: `informer`, el email de quien creó
el ticket, es el único dato de autoría que usa la app). `database_tickets`
conserva `db_namespace`/`db_deployment`/`db_name`/`sql_code` porque
`pcbox-api` los sigue necesitando como input al aprobar el ticket, en una
request separada de la creación. `kubernetes_tickets` es una copia exacta
de `datacenter_tickets`, salvo `code_yaml` en vez de `code_ansible` — mismo
motivo que `kubernetes_register` arriba: el manifiesto YAML no necesita
ninguna columna de target aparte. Las tablas `users`/`roles` del esquema
original tampoco aparecen: ya no tienen ningún consumidor. Cada tabla nueva
calcula su propio `MAX(number) + 1` de forma independiente — puede existir
un `TK-5` ANSIBLE, un `TK-5` DATABASE y un `TK-5` KUBERNETES al mismo
tiempo.

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

Debería listar las ocho tablas de `iam`; `datacenter_register`,
`database_register` y `kubernetes_register` en `pcbox`; `datacenter_tickets`,
`database_tickets` y `kubernetes_tickets` en `ticket-hub`.

Desde cualquier otro namespace del cluster (`auth-api`, `pcbox-api`,
`ticket-hub`), la instancia se ve en
`postgres.databases.svc.cluster.local:5432` — el DNS interno de Kubernetes
no distingue namespace de origen, solo el del Service (`databases`), así
que las tres apps llegan ahí sin importar en qué namespace corren ellas
mismas.

## 7. Crear las tablas de `kubernetes_register`/`kubernetes_tickets` en una instancia ya desplegada

Si esta instancia ya estaba corriendo antes de que `kubernetes_register`
(base `pcbox`) y `kubernetes_tickets` (base `ticket-hub`) se agregaran al
DDL del paso 4, esas dos tablas no existen todavía — el ConfigMap
`postgres-init` solo corre una vez, al primer arranque con el volumen
vacío (mismo motivo que el paso 8 de más abajo, para agregar una columna).
Se crean a mano, una sola vez, conectando al Pod y eligiendo la base con
`-d`:

```bash
microk8s kubectl exec -it -n databases deployment/postgres -- \
  psql -U usuario_db -d pcbox -c '
CREATE TABLE kubernetes_register (
  id SERIAL PRIMARY KEY,
  ticket_number INTEGER NOT NULL,
  department VARCHAR(15) NOT NULL,
  approver VARCHAR(100) NOT NULL,
  informer VARCHAR(30) NOT NULL,
  status VARCHAR(15) NOT NULL,
  file_content TEXT NOT NULL,
  response TEXT
);'

microk8s kubectl exec -it -n databases deployment/postgres -- \
  psql -U usuario_db -d "ticket-hub" -c '
CREATE TABLE kubernetes_tickets (
  id SERIAL PRIMARY KEY,
  number INTEGER NOT NULL UNIQUE,
  informer VARCHAR(30) NOT NULL,
  assignee VARCHAR(100),
  department VARCHAR(25) NOT NULL,
  subject VARCHAR(100) NOT NULL,
  status VARCHAR(20) NOT NULL,
  description VARCHAR(200) NOT NULL,
  code_yaml VARCHAR(5000),
  response TEXT
);'
```

Esto es una condición previa real para que la feature de tickets Kubernetes
funcione en un cluster ya desplegado: sin estas dos tablas, `ticket-hub-api`
y `pcbox-api` arrancan igual (`synchronize: false`, ninguna app valida el
esquema al boot) pero cualquier request que toque una de las dos tablas
falla en tiempo de ejecución contra Postgres (`relation ... does not
exist`) recién al primer intento de uso, no antes.

## 8. Agregar una columna más adelante (precedente para futuras migraciones)

Igual que en los tres documentos por app: el ConfigMap `postgres-init` del
paso 4 **no** se vuelve a ejecutar contra un volumen que ya tiene datos, así
que cualquier cambio de esquema posterior a este primer despliegue se aplica
a mano, una sola vez, con `ALTER TABLE` — conectando al Pod y eligiendo la
base con `-d`:

```bash
microk8s kubectl exec -it -n databases deployment/postgres -- \
  psql -U usuario_db -d iam
```

(o `-d pcbox` / `-d "ticket-hub"` según cuál base cambie). Si la columna
nueva tiene que terminar siendo `NOT NULL` en una tabla que puede que ya
tenga filas, seguí este patrón de cuatro pasos: `ADD COLUMN` sin `NOT NULL`
primero, `UPDATE` para completar las filas existentes, y recién después
`ALTER COLUMN ... SET NOT NULL`.

## 9. Datos producidos por este proceso

| Dato | Qué es | Qué paso lo produjo | Para qué sirve |
|---|---|---|---|
| Namespace `databases` | Namespace de infraestructura, dueño del Pod de Postgres consolidado | Paso 2 | Aísla el ciclo de vida de las bases del ciclo de vida de las apps que las consumen |
| Secret `postgres-credentials` (namespace `databases`) | `POSTGRES_USER`/`POSTGRES_PASSWORD`, dueño de las tres bases | Paso 3 (creado con `kubectl create secret`, editable después desde el Dashboard) | Credencial única de conexión a las tres bases; cualquier rotación se hace editando este Secret desde el Dashboard, no por SSH |
| ConfigMap `postgres-init` (namespace `databases`) | Tres scripts (`iam.sql`, `pcbox.sql`, `ticket-hub.sql`), uno por base | Paso 4 | Aplicado por el mecanismo `docker-entrypoint-initdb.d` de la imagen de Postgres al primer arranque con el volumen vacío |
| Bases `iam`, `pcbox`, `ticket-hub` | Las tres bases lógicas de la instancia (`iam` = la base de `auth-api`, renombrada) | Paso 4 (ejecutado al arrancar el Pod, paso 5) | Almacenamiento para `auth-api`, `pcbox-api` y `ticket-hub-api` respectivamente |
| Host interno `postgres.databases.svc.cluster.local:5432` | DNS interno del cluster que apunta al Service de la instancia consolidada | Paso 5 (`Service` `postgres`) | Cadena de conexión que usa cada app (`DATABASE_HOST`) |

Los tres Pods viejos por app (`auth-db`, `pcbox-db`, `ticket-hub-db`) ya
fueron decomisionados — `auth-api`, `pcbox-api` y `ticket-hub-api` corren
contra este Pod consolidado.
