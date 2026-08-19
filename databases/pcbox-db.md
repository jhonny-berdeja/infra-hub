# Deploy de la base de datos `pcbox-db` en microk8s (servidor pcbox)

Motor elegido: **PostgreSQL**, mismo criterio que `ticket-hub-db` (ver
`ticket-hub-db.md`, que es la plantilla que sigue este
documento). Corre como un Pod dentro del cluster de microk8s, con sus datos
en un volumen persistente y sus credenciales en un Secret de Kubernetes.

A diferencia de `ticket-hub-db` — que vive en su propio namespace
`ticket-hub`, compartido con `ticket-hub-api` — `pcbox-db` comparte el
namespace `pcbox-api`, el mismo namespace donde corre la app `pcbox-api`
misma: mismo criterio exacto (una base y su API en el mismo namespace),
aplicado acá con el nombre `pcbox-api` en vez de `pcbox-db-namespace` o
similar, porque ese es el namespace que la app ya usa.

## 0. Punto de partida

Todo este instructivo asume que ya se completó `pcbox-api/documentation/pcbox.bootstrap.md` (pasos
1 a 4) y `pcbox-api/documentation/pcbox.microk8s-setup.md` entero. Si `ticket-hub-db.md`
ya se corrió antes, el addon `hostpath-storage` (paso 1 ahí) ya está
habilitado — no hace falta repetirlo. Conectarse al servidor por SSH sobre
la IP de Tailscale (secret `SSH_HOST`):

```bash
ssh -i deploy_key jhon@IP_TAILSCALE
```

Todos los comandos de este documento se corren desde esa sesión.

## 1. Crear el namespace (si todavía no existe)

```bash
microk8s kubectl create namespace pcbox-api
```

Si la app `pcbox-api` ya se desplegó antes que su base, este comando falla
con "already exists" — no es un error, simplemente el namespace ya está
creado; seguir al paso 2.

## 2. Crear el Secret con el usuario y la contraseña

```bash
microk8s kubectl create secret generic pcbox-db-credentials \
  -n pcbox-api \
  --from-literal=POSTGRES_USER=usuario_db \
  --from-literal=POSTGRES_PASSWORD=clave_segura
```

> **Nota:** igual que `ticket-hub-db-credentials`, esta es la única vez que
> la credencial se escribe a mano por línea de comandos — para rotarla
> después, editar este Secret desde el Dashboard de microk8s
> (`pcbox-api/documentation/pcbox.microk8s-setup.md`, paso 3 → Secrets → namespace `pcbox-api`) y
> reiniciar el Pod, ya que Kubernetes no reinyecta variables de entorno en
> un contenedor ya corriendo.

## 3. Definir el esquema inicial como ConfigMap

```bash
sudo nano ~/pcbox-db-init.yaml
```

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: pcbox-db-init
  namespace: pcbox-api
data:
  init.sql: |
    CREATE TABLE administrations (
      id SERIAL PRIMARY KEY,
      ticket_number INTEGER NOT NULL,
      department VARCHAR(15) NOT NULL,
      approver VARCHAR(15) NOT NULL,
      informer VARCHAR(15) NOT NULL,
      status VARCHAR(15) NOT NULL,
      file_content VARCHAR(500) NOT NULL
    );
```

```bash
microk8s kubectl apply -f ~/pcbox-db-init.yaml
```

> **Nota sobre el esquema:** todas las columnas son `NOT NULL` a propósito
> — a diferencia de `tickets.assignee` en `ticket-hub-db`, un registro de
> `administrations` solo se escribe una vez que la app ya validó los dos
> gates (status local, YAML parseable — ver `.claude/CLAUDE.md`), así que
> nunca hay un registro parcial que representar. `ticket_number` es un
> entero simple, no una foreign key: `administrations` vive en una base y
> un namespace completamente separados de `ticket-hub-db`/`ticket-hub`, así
> que no hay forma de que Postgres valide esa referencia directamente —
> tampoco la app la valida ya: `ticket_number`/`department`/`approver`/
> `informer` se guardan tal cual se reciben, sin contrastarlos contra
> ticket-hub-api.

## 4. Crear el volumen persistente, el Deployment y el Service

```bash
sudo nano ~/pcbox-db.yaml
```

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: pcbox-db-pvc
  namespace: pcbox-api
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
  name: pcbox-db
  namespace: pcbox-api
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: pcbox-db
  template:
    metadata:
      labels:
        app: pcbox-db
    spec:
      containers:
        - name: postgres
          image: postgres:16-alpine
          ports:
            - containerPort: 5432
          env:
            - name: POSTGRES_DB
              value: pcbox-db
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata
          envFrom:
            - secretRef:
                name: pcbox-db-credentials
          volumeMounts:
            - name: data
              mountPath: /var/lib/postgresql/data
            - name: init-script
              mountPath: /docker-entrypoint-initdb.d
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: pcbox-db-pvc
        - name: init-script
          configMap:
            name: pcbox-db-init
---
apiVersion: v1
kind: Service
metadata:
  name: pcbox-db
  namespace: pcbox-api
spec:
  selector:
    app: pcbox-db
  ports:
    - port: 5432
      targetPort: 5432
```

