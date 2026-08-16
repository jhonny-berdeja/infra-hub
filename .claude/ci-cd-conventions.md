# Convenciones de CI/CD (workflows y arquitectura de deploy)

Aplica a cualquier repo de este ecosistema que build-y-dispare un deploy
hacia un repo central de infraestructura — no es específico de este
proyecto puntual.

## Nombramiento y organización de steps en workflows de GitHub Actions

1. **`name:` de jobs y steps son oraciones completas, en inglés,
   terminadas en punto.** No etiquetas cortas tipo "Checkout" — la
   acción completa, como si fuera la única documentación que alguien va
   a leer antes de entrar al detalle. Ej.: `"Clone the repository to
   access the code and scripts."`, no `"Checkout"`.

2. **El nombre dice qué hace el step y, cuando aplica, dónde queda el
   resultado.** Si un step escribe a `$GITHUB_ENV`, `$GITHUB_OUTPUT` o
   `$GITHUB_STEP_SUMMARY`, el nombre lo menciona explícitamente (ej.
   `"Save tag value to GITHUB_OUTPUT file."`) — el nombre reemplaza al
   comentario para el caso simple de "qué hace esto".

3. **Un step, una responsabilidad, una escritura.** Nunca mezclar
   "calcular algo" + "transformarlo" + "exponerlo" en un solo step.
   Partirlo en steps atómicos encadenados:
   - `$GITHUB_ENV` para pasar un valor a los steps siguientes *del mismo
     job* (el step que escribe no puede leer su propio valor todavía —
     recién el próximo step lo tiene disponible).
   - `$GITHUB_OUTPUT` + `id: <nombre>` solo en el step final que
     necesita que *otro job* lea ese valor vía
     `needs.<job>.outputs.<nombre>` — es el único caso que realmente
     necesita `id:`.

4. **Decisión pendiente, a resolver cuando se adopte esta convención en
   un repo**: si además de los nombres descriptivos se mantienen
   comentarios explicando el *por qué* de una decisión no obvia (el
   motivo de un gate, el scope de un token, etc.), o si el nombre
   descriptivo alcanza y el comentario queda reservado solo para
   decisiones que un nombre no puede transmitir.

## Extracción de lógica no trivial a scripts `.sh`

Cualquier `run:` que tenga un loop, un `curl`, un condicional, o más de
un comando encadenado, sale del YAML a un script propio en `scripts/`,
testeado aparte. El step queda reducido a invocar ese script — ideal,
en una sola línea.

1. **Un script, una responsabilidad.** Es la regla de "un step, una
   escritura" (arriba) llevada un nivel más profundo: si extraer a un
   script no alcanza para que el step vuelva a ser una sola
   responsabilidad, el script mismo está haciendo de más y hay que
   partirlo en más de uno.

2. **La frontera de la división es calcular vs. persistir.** Los
   scripts imprimen su resultado a **stdout**; el YAML es quien decide
   dónde va eso (`>> "$GITHUB_ENV"`, `> archivo`, `>> "$GITHUB_STEP_SUMMARY"`).
   Ningún script escribe directo a `$GITHUB_ENV` ni a
   `$GITHUB_STEP_SUMMARY` — eso es responsabilidad exclusiva del step
   que lo llama, así el script sigue siendo reusable sin importar a
   dónde vaya a parar su output.

3. **Reuso en vez de duplicar.** Si dos steps necesitan la misma lógica
   con una variación chica (ej. filtrar una lista "quedándose con" vs.
   "sacando" un set de elementos), es un solo script con un parámetro
   de modo, llamado dos veces distinto — no dos scripts casi iguales.

4. **Composición entre scripts.** Un script puede llamar a otro más
   chico y específico en vez de reimplementar su lógica — resolviendo
   su propio directorio primero, para no depender de dónde esté parado
   quien lo invoca:
   ```bash
   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
   "$SCRIPT_DIR/otro-script.sh" "$ARG"
   ```

