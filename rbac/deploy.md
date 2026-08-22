# RBAC de pcbox-api para tickets Kubernetes (servidor pcbox)

Instructivo para dar de alta el `ServiceAccount`/`ClusterRole`/`RoleBinding`s que necesita el módulo `kubernetes/` de pcbox-api — la ejecución de tickets Kubernetes le pega directo a la API del cluster (in-cluster, vía el propio Pod), y hasta que este instructivo se corra, ese Pod no tiene ningún permiso sobre la API de Kubernetes (hoy solo tiene acceso SSH al servidor `pcbox` para correr `ansible-playbook`, que es un camino totalmente aparte).

Se hace a mano, por SSH, con `kubectl apply` — mismo criterio que `infra-hub/loki/deploy.md` (paso 3.1, RBAC de Promtail): no es algo que la pipeline de deploy de pcbox-api aplique sola.

## 0. Punto de partida

Asume el bootstrap del servidor ya hecho (`pcbox-api/documentation/pcbox.bootstrap.md`, pasos 0 a 4, y `pcbox-api/documentation/pcbox.microk8s-setup.md` entero). Conectarse por SSH sobre la IP de Tailscale:

```bash
ssh -i deploy_key jhon@IP_TAILSCALE
```

Todos los comandos de este documento se corren desde esa sesión.

## 1. Namespaces permitidos — mantener sincronizado con el código

El `ClusterRole`/`RoleBinding`s de abajo solo tienen sentido para los mismos namespaces que pcbox-api ya valida en su propio código, en `pcbox-api/src/modules/kubernetes/value-objects/k8s-namespace.allowlist.ts` (`ALLOWED_K8S_NAMESPACES`):

- `pcbox-api`
- `ticket-hub`
- `auth-api`
- `iam-api`
- `databases`

Son dos gates independientes a propósito (defensa en profundidad): RBAC es lo que el cluster permite de verdad; `K8sTargetValidator` es lo que la app valida antes de intentarlo. Si el día de mañana se agrega o saca un namespace de esa constante en el código, este archivo tiene que actualizarse en el mismo cambio — igual que ya se documenta para `pcbox-api/src/modules/database/value-objects/db-target.allowlist.ts` ("agregar un target ahí es un deploy deliberado y revisado").

Tampoco se otorga `delete` sobre nada: un ticket Kubernetes solo aplica manifiestos (crear/actualizar), nunca borra recursos.

## 2. Crear ServiceAccount + ClusterRole + RoleBindings

```bash
sudo nano ~/pcbox-api-kubernetes-rbac.yaml
```

```yaml
# ServiceAccount dedicado para pcbox-api -- antes de esto, el Pod corría
# con la cuenta "default" del namespace, que no tiene (ni necesitaba)
# ningún permiso sobre la API de Kubernetes.
apiVersion: v1
kind: ServiceAccount
metadata:
  name: pcbox-api
  namespace: pcbox-api
---
# get/list para poder decidir create vs. patch (ver
# KubernetesConnector.applyManifests: hace un read antes de aplicar).
# create/patch para aplicar el manifiesto del ticket. Sin delete a
# propósito -- ver nota arriba. Los kinds cluster-scoped/de alto
# privilegio (Namespace, ClusterRole, ClusterRoleBinding, Node,
# CustomResourceDefinition, PersistentVolume, los dos
# *WebhookConfiguration) quedan afuera on purpose -- ni siquiera están
# en esta lista de resources, y además el código los bloquea igual en
# K8sTargetValidator.assertAllowedKind.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: pcbox-api-kubernetes-executor
rules:
  - apiGroups: [""]
    resources:
      - services
      - configmaps
      - secrets
      - pods
      - persistentvolumeclaims
    verbs: ["get", "list", "create", "patch"]
  - apiGroups: ["apps"]
    resources:
      - deployments
      - statefulsets
      - daemonsets
    verbs: ["get", "list", "create", "patch"]
  - apiGroups: ["batch"]
    resources:
      - jobs
      - cronjobs
    verbs: ["get", "list", "create", "patch"]
  - apiGroups: ["networking.k8s.io"]
    resources:
      - ingresses
    verbs: ["get", "list", "create", "patch"]
---
# Un RoleBinding por namespace permitido -- vincula el mismo ClusterRole
# pero acotado namespace por namespace (a diferencia de un
# ClusterRoleBinding, que sería cluster-wide). Cinco objetos separados,
# uno por entrada de ALLOWED_K8S_NAMESPACES (sección 1).
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: pcbox-api-kubernetes-executor
  namespace: pcbox-api
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: pcbox-api-kubernetes-executor
subjects:
  - kind: ServiceAccount
    name: pcbox-api
    namespace: pcbox-api
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: pcbox-api-kubernetes-executor
  namespace: ticket-hub
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: pcbox-api-kubernetes-executor
subjects:
  - kind: ServiceAccount
    name: pcbox-api
    namespace: pcbox-api
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: pcbox-api-kubernetes-executor
  namespace: auth-api
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: pcbox-api-kubernetes-executor
subjects:
  - kind: ServiceAccount
    name: pcbox-api
    namespace: pcbox-api
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: pcbox-api-kubernetes-executor
  namespace: iam-api
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: pcbox-api-kubernetes-executor
subjects:
  - kind: ServiceAccount
    name: pcbox-api
    namespace: pcbox-api
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: pcbox-api-kubernetes-executor
  namespace: databases
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: pcbox-api-kubernetes-executor
subjects:
  - kind: ServiceAccount
    name: pcbox-api
    namespace: pcbox-api
```