> **Nota sobre `PGDATA`:** mismo workaround que `ticket-hub-db` — apunta a
> un subdirectorio porque la raíz de un volumen `hostPath` trae un
> `lost+found` que Postgres rechaza como directorio de datos no vacío.

```bash
microk8s kubectl apply -f ~/pcbox-db.yaml
```

## 5. Verificar

```bash
microk8s kubectl get pods -n pcbox-api
```

Debería aparecer `pcbox-db-...` en estado `Running`, junto al Pod de la app
`pcbox-api` si ya está desplegada.

```bash
microk8s kubectl exec -it -n pcbox-api deployment/pcbox-db -- psql -U usuario_db -d pcbox-db -c '\dt'
```

Debería listar `administrations`.

```bash
microk8s kubectl exec -it -n pcbox-api deployment/pcbox-db -- psql -U usuario_db -d pcbox-db -c '\d administrations'
```

Todas las columnas deberían mostrar `not null`.

## 6. Datos que quedan de este proceso

| Dato | Qué es | De qué paso salió | Para qué es |
|---|---|---|---|
| Secret `pcbox-db-credentials` (namespace `pcbox-api`) | `POSTGRES_USER` y `POSTGRES_PASSWORD` de la base `pcbox-db` | Paso 2 (creado por `kubectl create secret`, editable después desde el Dashboard) | Credenciales de conexión a la base — mismos valores que `POSTGRES_USER`/`POSTGRES_PASSWORD` en el `.env.example`/README de `pcbox-api` |
| Host interno `pcbox-db.pcbox-api.svc.cluster.local:5432` | DNS interno del cluster que apunta al Service de la base | Paso 4 (`Service` `pcbox-db`) | Cadena de conexión que usa la propia app `pcbox-api` (`DATABASE_HOST`) |

## 7. Ensanchar `approver`/`informer` (migración posterior)

`approver`/`informer` dejaron de venir de `users.name` (VARCHAR(15) en la
`ticket-hub-db` vieja) — ahora `approver` es el texto libre de
`tickets.assignee` (VARCHAR(100)) e `informer` es el email del creador
(`tickets.informer`, VARCHAR(30)). Con `VARCHAR(15)` acá, casi cualquier
aprobación real fallaba la validación de `CreatePcboxDto` con 400.

Conectado al contenedor y a `psql`, igual que en pasos anteriores de otros
despliegues de este mismo repo:

```bash
microk8s kubectl exec -it -n pcbox-api deployment/pcbox-db -- \
  psql -U usuario_db -d pcbox-db
```

```sql
ALTER TABLE administrations ALTER COLUMN approver TYPE VARCHAR(100);
ALTER TABLE administrations ALTER COLUMN informer TYPE VARCHAR(30);
```

Verificar:

```sql
\d administrations
```

`approver` debería listar `character varying(100)`, `informer`
`character varying(30)`, ambos `not null`.

## 8. Ensanchar `file_content` a `TEXT` (migración posterior)

Cambio `manage-database-sql-ticket`: para un ticket `DATABASE`,
`pcbox-api` genera el playbook (SQL entregado por `stdin`, ver
`SqlPlaybookBuilder`) y lo persiste igual que hoy en `file_content` —
pero ese playbook generado puede superar largo los 500 caracteres del
`VARCHAR(500)` actual una vez que se le suma el SQL (hasta 5000
caracteres) más el boilerplate YAML del `command.argv`/`stdin`. El
esquema anterior (`VARCHAR(500)`) seguía siendo suficiente para el
YAML escrito a mano de un ticket `ANSIBLE`, así que se ensancha la
columna en vez de acotar el SQL a un tamaño que no alcanza.

Conectado al contenedor y a `psql`, igual que en el paso 7:

```bash
microk8s kubectl exec -it -n pcbox-api deployment/pcbox-db -- \
  psql -U usuario_db -d pcbox-db
```

```sql
ALTER TABLE administrations ALTER COLUMN file_content TYPE TEXT;
```

Sigue `NOT NULL` — la columna no cambia de significado ("el playbook
que realmente corrió"), solo deja de tener un tope acotado. `TEXT` en
vez de un `VARCHAR(n)` mayor porque no hay un límite de negocio propio
para el playbook ya generado (el límite real está en `sqlCode`, ya
acotado a 5000 en `DatabaseActionDto` antes de llegar acá).

Verificar:

```sql
\d administrations
```

`file_content` debería listar `text`, `not null` (sin longitud
asociada — `TEXT` no la tiene).
