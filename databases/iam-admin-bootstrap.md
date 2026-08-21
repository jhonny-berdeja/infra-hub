# Crear el primer usuario ADMIN de `iam` (bootstrap manual)

`iam-api` protege `POST /applications`, `POST /roles` y casi todos los
endpoints de `POST /internal-users` (todo menos `POST /internal-users/login`)
con `@Roles(Role.ADMIN)` — hace falta estar ya logueado como `ADMIN` para
crear una aplicación, un rol o un usuario interno. Como la base `iam` (ver
`jtagram.db.md`) se creó vacía a propósito (no se migraron datos desde
`auth-db`), no existe ningún usuario todavía — y sin usuario no hay forma de
loguearse para crear el primero. Es el mismo problema del huevo y la
gallina de siempre, y no hay una ruta de API pensada para resolverlo: se
resuelve por SQL directo, igual que cualquier otro cambio manual sobre esta
base (mismo criterio que los `ALTER TABLE` de `auth-db.md`/`pcbox-db.md`/
`ticket-hub-db.md`, pero acá es un `INSERT`, no un cambio de esquema).

Este documento crea, en un solo paso atómico: la aplicación `iam` en
`apps_applications`, un rol `ADMIN` para esa aplicación, el primer
`internal_user` (una persona, no un `apps_user`), y le asigna tanto el
acceso a la aplicación como el rol.

## 0. Punto de partida

Asume que `jtagram.db.md` ya está completo — el Pod `postgres` corriendo en
el namespace `databases`, con la base `iam` ya creada — y que `iam-api` ya
está desplegado en el namespace `iam-api` (ver
`infra-hub/apps/iam-api/`). Conectate por SSH al servidor:

```bash
ssh -i deploy_key jhon@IP_TAILSCALE
```

## 1. Generar el hash bcrypt de la contraseña

`internal_users.password` guarda un hash bcrypt (`VARCHAR(60)`), nunca la
contraseña en texto plano — mismo criterio que `apps_users.cliente_secret`
en `auth-db.md`. Generalo usando el propio Pod de `iam-api`, que ya trae
`bcrypt` como dependencia (`package.json`) — así la contraseña en texto
plano no pasa por ningún lado más que tu propia terminal:

```bash
microk8s kubectl exec -it -n iam-api deployment/iam-api -- \
  node -e "require('bcrypt').hash(process.argv[1], 10).then(h => console.log(h))" 'TU_PASSWORD_AQUI'
```

Copiá el hash que imprime (empieza con `$2b$10$...`).

## 2. Conectarte a la base `iam`

Usá tu `POSTGRES_USER` real (el mismo que quedó en el Secret
`postgres-credentials` del namespace `databases`) en vez de `usuario_db`:

```bash
microk8s kubectl exec -it -n databases deployment/postgres -- psql -U usuario_db -d iam
```

## 3. Crear la aplicación, el rol, el usuario y sus asignaciones

Todo en un único `INSERT` encadenado con CTEs de escritura (`WITH ... AS
(INSERT ... RETURNING ...)`) — o entra todo, o no entra nada, sin estados
intermedios a mano. Reemplazá `name`/`lastname` (máx. 15 caracteres cada
uno — mismo ancho que `ticket-hub-db.users.name`/`lastname`), `email` (máx.
30) y el hash del paso 1:

```sql
WITH app AS (
  INSERT INTO apps_applications (name, description)
  VALUES ('iam', 'Panel de administracion IAM del ecosistema jtagram')
  RETURNING id
), role AS (
  INSERT INTO apps_roles (application_id, name, description)
  SELECT id, 'ADMIN', 'Acceso total al panel de administracion IAM'
  FROM app
  RETURNING id, application_id
), usr AS (
  INSERT INTO internal_users (name, lastname, email, password)
  VALUES ('TuNombre', 'TuApellido', 'tu@email.com', '$2b$10$PEGAR_EL_HASH_ACA')
  RETURNING id
), access AS (
  INSERT INTO internal_users_applications (internal_user_id, application_id)
  SELECT usr.id, app.id FROM usr, app
  RETURNING internal_user_id
)
INSERT INTO internal_users_roles (internal_user_id, application_id, role_id)
SELECT usr.id, role.application_id, role.id
FROM usr, role;
```

> **Por qué `'iam'` como nombre de aplicación:** tiene que coincidir
> exactamente con `IAM_APPLICATION_NAME` en el Secret `iam-credentials`
> (namespace `iam-api`, ver `infra-hub/apps/iam/secret.example.yaml`) — es
> el valor que el frontend `iam` manda como header `X-Application-Name` en
> cada login, y contra el que `InternalUsersLoginService` verifica el
> acceso. Si ya creaste ese Secret con otro valor, usá ese mismo acá en vez
> de `'iam'`.

## 4. Verificar

```sql
SELECT * FROM apps_applications;

SELECT iu.email, r.name AS rol
FROM internal_users iu
JOIN internal_users_roles ir ON ir.internal_user_id = iu.id
JOIN apps_roles r ON r.id = ir.role_id;
```

La segunda consulta debería devolver una fila: tu email, rol `ADMIN`.

## 5. Datos producidos por este proceso

| Dato | Qué es | Para qué sirve |
|---|---|---|
| Fila en `apps_applications` (`name = 'iam'`) | La aplicación que representa al propio frontend `iam` dentro del ecosistema de `iam-api` | Es lo que valida `X-Application-Name` en cada login de `iam`, y el dueño de cualquier rol futuro que se cree para esta app |
| Fila en `apps_roles` (`name = 'ADMIN'`, `application_id` = el de arriba) | El rol de administrador total sobre `iam` | Habilita, a quien lo tenga asignado, todos los endpoints protegidos con `@Roles(Role.ADMIN)` en `iam-api` |
| Fila en `internal_users` | Tu propio usuario humano, con la contraseña ya hasheada | Es la cuenta con la que te logueás en `iam` desde `POST /internal-users/login` |
| Filas en `internal_users_applications` / `internal_users_roles` | Acceso a la aplicación `iam` + rol `ADMIN` asignado a tu usuario | Sin ambas, el login puede autenticar la contraseña pero el `RolesGuard` va a rechazar cualquier endpoint protegido |

## 6. Pendiente: mismo bootstrap para las demás apps del ecosistema

Este documento solo registra la aplicación `iam`. Cada app que loguea
contra `iam-api` necesita su propia fila en `apps_applications` (mismo
patrón: `INSERT` + rol + asignación), porque la base `iam` se creó vacía
— no se migraron los datos de `auth-db`. Quedan pendientes, con el mismo
procedimiento de este documento:

- **`ticket-hub`** (frontend): aplicación `'ticket-hub'`, reusando el
  mismo `internal_user` ya creado acá en vez de crear uno nuevo.
- **`pcbox-api`** (M2M): este caso es distinto — no es un `internal_user`
  sino un `apps_user` (login vía `POST /apps-users/login`, no
  `/internal-users/login`), con su propio `cliente_id`/`cliente_secret`.
  Lo usa `ticket-hub-api` (`PcboxApiConnector`) antes de llamar a
  `pcbox-api` — ver el Secret `pcbox-api-notification-credentials` en el
  namespace `ticket-hub`, que también hay que actualizar con el
  `cliente_id`/`cliente_secret` nuevos una vez creado.
