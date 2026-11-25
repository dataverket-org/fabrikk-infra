# Runbook: move the forge to a new Forgejo release

Written 2026-11-22 from a run in a local kind cluster, 15.0.11 to 15.0.12 on a database with repositories in it.
Run on `git.dataverket.org` on 2026-11-24 for the same versions.

## Why

A Forgejo patch release is how the forge gets its security fixes, and 15.0.12 of 2026-11-18 carried five of them.
The chart is rendered in the factory (decision 028), so an upgrade is a new chart version in the recipe, a new
`rendered/`, a merge and a push of the artifact. The forge stays on the v15 LTS line, supported until 2027-07-15; a
new major is a decision of its own and not this job.

## What it touches

| What | Read or written | Needs |
|---|---|---|
| `artifacts/forgejo/recipe/kustomization.yaml`, `artifacts/forgejo/rendered/`, `artifacts/forgejo-theme/rendered/` | Written, on a branch | Nothing; `code.forgejo.org`, `codeberg.org` and the forge must answer |
| The database `forgejo-postgres` | A base backup taken by you; its schema migrated by Forgejo on first start, when the release has a migration | `dataverket-prod-admin` (`task admin:start`) |
| `platform/forgejo-theme-config` and `platform/forgejo-config` in zot | Pushed | A YubiKey, two touches each |
| The forge pod | Replaced; the forge is away for about a minute | Flux does it |
| The database's Postgres and its archive, the runner, `*.enc.yaml`, `.sops.yaml` | Never touched | |

## Steps

1. Read what the release changes. The notes of every version between the running one and the new one, at
   `https://codeberg.org/forgejo/forgejo/src/branch/forgejo/release-notes-published/<version>.md`, and the chart's at
   `https://code.forgejo.org/forgejo-helm/forgejo-helm/releases`. A line under "upgrade" or "breaking" is a step to
   add here before going on. What runs now:

   ```sh
   curl -s https://git.dataverket.org/api/v1/version
   ```

2. On a branch, name the chart version that carries the release and render the forge and then the theme, which
   takes its locale from the release:

   ```sh
   git switch -c forgejo-<version>
   $EDITOR artifacts/forgejo/recipe/kustomization.yaml     # helmCharts[0].version
   bin/artifact forgejo
   bin/artifact forgejo-theme
   git diff --stat artifacts/
   ```

   For a patch release the diff of `rendered/` is the image tag, the `version` and `helm.sh/chart` labels, and
   `checksum/config`. Any other line is a change the chart made; read it against the chart's notes before going on.

3. Scan the new image. It prints what is still open and what `share/image-scan-accepted` covers:

   ```sh
   bin/image-scan code.forgejo.org/forgejo/forgejo:<version>-rootless
   ```

   An `OPEN` line is either fixed by a newer release, which is then the one to take, or accepted in the same pull
   request with a last day (`image-scan.md`).

4. Commit, push the branch, open the pull request and merge it with the forge's button, which signs the merge
   (decision 036). `check / artifacts` must be green: it proves `rendered/` true to the recipe.

5. `dataverket-prod-admin`. Take a base backup and wait for `completed`; a release may migrate the database on its
   first start, and this is the point to return to:

   ```sh
   kubectl --context dataverket-prod-admin apply -f - <<EOF
   apiVersion: postgresql.cnpg.io/v1
   kind: Backup
   metadata:
     name: forgejo-postgres-before-upgrade-$(date -u +%Y%m%d%H%M)
     namespace: forgejo
   spec:
     cluster:
       name: forgejo-postgres
     method: plugin
     pluginConfiguration:
       name: barman-cloud.cloudnative-pg.io
   EOF
   kubectl --context dataverket-prod-admin -n forgejo get backup --sort-by=.status.startedAt | tail -2
   ```

6. YubiKey, two touches for each artifact. From a clean checkout of `main` at the merge, the theme first, since
   the forge's Kustomization waits for it:

   ```sh
   git switch main && git pull --ff-only
   bin/artifact forgejo-theme --push
   bin/artifact forgejo --push
   ```

7. Flux applies within ten minutes; to have it now, and to watch:

   ```sh
   flux --context dataverket-prod-admin reconcile kustomization forgejo --with-source
   kubectl --context dataverket-prod-admin -n forgejo rollout status deployment/forgejo --timeout=180s
   ```

   The Deployment is `Recreate` on one volume: the old pod stops, the volume moves, the new pod starts. In kind the
   new pod was ready 23 seconds after the apply; on the cluster on 2026-11-24, with the Cinder detach and attach, it
   took about 50 seconds.

## Proof

```sh
curl -s https://git.dataverket.org/api/v1/version
curl -s https://git.dataverket.org/api/v1/signing-key.ssh
```

The first prints the new version, the second the key in `apps/forgejo/README.md`. Then push a commit to any
repository and merge one pull request with the forge's button; the merge commit must be signed by the forge:

```sh
curl -s "https://git.dataverket.org/api/v1/repos/<owner>/<repo>/commits?limit=1" | jq '.[0].commit.verification | {verified, reason}'
```

In kind on 2026-11-22 this held after the upgrade, the repositories made before it were all there, and the forge
answered its API a few seconds after the pod was `Ready`, so a first `curl` that fails is asked again.

| Seen | Means |
|---|---|
| The old version | Flux has not applied yet, or the artifact was pushed from a checkout that was not at the merge; `flux --context dataverket-prod-readers get kustomization forgejo` shows the revision |
| The pod in `CrashLoopBackOff` with a migration error in its log | The release cannot migrate this database. Stop, and return to the backup of step 5 (`backup/cnpg-backups.md`, "Restore") |
| `check / artifacts` red on the pull request | `rendered/` was not rendered from this recipe; run step 2 again on the branch |
| The landing page in Forgejo's own words | The theme's locale is of another release; `bin/artifact forgejo-theme --check` says so. Render and push the theme, then restart the pod |

## Not part of this

A new Forgejo major: no chart carries one past v15 today, and it is a decision, with its own test. The database's
Postgres (`postgres-minor-upgrade.md`). The runner (`runner-upgrade.md`). The signing key, which an upgrade does not
touch (`forge-signing-key.md`).