5. **`scripts/` vive hermano de `workflows/`, dentro de `.github/`.**
   No en la raíz del repo — solo lo usan los workflows, así que queda
   `.github/scripts/` (con `.github/scripts/tests/` adentro). Los
   `run:` referencian el path completo: `.github/scripts/algo.sh`.

## Separar "chequear" de "exigir": patrón checker + assert

Cuando una validación tiene que poder fallar en las dos direcciones
según el caso (un tag que *no debe* existir todavía vs. uno que *sí
debe* existir ya), no se escribe el `if`/mensaje/`exit 1` inline en el
YAML, ni se duplica el script de chequeo una vez por dirección.

1. **El script "checker" es puro y booleano.** Solo responde "existe o
   no" vía exit code (0 = sí, 1 = no) — no imprime mensajes de error de
   negocio, no sabe si el llamador esperaba que existiera o no. Ej.:
   `git-tag-exists.sh <tag>`, `docker-hub-tag-exists.sh <repo> <tag>`.

2. **El script "assert" envuelve al checker y agrega el modo.** Recibe
   `exists`/`not-exists` como primer argumento, llama al checker, y
   recién ahí decide si eso es una falla — con el mensaje de error
   específico para esa dirección. Ej.: `assert-git-tag-existence.sh
   exists v1.0.0` vs. `assert-git-tag-existence.sh not-exists v1.0.0`.

3. **El step del YAML queda en una sola línea**, sin `if`/`exit` visible:
   ```yaml
   run: .github/scripts/assert-git-tag-existence.sh not-exists "$NEW_TAG"
   ```

Esta separación evita dos problemas a la vez: reimplementar el mismo
chequeo booleano dos veces (una por dirección), y ensuciar el YAML con
lógica condicional que después hay que testear por separado del resto.

## Disparar y esperar un workflow en otro repo

`gh workflow run` es **fire-and-forget** — devuelve apenas GitHub
acepta el pedido, no cuando el workflow disparado termina. Si un job
siguiente depende de que ese otro workflow haya salido bien (no solo
de que se haya disparado), hace falta un paso extra:

1. **Guardar un timestamp UTC justo antes de disparar** (`date -u
   +%Y-%m-%dT%H:%M:%SZ`), en su propio step. Sirve para encontrar el
   run correcto después, sin agarrar por error uno viejo de otra
   persona.

2. **Buscar el run recién disparado filtrando por ese timestamp**, no
   por "el último de la lista" a secas — `gh run list --json
   databaseId,createdAt | jq '[.[] | select(.createdAt >= $since)] |
   sort_by(.createdAt) | .[0].databaseId'`. Con reintentos cortos
   (unos segundos entre cada uno): el run tarda un rato en aparecer
   listado después del dispatch.

3. **Bloquear con `gh run watch <id> --exit-status`** — esto sí espera
   a que termine, y devuelve código de error si el run remoto falló.
   Como vive en el mismo `run:` que hizo el dispatch, propaga la falla
   al job actual: si el otro workflow falla, este job también queda en
   rojo, y cualquier job siguiente que dependa de él (`needs:`) no
   corre.

4. **Retries/sleep parametrizables por variable de entorno**, con
   default razonable en producción — así el test del script no tiene
   que dormir de verdad para cubrir el caso "nunca aparece".

## Visibilidad de dependencias entre workflows

Cuando un job dispara y depende de un workflow en OTRO repo, la
persona que lo mira tiene que enterarse de eso sin adivinar ni ir a
buscar en los logs.

1. **`::notice::` para un cartel visible en la corrida**, posteado
   ANTES del step que bloquea esperando el resultado (no después) —
   así se ve apenas arranca, y sigue estando si el wait termina
   fallando:
   ```bash
   echo "::notice title=Título::Mensaje con el link: https://..."
   ```

