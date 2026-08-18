# Deploy de Loki + Promtail en microk8s (servidor pcbox)

Instructivo para levantar Loki (almacenamiento de logs) y Promtail (agente que junta los logs de stdout de todos los Pods del cluster y los empuja a Loki) dentro del cluster de microk8s del servidor `pcbox` — mismo patrón ya usado para Grafana (ver `infra-hub/grafana/deploy.md`) y para `ticket-hub-db` (`pcbox-api/documentation/pcbox.bootstrap.md`, paso 6). Al terminar este instructivo, los logs de `ticket-hub-api` (y de cualquier otro Pod del cluster) van a poder consultarse desde el Grafana ya deployado.

## 0. Punto de partida

Todo este instructivo asume que ya se completó `infra-hub/grafana/deploy.md` entero — Grafana corriendo en el namespace `grafana` y accesible por el túnel `grafana-tunnel.service`. También asume el bootstrap del servidor (`pcbox-api/documentation/pcbox.bootstrap.md`, pasos 1 a 4, y `pcbox-api/documentation/pcbox.microk8s-setup.md` entero): Tailscale configurado, clave SSH sin contraseña, y el addon `hostpath-storage` habilitado.

Conectarse al servidor por SSH sobre la IP de Tailscale (`SSH_HOST`, `100.x.x.x`):

```bash
ssh -i deploy_key jhon@IP_TAILSCALE
```

Todos los comandos de este documento se corren desde esa sesión.

## 1. Crear el namespace

Mismo criterio que separó `ticket-hub` y `grafana` de `kube-system`. Loki y Promtail comparten namespace porque son dos mitades de la misma pieza de infra (uno no tiene sentido sin el otro):

```bash
microk8s kubectl create namespace loki
```

## 2. Desplegar Loki

### 2.1. ConfigMap con la configuración

Loki en modo "single binary" con storage en filesystem (mismo criterio que el volumen persistente de Grafana/Postgres — no hace falta object storage externo para este tamaño de cluster):

```bash
sudo nano ~/loki-config.yaml
```

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: loki-config
  namespace: loki
data:
  loki.yaml: |
    auth_enabled: false

    server:
      http_listen_port: 3100
      grpc_listen_port: 9096

    common:
      path_prefix: /loki
      storage:
        filesystem:
          chunks_directory: /loki/chunks
          rules_directory: /loki/rules
      replication_factor: 1
      ring:
        kvstore:
          store: inmemory

    schema_config:
      configs:
        - from: 2024-01-01
          store: tsdb
          object_store: filesystem
          schema: v13
          index:
            prefix: index_
            period: 24h

    limits_config:
      retention_period: 168h
```

> **Nota sobre `retention_period: 168h`:** son 7 días. Sin este límite Loki guarda los logs para siempre y el volumen persistente se llena — ajustar según cuánto espacio se le dé al PVC en el paso siguiente.

```bash
microk8s kubectl apply -f ~/loki-config.yaml
```

### 2.2. Volumen persistente, Deployment y Service

```bash
sudo nano ~/loki.yaml
```

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: loki-pvc
  namespace: loki
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: microk8s-hostpath
  resources:
    requests:
      storage: 10Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: loki
  namespace: loki
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: loki
  template:
    metadata:
      labels:
        app: loki
    spec:
      securityContext:
        fsGroup: 10001
      containers:
        - name: loki
          image: grafana/loki:3.3.0
          args:
            - -config.file=/etc/loki/loki.yaml
          ports:
            - containerPort: 3100
          volumeMounts:
            - name: config
              mountPath: /etc/loki
            - name: data
              mountPath: /loki
      volumes:
        - name: config
          configMap:
            name: loki-config
        - name: data
          persistentVolumeClaim:
            claimName: loki-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: loki
  namespace: loki
spec:
  selector:
    app: loki
  ports:
    - port: 3100
      targetPort: 3100
```

> **Nota sobre `securityContext.fsGroup: 10001`:** mismo problema que con Grafana (`infra-hub/grafana/deploy.md`, paso 3) — el contenedor de Loki corre como usuario no-root (UID `10001`), y un volumen `microk8s-hostpath` recién creado queda con dueño `root`. Sin este `fsGroup` el Pod cae en `CrashLoopBackOff` por permisos al intentar escribir en `/loki`.

```bash
microk8s kubectl apply -f ~/loki.yaml
```

### 2.3. Verificar

```bash
microk8s kubectl get pods -n loki
microk8s kubectl logs -n loki deployment/loki
```