> **Nota — la `databases` namespace no vive en este repo como manifiesto propio.** Si todavía no existe cuando se corra esto (`microk8s kubectl get namespace databases`), crearla primero (`databases/jtagram.db.md` debería ser quien la documenta) antes del `apply` de abajo, o el `RoleBinding` de ese namespace va a fallar.

```bash
microk8s kubectl apply -f ~/pcbox-api-kubernetes-rbac.yaml
```

## 3. Asignarle el ServiceAccount al Deployment de pcbox-api

Esto sí se commitea al repo, porque `deployment.yaml` es uno de los tres archivos que la pipeline `deploy-pcbox-api.yml` ya aplica automáticamente (`copy-manifest-templates.sh pcbox-api namespace.yaml deployment.yaml service.yaml`) — a diferencia del YAML del paso 2, que no está en esa lista fija y por eso se aplicó a mano.

En `infra-hub/apps/pcbox-api/deployment.yaml`, agregar `serviceAccountName` bajo `spec.template.spec` (mismo nivel que `containers`):

```yaml
spec:
  replicas: 1
  selector:
    matchLabels:
      app: pcbox-api
  template:
    metadata:
      labels:
        app: pcbox-api
    spec:
      serviceAccountName: pcbox-api
      containers:
        - name: pcbox-api
          # ...
```

Commitear ese cambio a `master` y correr el workflow `Deploy pcbox-api` (`workflow_dispatch`, como cualquier otro deploy) para que el rollout tome el nuevo `serviceAccountName`.

## 4. Verificar

```bash
# El Pod debería estar corriendo con el ServiceAccount nuevo, no "default":
microk8s kubectl get pod -n pcbox-api -o jsonpath='{.items[0].spec.serviceAccountName}'

# Confirmar que el ServiceAccount puede lo que debería en cada namespace permitido
# (auth impersonado, no pega de verdad):
microk8s kubectl auth can-i create deployments -n ticket-hub --as=system:serviceaccount:pcbox-api:pcbox-api
microk8s kubectl auth can-i patch configmaps -n databases --as=system:serviceaccount:pcbox-api:pcbox-api

# Y que NO puede tocar algo fuera del allowlist ni un kind bloqueado:
microk8s kubectl auth can-i create deployments -n kube-system --as=system:serviceaccount:pcbox-api:pcbox-api
microk8s kubectl auth can-i create namespaces --as=system:serviceaccount:pcbox-api:pcbox-api
```

Las dos últimas deberían responder `no`. Si alguna responde `yes`, algo en el `ClusterRole`/`RoleBinding` quedó más permisivo de lo que dice este documento — revisar antes de dar por cerrado el punto.

Prueba de punta a punta: crear un ticket Kubernetes real desde ticket-hub con un manifiesto simple (un `ConfigMap` en `ticket-hub`, por ejemplo) y aprobarlo — el `response` del ticket debería mostrar `created`/`configured` para ese recurso.
