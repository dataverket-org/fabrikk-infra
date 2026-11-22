# Runbook: move the org runner to a new runner or docker release

Written 2026-11-22. Run that day in a local kind cluster, runner 12.7.3 to 13.2.2 and docker 29.5.2 to 29.10.0, on a
registration made by 12.7.3; not yet run on the cluster.

## Why

The runner executes whatever a workflow in the organization says, beside a privileged docker daemon, so both are
kept current. The runner chart has had no release since 0.7.5, which carries runner 12.7.3; the chart in git stays
as it is and `artifacts/forgejo-runners/recipe/values.yaml` names the two images by tag and digest
(`artifacts/forgejo-runners/README.md`).

## What it touches

| What | Read or written | Needs |
|---|---|---|
| Every workflow file in the `dataverket` organization | Read | Nothing; the forge's API is public |
| `artifacts/forgejo-runners/recipe/values.yaml`, `rendered/` | Written, on a branch | Nothing |
| `platform/forgejo-runners-config` in zot | Pushed | A YubiKey, two touches |
| The runner pod | Replaced; a job that is running is lost | Flux does it |
| The registration (`runner-secret.enc.yaml`), the docker store, the fabrikk release runner | Never touched | |

## Steps

1. Read the notes of every release between the running one and the new one, at
   `https://code.forgejo.org/forgejo/runner/releases`, and for a new major the post at `https://forgejo.org/news/`.
   Write down every command, variable and config key that is removed.

2. Look for each of them in every workflow of the organization, on the default branch. This fetches them all into a
   directory and searches it; the pattern is the list of runner 13, and gets what step 1 found:

   ```sh
   dir=$(mktemp -d) && api=https://git.dataverket.org/api/v1
   for repo in $(curl -s "$api/orgs/dataverket/repos?limit=50" | jq -r '.[].name'); do
     branch=$(curl -s "$api/repos/dataverket/$repo" | jq -r .default_branch)
     for wf in .forgejo/workflows .github/workflows .gitea/workflows; do
       curl -s "$api/repos/dataverket/$repo/contents/$wf?ref=$branch" |
         jq -r 'if type == "array" then .[] | select(.type == "file") | .path else empty end' |
         while read -r path; do
           mkdir -p "$dir/$repo/${path%/*}"
           curl -s -o "$dir/$repo/$path" "https://git.dataverket.org/dataverket/$repo/raw/branch/$branch/$path"
         done
     done
   done
   grep -rnE '::(set-output|set-env|add-path)|GITEA_|DOCKER_USERNAME|DOCKER_PASSWORD|network_mode' "$dir"
   ```

   No output means no workflow it read uses them. It reads the first 50 repositories the forge shows without a
   login: on 2026-11-22 that was 19. A private repository is not among them, and neither is a fifty-first; those
   are read by hand.
   A hit in a repository with Actions switched off, as `incus` and `incus-os` have, does not count. Any other hit is fixed in its repository first, and this job waits for that
   merge. The runner's own config is `runner.config.file` in `values.yaml`; read it against the same list.

3. On a branch, both tags with their digests, and the render:

   ```sh
   crane digest code.forgejo.org/forgejo/runner:<version>
   crane digest docker.io/library/docker:<version>-dind
   $EDITOR artifacts/forgejo-runners/recipe/values.yaml    # image.tag and dind.image.tag, as <tag>@sha256:<digest>
   bin/artifact forgejo-runners
   git diff artifacts/forgejo-runners/rendered/
   ```

   The diff is three `image:` lines, the runner twice and docker once.

4. Scan both, then commit, push, open the pull request and merge it with the forge's button:

   ```sh
   bin/image-scan code.forgejo.org/forgejo/runner:<tag>@sha256:<digest> docker.io/library/docker:<tag>@sha256:<digest>
   ```

5. Pick a moment with no job running; the forge lists them under the organization's Actions. A job that is running
   when the pod stops is lost, and the forge goes on showing it as running until someone cancels it there.

6. YubiKey, two touches. From a clean checkout of `main` at the merge:

   ```sh
   git switch main && git pull --ff-only
   bin/artifact forgejo-runners --push
   flux --context dataverket-prod-admin reconcile kustomization forgejo-runners --with-source
   kubectl --context dataverket-prod-admin -n forgejo-runners rollout status deployment/org-dataverket-runner-forgejo-runner --timeout=180s
   ```

   The old pod stops before the new one starts, and the docker store moves with it: the runner is away for the
   minutes a Cinder detach and attach take.

## Proof

```sh
kubectl --context dataverket-prod-admin -n forgejo-runners logs deployment/org-dataverket-runner-forgejo-runner -c runner --tail=20 | grep 'declared successfully'
```

The line names the runner, the new version and its labels. Then run the `noop` workflow of this repository from
the forge, and one job that uses docker, such as `salmon-pg-validator`'s image build; both must end green.

In kind on 2026-11-22 a registration file made by 12.7.3 was taken by 13.2.2 as it was: `runner: dataverket-runner,
with version: v13.2.2, with labels: [ubuntu-latest], ephemeral: false, declared successfully`, and it took queued
jobs within seconds and ran them, `actions/checkout` from the forge's own actions org included.

| Seen | Means |
|---|---|
| The new pod stays `Pending` on its volume | The old pod still holds the docker store; it lets go when it has stopped (`artifacts/forgejo-runners/README.md`, "Rollouts") |
| `waiting for docker daemon...` and nothing more | The dind container did not start; its log says why |
| A job fails on `::set-output::` or a missing `GITEA_` variable | Step 2 missed a workflow; fix the workflow, the runner stays |
| A job shown as running since before the rollout | It was lost in step 5; cancel it on the forge and run it again |

## Not part of this

The fabrikk release runner, which Flux does not know and the `fabrikk-runner` workflow makes. A new registration:
the `.runner` file is kept as it is. A new chart: `artifacts/forgejo-runners/README.md` says how the tree in git is
replaced, and Renovate proposes its commit once a month.