Buscar una línea tipo `msg="Loki started"` — confirma que terminó de arrancar.

No hace falta exponer Loki hacia afuera con un túnel systemd: solo Grafana lo consume, y lo hace desde adentro del cluster vía DNS interno (`loki.loki.svc.cluster.local:3100`) — mismo criterio que ya separa los Services de las apps (`ClusterIP` sin túnel) de los servicios de administración (Grafana, Dashboard).

## 3. Desplegar Promtail

Promtail corre como `DaemonSet` (un Pod por nodo) para poder leer los logs de todos los contenedores que corren en ese nodo directamente del filesystem del host.

### 3.1. Permisos (ServiceAccount + ClusterRole)

Promtail necesita listar/observar Pods y nodos en todo el cluster para saber qué logs le corresponde a cada uno y con qué labels (`namespace`, `pod`, `container`, `app`, etc.):

```bash
sudo nano ~/promtail-rbac.yaml
```

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: promtail
  namespace: loki
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: promtail
rules:
  - apiGroups: [""]
    resources:
      - nodes
      - nodes/proxy
      - services
      - endpoints
      - pods
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: promtail
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: promtail
subjects:
  - kind: ServiceAccount
    name: promtail
    namespace: loki
```

```bash
microk8s kubectl apply -f ~/promtail-rbac.yaml
```

### 3.2. ConfigMap con la configuración de scraping

```bash
sudo nano ~/promtail-config.yaml
```

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: promtail-config
  namespace: loki
data:
  promtail.yaml: |
    server:
      http_listen_port: 9080
      grpc_listen_port: 0

    positions:
      filename: /run/promtail/positions.yaml

    clients:
      - url: http://loki.loki.svc.cluster.local:3100/loki/api/v1/push

    scrape_configs:
      - job_name: kubernetes-pods
        kubernetes_sd_configs:
          - role: pod
        pipeline_stages:
          - cri: {}
        relabel_configs:
          - source_labels: [__meta_kubernetes_namespace]
            target_label: namespace
          - source_labels: [__meta_kubernetes_pod_name]
            target_label: pod
          - source_labels: [__meta_kubernetes_pod_container_name]
            target_label: container
          - source_labels: [__meta_kubernetes_pod_label_app]
            target_label: app
          - source_labels: [__meta_kubernetes_pod_node_name]
            target_label: node_name
          - source_labels:
              - __meta_kubernetes_pod_uid
              - __meta_kubernetes_pod_container_name
            separator: /
            target_label: __path__
            replacement: /var/log/pods/*$1/*.log
```

> **Nota sobre `pipeline_stages: - cri: {}`:** microk8s usa containerd como runtime, que escribe los logs de cada contenedor en formato CRI (`<timestamp> <stream> <flags> <mensaje>`) en `/var/log/pods/...`. El stage `cri` le saca ese envoltorio a cada línea antes de mandarla a Loki, para que quede solo el mensaje real de la app.

```bash
microk8s kubectl apply -f ~/promtail-config.yaml
```

### 3.3. DaemonSet

```bash
sudo nano ~/promtail.yaml
```

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: promtail
  namespace: loki
spec:
  selector:
    matchLabels:
      app: promtail
  template:
    metadata:
      labels:
        app: promtail
    spec:
      serviceAccountName: promtail
      tolerations:
        - effect: NoSchedule
          operator: Exists
      containers:
        - name: promtail
          image: grafana/promtail:3.3.0
          args:
            - -config.file=/etc/promtail/promtail.yaml
          env:
            # Promtail agrega automáticamente un selector
            # `spec.nodeName=$HOSTNAME` a su kubernetes_sd_config de rol
            # `pod`, para que cada Pod del DaemonSet descubra solo los pods
            # de su propio nodo. Dentro de un contenedor, `HOSTNAME` es por
            # default el nombre del Pod (`promtail-xxxxx`), no el nombre
            # real del nodo — sin este override el selector nunca matchea
            # nada y kubernetes-pods queda en 0/0 targets. Downward API
            # para forzar el valor correcto.
            - name: HOSTNAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          volumeMounts:
            - name: config
              mountPath: /etc/promtail
            - name: varlog
              mountPath: /var/log
              readOnly: true
            - name: positions
              mountPath: /run/promtail
      volumes:
        - name: config
          configMap:
            name: promtail-config
        - name: varlog
          hostPath:
            path: /var/log
        - name: positions
          emptyDir: {}