2. **`environment: { name, url }` como segunda superficie**, no
   reemplaza al notice — agrega un botón "View deployment" nativo de
   GitHub, visible en la sección Environments del repo y en el grafo
   del run. Confirmado con la API real: el `environment_url` queda
   vacío mientras el job espera aprobación (`state: waiting`) — recién
   se completa cuando el job termina de ejecutar, no antes.

3. **El nodo del job en el grafo no soporta mensajes ni tooltips
   custom** — solo nombre y estado. Ningún truco de YAML cambia eso;
   `::notice::` y `environment.url` son los mecanismos reales que
   GitHub expone, ninguno vive *dentro* del cuadradito del nodo.

## Nombramiento de scripts `.sh` y sus variables

1. **Archivos: kebab-case, verbo primero** (`validate-`, `build-`,
   `call-`, `list-`, `filter-`, `delete-`, `render-`...).

2. **El nombre dice con qué sistema habla, no solo qué hace.** Un
   script que le pega a un servicio externo lo nombra explícito y
   completo — no una abreviación ambigua. Ej.: si el servicio es
   "Docker Hub", el nombre dice `docker-hub`, no solo `hub` (que podría
   ser cualquier cosa). Un script que es lógica pura local (validar un
   formato, filtrar un archivo, armar texto) NO lleva el nombre del
   servicio externo — sería mentir sobre lo que hace.

3. **El nombre del archivo se repite como prefijo en sus propios
   mensajes de error** (`echo "nombre-del-script: mensaje" >&2`).
   Renombrar un script implica actualizar ese prefijo también, no solo
   el nombre del archivo.

4. **Variables en `SCREAMING_SNAKE_CASE`, y el nombre codifica estado
   cuando importa.** Un valor que todavía no pasó una validación se
   llama `UNVALIDATED_ALGO`, no `ALGO` — el nombre avisa que no es
   seguro confiar en él todavía.

5. **Nada de nombres genéricos que solo se entienden con el resto del
   script alrededor.** `MODE`, `RESPONSE`, `VALUE` no dicen nada por sí
   solos — `FILTER_MODE`, `PAGE_RESPONSE` sí.

6. **El mismo concepto usa siempre la misma palabra, en todos los
   scripts.** Si `TAG_FILE` significa "archivo con una lista de tags"
   en un script, significa lo mismo en todos — así no hay que
   reaprender vocabulario al saltar de uno a otro. Cuando hay más de un
   archivo del mismo tipo en juego dentro del mismo script, cada uno
   tiene su propio nombre preciso en vez de reusar el genérico
   (`KEEP_TAG_FILE` / `DELETE_TAG_FILE`, no dos `TAG_FILE`).

## Tests de scripts `.sh`

1. **Separados físicamente en `scripts/tests/`**, no mezclados con los
   scripts que prueban. Cada test resuelve el path a su target un nivel
   arriba: `TARGET="$SCRIPT_DIR/../nombre-del-script.sh"`.

2. **Estilo tabla, con contador de pass/fail.** Cada caso imprime
   `PASS`/`FAIL` con una etiqueta corta describiendo qué caso es: el
   test final imprime el conteo y el exit code del harness refleja
   `[ "$fail" -eq 0 ]`.

3. **Nunca hay una llamada de red real en un test.** Si el script llama
   `curl`, el test lo stubea armando un ejecutable falso en un
   directorio temporal y anteponiéndolo al `PATH`, devolviendo
   respuestas fijas.

4. **Se prueba tanto el camino feliz como los de rechazo** — un
   argumento faltante, un input inválido, un archivo que no existe —
   nunca solo el caso de éxito.

## Seguridad y robustez en scripts `.sh`

1. **`set -euo pipefail` en todo script externo**, siempre. No es
   redundante con el `bash -e -o pipefail` implícito de GitHub Actions
   — ese wrapper implícito solo aplica a bloques `run:` inline, nunca a
   un script externo invocado desde uno (corre como su propio proceso).
   Sin esto, un `curl` que falla adentro del script no corta la
   ejecución.

