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
