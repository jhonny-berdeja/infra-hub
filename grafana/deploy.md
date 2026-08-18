# Deploy de Grafana en microk8s (servidor pcbox)

Instructivo para levantar Grafana como un Pod dentro del cluster de microk8s del servidor `pcbox`, con sus datos (dashboards, usuarios, configuración) en un volumen persistente y sus credenciales de admin en un Secret de Kubernetes — mismo patrón ya usado para la base `ticket-hub-db` (ver `pcbox-api/documentation/pcbox.bootstrap.md`, paso 6).

## 0. Punto de partida

Todo este instructivo asume que ya se completó el bootstrap del servidor (`pcbox-api/documentation/pcbox.bootstrap.md`, pasos 1 a 4, y `pcbox-api/documentation/pcbox.microk8s-setup.md` entero): Tailscale instalado y configurado, clave SSH sin contraseña, y microk8s corriendo con el addon `hostpath-storage` habilitado (`infra-hub/databases/ticket-hub-db.md`, paso 1 — si todavía no está habilitado, correr `microk8s enable hostpath-storage` antes de seguir).

Conectarse al servidor por SSH sobre la IP de Tailscale (`SSH_HOST`, `100.x.x.x`):

```bash
ssh -i deploy_key jhon@IP_TAILSCALE
```

Todos los comandos de este documento se corren desde esa sesión.

## 1. Crear el namespace

Para no mezclar los recursos de Grafana con los de otra app (mismo criterio que separó `ticket-hub` de `kube-system`):

```bash
microk8s kubectl create namespace grafana
```

## 2. Crear el Secret con las credenciales de admin

La imagen oficial de Grafana lee `GF_SECURITY_ADMIN_USER` y `GF_SECURITY_ADMIN_PASSWORD` como variables de entorno para fijar el usuario y la contraseña de administrador en el primer arranque. Guardarlas en un Secret, no en el manifiesto del Deployment, para poder rotarlas después sin editar YAML — mismo mecanismo que `ticket-hub-db-credentials`. Reemplazar `clave_segura` por un valor real:

```bash
microk8s kubectl create secret generic grafana-admin-credentials \
  -n grafana \
  --from-literal=GF_SECURITY_ADMIN_USER=admin \
  --from-literal=GF_SECURITY_ADMIN_PASSWORD=clave_segura
```

> **Nota:** igual que con `ticket-hub-db-credentials`, esta es la única vez que la contraseña se escribe a mano por línea de comandos. Para rotarla después, editar este Secret desde el Dashboard de microk8s (`pcbox-api/documentation/pcbox.microk8s-setup.md`, paso 3 → Secrets → namespace `grafana`) y reiniciar el Pod (`microk8s kubectl rollout restart deployment/grafana -n grafana`) — Grafana solo relee las variables de entorno al arrancar.

## 3. Crear el volumen persistente, el Deployment y el Service

```bash
sudo nano ~/grafana.yaml
```

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: grafana-pvc
  namespace: grafana
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
  name: grafana
  namespace: grafana
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels:
      app: grafana
  template:
    metadata:
      labels:
        app: grafana
    spec:
      securityContext:
        fsGroup: 472
      containers:
        - name: grafana
          image: grafana/grafana:11.4.0
          ports:
            - containerPort: 3000
          envFrom:
            - secretRef:
                name: grafana-admin-credentials
          volumeMounts:
            - name: data
              mountPath: /var/lib/grafana
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: grafana-pvc
---
apiVersion: v1
kind: Service
metadata:
  name: grafana
  namespace: grafana
spec:
  selector:
    app: grafana
  ports:
    - port: 3000
      targetPort: 3000
```

> **Nota sobre `securityContext.fsGroup: 472`:** el contenedor de Grafana corre como el usuario `grafana` (UID/GID `472`), no como `root`. Un volumen `hostPath`/`microk8s-hostpath` recién creado queda con dueño `root` por defecto — sin este `fsGroup`, Grafana no puede escribir en `/var/lib/grafana` y el Pod queda en `CrashLoopBackOff` con "permission denied" en los logs. `fsGroup` le dice a Kubernetes que ajuste el grupo dueño del volumen a `472` al montarlo, antes de que arranque el contenedor — mismo tipo de ajuste que el subdirectorio `PGDATA` resolvió para Postgres en `infra-hub/databases/ticket-hub-db.md` (paso 5), pero para el problema de permisos en vez del de "directorio no vacío".

```bash
microk8s kubectl apply -f ~/grafana.yaml
```

## 4. Verificar

```bash
microk8s kubectl get pods -n grafana
```

Debería aparecer `grafana-...` en estado `Running` (puede reiniciar una vez sola al principio si el volumen tardó en montarse — si sigue en `CrashLoopBackOff` después de un minuto, revisar los logs).

```bash
microk8s kubectl logs -n grafana deployment/grafana
```

Buscar una línea tipo `HTTP Server Listen ... address=[::]:3000` — confirma que Grafana terminó de arrancar y está escuchando.

## 5. Exponer Grafana con un túnel systemd

Mismo mecanismo que el Dashboard de microk8s (`pcbox-api/documentation/pcbox.microk8s-setup.md`, paso 3): un servicio systemd en vez de un `port-forward` manual, para que sobreviva a que se cierre la sesión SSH y se reinicie solo si falla.

```bash
sudo nano /etc/systemd/system/grafana-tunnel.service
```

```ini
[Unit]
Description=Grafana port-forward via Tailscale
After=network.target tailscaled.service
Wants=tailscaled.service

[Service]
Type=simple
ExecStart=/snap/bin/microk8s kubectl port-forward -n grafana service/grafana --address 100.x.x.x 3000:3000
Restart=always
RestartSec=5
User=root

[Install]
WantedBy=multi-user.target
```

Reemplazar `100.x.x.x` por la IP de Tailscale del servidor (`tailscale ip -4`, o el mismo valor que el secret `SSH_HOST`). Guardar y salir, recargar systemd y habilitar el servicio:

```bash
sudo systemctl daemon-reload
sudo systemctl enable grafana-tunnel
sudo systemctl start grafana-tunnel
```

Verificar:

```bash
sudo systemctl status grafana-tunnel
sudo ss -tlnp | grep 3000
```

Debería mostrar `active (running)` y el puerto `3000` en estado `LISTEN` sobre la IP de Tailscale.

Acceder desde el navegador, con Tailscale conectado en la PC cliente:

```
http://IP_TAILSCALE_DEL_SERVIDOR:3000
```

Login con el usuario y la contraseña creados en el paso 2. Grafana va a pedir cambiar la contraseña en el primer login — eso queda guardado en su propia base interna (el volumen persistente del paso 3), no vuelve a afectar el Secret de Kubernetes.
