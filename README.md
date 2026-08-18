# infra-hub

Este proyecto es para todo lo que tiene que ver con Kubernetes del ecosistema `jtagram`: los manifiestos de Deployment/Service de cada app (`apps/<nombre>/`), y los instructivos para levantar en el mismo cluster microk8s las bases de datos de cada app y la observabilidad (Grafana, Loki/Promtail) que las acompaña.

## Cómo montar el ecosistema

Esta guía asume que el servidor y microk8s ya están listos — ver `pcbox-api/README.md` (pasos 1 y 2: bootstrap del servidor e instalación de microk8s). A partir de ahí, seguir estos documentos, en este orden:

Primero, las bases de datos:

1. [`databases/ticket-hub-db.md`](./databases/ticket-hub-db.md) — deploy de la base de datos `ticket-hub-db` en microk8s. Es la plantilla que siguen las otras dos, y la que habilita el addon `hostpath-storage` que las tres necesitan.
2. [`databases/pcbox-db.md`](./databases/pcbox-db.md) — deploy de la base de datos `pcbox-db` (tabla `administrations`) en microk8s, namespace `pcbox-api`.
3. [`databases/auth-db.md`](./databases/auth-db.md) — deploy de la base de datos `auth-db` en microk8s, namespace `auth-api`.

Después, Grafana:

4. [`grafana/deploy.md`](./grafana/deploy.md) — deploy de Grafana en microk8s, con sus dashboards y credenciales de admin en un Secret.

Por último, Loki:

5. [`loki/deploy.md`](./loki/deploy.md) — deploy de Loki + Promtail en microk8s, y cómo agregar Loki como datasource en el Grafana ya desplegado. Al terminar, los logs de cualquier Pod del cluster quedan consultables desde Grafana.

Con eso, la infraestructura del cluster ya queda montada. Lo que falta para tener cada app corriendo (su propio Deployment/Service) es el pipeline de CI/CD de cada repo de app — ver `.claude/infra/ci-cd-conventions.md` en `jtagram`.