```

```bash
microk8s kubectl apply -f ~/promtail.yaml
```

### 3.4. Verificar

```bash
microk8s kubectl get pods -n loki -l app=promtail
microk8s kubectl logs -n loki daemonset/promtail
```

Con microk8s corriendo en un solo nodo va a aparecer un único Pod `promtail-...` en `Running`. En los logs, buscar líneas de nivel `info` sin errores de conexión a `loki.loki.svc.cluster.local:3100` — un error ahí (`connection refused`) suele significar que el Service de Loki todavía no está listo.

> **Nota — `Running` sin errores no alcanza:** confirmá también que el service discovery encontró algo, no solo que el Pod está sano:
> ```bash
> microk8s kubectl exec -n loki daemonset/promtail -- wget -qO- http://localhost:9080/targets
> ```
> Si el job `kubernetes-pods` aparece como `0/0 ready` sin ningún error en los logs, el `env: HOSTNAME` del paso anterior no se aplicó — es la causa más común de este síntoma (Promtail filtra por nodo usando un `HOSTNAME` que en realidad es el nombre del propio Pod, no del nodo).

## 4. Agregar Loki como datasource en Grafana

Con Grafana ya accesible por el túnel de `infra-hub/grafana/deploy.md` (`http://IP_TAILSCALE_DEL_SERVIDOR:3000`):

1. Loguearse con el usuario/contraseña de admin.
2. Ir a **Connections → Data sources → Add data source → Loki**.
3. En **URL** poner `http://loki.loki.svc.cluster.local:3100` — la URL interna del cluster, no la del túnel. Grafana le habla a Loki Pod a Pod, no a través de Tailscale.
4. **Save & test** — debería confirmar la conexión.

## 5. Ver los logs de `ticket-hub-api`

En Grafana, ir a **Explore**, elegir el datasource Loki, y correr una query LogQL sobre las labels definidas en el `relabel_configs` del paso 3.2, por ejemplo:

```
{namespace="ticket-hub", container="ticket-hub-api"}
```

> **Nota:** `ticket-hub-api` emite logs JSON estructurados (`nestjs-pino`, ver `ticket-hub-api/.claude/exception-filters-conventions.md` y `src/instrument/logger/`) — se puede filtrar por campos con `| json`, por ejemplo `{namespace="ticket-hub", container="ticket-hub-api"} | json | level="error"`.

## 6. Métrica de duración de request, sin desplegar Prometheus

`pino-http` ya loguea `responseTime` (en milisegundos) en la línea `"request completed"` de cada request — no hace falta instrumentar nada nuevo en la app ni desplegar un sistema de métricas aparte. LogQL puede agregar directamente sobre ese campo.

En Grafana: **Dashboards → New → Add visualization**, datasource Loki, tipo **Time series**, con esta query:

```
quantile_over_time(0.95, {namespace="ticket-hub", container="ticket-hub-api"} |= "responseTime" | json | unwrap responseTime [$__interval])
```

- `|= "responseTime"` — filtro de texto plano *antes* de parsear JSON: descarta rápido las líneas que ni siquiera tienen el campo (arranque de NestJS, líneas de los exception filters), sin gastar CPU parseándolas todas.
- `| json` — parsea la línea como JSON y expone sus campos.
- `| unwrap responseTime` — le dice a LogQL que agregue sobre ese campo numérico, en vez de solo contar líneas.
- `quantile_over_time(0.95, ..., [$__interval])` — percentil 95, en la ventana de tiempo que Grafana ajusta sola según el zoom del panel.

Para ver varios percentiles juntos, agregar una query por cada uno en el mismo panel:

```
quantile_over_time(0.50, {namespace="ticket-hub", container="ticket-hub-api"} |= "responseTime" | json | unwrap responseTime [$__interval])
quantile_over_time(0.95, {namespace="ticket-hub", container="ticket-hub-api"} |= "responseTime" | json | unwrap responseTime [$__interval])
quantile_over_time(0.99, {namespace="ticket-hub", container="ticket-hub-api"} |= "responseTime" | json | unwrap responseTime [$__interval])
```

> **Nota sobre esta elección:** esto agrega sobre líneas de log, no sobre un histograma nativo como el de Prometheus — para el volumen de tráfico de este cluster no es un problema, pero es más costoso a medida que el tráfico crece. Si en algún momento eso empieza a pesar (paneles lentos, mucho volumen), esa es la señal para reconsiderar desplegar Prometheus + `@willsoto/nestjs-prometheus` en vez de esto — se descartó a propósito por ahora para no sumar otra pieza de infra sin necesidad real.
