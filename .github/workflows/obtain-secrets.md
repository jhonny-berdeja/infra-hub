# Cómo obtener los secretos de los workflows de deploy

Guía paso a paso para conseguir los valores listados en [.env.secrets.example](.env.secrets.example)
y cargarlos como secretos del repositorio en GitHub Actions
(Settings > Secrets and variables > Actions > New repository secret).

## TS_OAUTH_CLIENT_ID / TS_OAUTH_SECRET

Los usa el step de `tailscale/github-action` para unir el runner a la tailnet
y así poder llegar al API server de microk8s en pcbox.

1. Entrá a la [consola de administración de Tailscale](https://login.tailscale.com/admin/settings/oauth) > Settings > OAuth clients.
2. Creá un nuevo cliente OAuth.
   - Scope: `Devices` > `Write`.
   - Tags: agregá `tag:continuous-integration` (debe coincidir con el valor
     `tags:` del step de Tailscale en los workflows) — esto es lo que permite
     que el dispositivo efímero de CI se autentique sin aprobación manual.
3. Copiá el Client ID y el Client Secret generados apenas se muestren — el
   secret solo se ve una vez.
4. Guardalos como `TS_OAUTH_CLIENT_ID` y `TS_OAUTH_SECRET`.

## KUBECONFIG_PCBOX

Contenido crudo del kubeconfig (no en base64) usado para autenticar
`kubectl` contra el cluster de microk8s en pcbox — ver [save-kubeconfig.sh](../scripts/save-kubeconfig.sh).

El procedimiento completo está documentado en el repo `pcbox-api`,
`documentation/pcbox.microk8s-setup.md` (paso 2). Resumen:

1. **Prerrequisito**: el certificado del API server de microk8s tiene que
   estar extendido para incluir la IP de Tailscale del servidor (`sudo nano
   /var/snap/microk8s/current/certs/csr.conf.template` agregando esa IP en
   `[alt_names]`, después `sudo microk8s refresh-certs -e server.crt`). Por
   defecto el certificado solo es válido para la IP local, y el runner de CI
   se conecta por Tailscale — sin este paso, `kubectl` va a fallar la
   verificación TLS.
2. Conectate por SSH al nodo de microk8s en pcbox (por la IP de Tailscale,
   secret `SSH_HOST`).
3. Generá el kubeconfig:
   ```
   microk8s config > ~/pcbox-kubeconfig.yaml
   ```
4. **Editá el archivo a mano**: el campo `server:` apunta por defecto a la
   IP local del servidor. Cambialo para que apunte a la IP de Tailscale
   (la CA y el resto del archivo quedan igual):
   ```yaml
   server: https://100.x.x.x:16443   # IP de Tailscale, no la local
   ```
5. Sacá el archivo del servidor a tu PC (`scp jhon@IP_TAILSCALE:~/pcbox-kubeconfig.yaml .`)
   — contiene una clave privada, es un secreto, no se commitea al repo.
6. Copiá el contenido completo ya editado y guardalo como `KUBECONFIG_PCBOX`.
   - Si ya existe una service account con permisos RBAC acotados a los
     namespaces necesarios, preferí ese kubeconfig por sobre el admin
     completo.

## DOCKERHUB_USERNAME

La cuenta/organización de Docker Hub bajo la que se publican las imágenes
que se despliegan. Se sustituye en la referencia de imagen de cada manifest
de deployment.

1. Es el username que figura en tu perfil de [Docker Hub](https://hub.docker.com/)
   (o el nombre de la organización dueña de los repositorios de imágenes).
2. Guardalo como `DOCKERHUB_USERNAME`.

## SSH_HOST / SSH_USER

Solo los usa `deploy-pcbox-api.yml`. **No** los usa el runner para conectarse
por SSH a ningún lado: se inyectan como variables de entorno del Deployment
de pcbox-api (`PCBOX_SSH_HOST`/`PCBOX_SSH_USER` en [deployment.yaml](../../apps/pcbox-api/deployment.yaml))
para que la propia app pueda llegar por SSH al servidor físico de pcbox.

1. `SSH_HOST`: el hostname o IP de Tailscale del servidor pcbox (el mismo
   host al que apunta el kubeconfig de arriba).
2. `SSH_USER`: el usuario de login SSH configurado en ese servidor para que
   lo use la app.
3. Guardalos como `SSH_HOST` y `SSH_USER`.
