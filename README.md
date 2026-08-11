# infra-hub

Central home for Kubernetes manifests and deploy workflows across this
organization's apps. Application repositories (e.g. `ticket-hub-api`) build
and publish their own images; they never hold cluster credentials. Every
manifest and every credential that reaches the cluster (`pcbox`, microk8s)
lives here, gated behind code owner review and a required manual approval.

## Layout

```
apps/<app-name>/
  namespace.yaml        # Namespace for the app (idempotent to apply)
  deployment.yaml        # Deployment, with placeholder image reference
  service.yaml            # Service exposing the app in-cluster
  secret.example.yaml     # Template only — never applied by CI, copy to
                           # secret.yaml and apply manually/out-of-band
```

Each app gets its own directory under `apps/`, mirroring the manifest set
it previously owned in its own repo's `.kubernetes/` (or equivalent)
folder before onboarding here.

### Image reference placeholders

`deployment.yaml` files use two literal placeholders that the deploy
workflow substitutes with `sed` at deploy time, never in git:

- `DOCKERHUB_USER` → `secrets.DOCKERHUB_USERNAME`
- `IMAGE_TAG` → the validated tag carried by the trigger (see below)

This keeps manifests in git environment-neutral; git is never mutated by
CI.

## Deploy flow

Each onboarded app gets its own `deploy-<app-name>.yml` workflow under
`.github/workflows/`. The workflow for `ticket-hub-api` accepts two
triggers, both converging on the same gated deploy job:

1. **`repository_dispatch`** — sent by the app repo's own publish
   workflow after it pushes a new image to Docker Hub. Payload:

   ```json
   { "event_type": "deploy-<app-name>",
     "client_payload": { "image_tag": "master" } }
   ```

2. **`workflow_dispatch`** — manual fallback, with an optional
   `image_tag` input (defaults to `master`).

Both paths resolve to the same tag variable, which is validated by
`scripts/validate-image-tag.sh` (regex `^[a-zA-Z0-9._-]{1,128}$`,
fail-closed) before anything else happens — no cluster credential is
written to disk if the tag is malformed.

The deploy job declares `environment: production`, so **every** run — no
matter which trigger started it — pauses in "Waiting" until a required
reviewer approves. Only after approval does the job:

1. Join the tailnet (`tailscale/github-action@v4`, `tag:continuous-integration`).
2. Write the `KUBECONFIG_PCBOX` secret to `~/.kube/config` (`chmod 600`).
3. Run `kubectl get nodes` to fail fast if the cluster isn't reachable.
4. Copy the app's manifests to `/tmp`, substitute placeholders, and
   `kubectl apply -f` the substituted copy.
5. Run `kubectl rollout restart` followed by `kubectl rollout status
   --timeout=180s`. Tags are mutable (always `master` in practice for
   `ticket-hub-api`), so a re-deploy of the same tag produces no diff on
   `apply` alone — the explicit restart is what forces Pods to pull the
   new image digest (`imagePullPolicy: Always`).
6. Verify the deployment/pods/service, and print diagnostics on failure.

## Redeploying manually

Run the app's `deploy-<app-name>.yml` workflow via `workflow_dispatch`
from the Actions tab, optionally overriding `image_tag`. The run will
still pause for approval before touching the cluster.

## Required secrets (per app onboarded)

| Secret | Used for |
|--------|----------|
| `TS_OAUTH_CLIENT_ID` / `TS_OAUTH_SECRET` | Joining the tailnet as `tag:continuous-integration` |
| `KUBECONFIG_PCBOX` | Authenticating `kubectl` against pcbox over Tailscale |
| `DOCKERHUB_USERNAME` | Substituted into the image reference placeholder |

These are repo-level secrets on `infra-hub` itself — the app repo (e.g.
`ticket-hub-api`) holds its own separate `DOCKERHUB_USERNAME` /
`DOCKERHUB_TOKEN` / dispatch token for publishing, and never sees these.

## Manual setup checklist (not code — GitHub settings)

- [ ] Create repo secrets on `infra-hub`: `TS_OAUTH_CLIENT_ID`,
      `TS_OAUTH_SECRET`, `KUBECONFIG_PCBOX`.
- [ ] Configure branch protection on `master`: require PR + code owner
      review.
- [ ] Configure the `production` Environment's required reviewers — the
      same group as `CODEOWNERS`.
- [ ] Assign the real `CODEOWNERS` handle once the leads/managers team is
      decided (see `CODEOWNERS` — it currently ships with a placeholder
      only).
- [ ] On the app repo side: create its publish workflow, its own Docker
      Hub / dispatch secrets, and confirm the public Docker Hub
      repository exists.
- [ ] Prove the path once via `workflow_dispatch` before relying on the
      automatic `repository_dispatch` trigger.

## Ownership

See `CODEOWNERS`. All manifest and workflow paths require code owner
review before merge, and the `production` Environment gate requires
approval from the same group before any deploy touches the cluster.