2. **Ningún input de texto libre (`workflow_dispatch`, etc.) se pega
   directo como `${{ }}` en un `run:`.** Siempre pasa primero por
   `env:`, incluso para valores que "parecen" inofensivos (un username,
   por ejemplo) — consistencia en todo el archivo cierra la superficie
   de inyección de una sola vez, en vez de caso por caso.

3. **Todo input de texto libre pasa por un script `validate-*.sh`**
   antes de llegar a cualquier comando de shell que lo use.

4. **Un secret calculado en runtime (no un `secrets.*` registrado, ej.
   un JWT que devuelve un login) se enmascara explícito con
   `::add-mask::` antes de que quede expuesto en cualquier lado** — el
   masking automático de GitHub Actions solo cubre `secrets.*`, nunca
   un valor derivado en el momento.

5. **`jq -n` necesita `-c` explícito si su salida va a `$GITHUB_ENV`.**
   Sin el flag, el pretty-print multilínea que trae por default rompe
   el formato `CLAVE=valor` de ese archivo.

6. **`fetch-tags: true` solo no alcanza para validar tags de git.** Con
   el `fetch-depth: 1` shallow por default, el checkout trae la
   referencia del tag pero no necesariamente el objeto commit al que
   apunta (si ese commit ya no es la punta de la rama). Un chequeo de
   existencia contra un tag real puede dar falso negativo. Hace falta
   `fetch-depth: 0` (historia completa) en el job que necesite
   confiar en `git tag`/`git rev-parse` contra tags existentes.

## Por qué los manifests de Kubernetes no viven en el repo de la app

Cada repo de app (build) nunca tiene sus propios manifests de
Kubernetes ni credenciales de cluster — solo buildea su imagen, la
pushea a Docker Hub, y dispara un deploy en un repo central de
infraestructura (hoy: `infra-hub`) que sí los tiene, bajo
`apps/<nombre-de-la-app>/`. Tres motivos, no es una preferencia
estética:

1. **Evita que alguien modifique el deploy sin querer.** Quien trabaja
   el código de la app día a día no tiene motivo para tocar YAML de
   Kubernetes — si vive en el mismo repo, un cambio accidental es
   demasiado fácil.

2. **Gobernanza separada.** El repo de infra tiene su propio
   `CODEOWNERS` + branch protection (restringido a líderes/gerentes),
   independiente de quién puede aprobar cambios de código de cada app.
   Si el manifest viviera en el repo de la app, ese límite de
   aprobación para infraestructura desaparece.

3. **Los secretos de cluster nunca tocan el repo de la app.** El puente
   entre el repo de la app y el repo de infra es un PAT *fine-grained*
   con scope `actions: write` únicamente (puede disparar un workflow ya
   existente, no puede leer ni modificar ningún archivo — verificado
   contra la documentación de la API de GitHub). El repo de la app
   jamás tiene el token de Tailscale ni el kubeconfig del cluster.

En una frase: **build vive con el código, deploy vive centralizado.**

## Mantener sincronizada la documentación de secrets

`.github/workflows/.env.secrets.example` y `.github/workflows/obtain-secrets.md`
son la referencia de qué secrets usan los workflows y cómo conseguirlos.
Se desactualizan solos si un cambio a un workflow no los toca en el mismo PR.

1. **Agregar un `secrets.ALGO` nuevo a cualquier workflow de este
   directorio implica, en el mismo cambio:**
   - Sumar la entrada correspondiente a `.env.secrets.example`, con el
     comentario indicando en qué workflow(s) se usa.
   - Sumar una sección a `obtain-secrets.md` explicando cómo obtener ese
     valor y dónde guardarlo.
2. **Sacar un `secrets.ALGO` de todos los workflows que lo usaban implica
   borrar su entrada de ambos archivos** — no dejar documentación de un
   secret que ya no hace falta.
3. **Renombrar un secret o agregarlo a un workflow adicional** actualiza
   el comentario de "Used by" en `.env.secrets.example` para que siga
   reflejando la lista real de workflows que lo usan.
