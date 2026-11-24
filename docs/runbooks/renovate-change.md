# Runbook: change Renovate's schedule, version or global settings

Written 2026-11-24. Run that day on the cluster for the schedule: from once an hour to four runs a day.

## Why

After this job the cluster runs Renovate with a new schedule, a new Renovate version, or new global settings. These
three live in the renovate repository's `kube/`, and this repository pins one commit of it. So a change takes three
steps: merge it there, pin it here, push the artifact.

A repository's own `renovate.json` needs none of this. Renovate reads it on every run.

## What it touches

| What | Read or written | Needs |
|---|---|---|
| `kube/` in `dataverket/renovate` | Changed, on a branch | A merge by a member of Owners |
| `artifacts/renovate/recipe/source.env` and `artifacts/renovate/rendered/` | Written, on a branch | Nothing |
| `platform/renovate-config` in zot | Pushed | A YubiKey, two touches |
| The bot, its token, the team, the branch rules | Never touched | |

## Steps

1. Change `kube/cronjob.yaml` or `kube/config.js` in the renovate repository, on a branch. Merge the pull request.
   Note the merge commit.

   ```sh
   git ls-remote https://git.dataverket.org/dataverket/renovate.git refs/heads/main
   ```

2. Pin that commit here, on a branch, and render. The diff of `rendered/` must show your change and nothing else.

   ```sh
   git switch -c renovate-<what changed>
   $EDITOR artifacts/renovate/recipe/source.env      # RENOVATE_COMMIT=<the merge commit>
   bin/artifact renovate
   git diff artifacts/renovate/rendered/
   ```

3. Only for a new Renovate version: check who signed the new image. It must print `signed`.

   ```sh
   cosign verify \
     --certificate-identity https://github.com/renovatebot/renovate/.github/workflows/build.yml@refs/heads/main \
     --certificate-oidc-issuer https://token.actions.githubusercontent.com \
     "$(yq '.spec.jobTemplate.spec.template.spec.containers[0].image' artifacts/renovate/rendered/batch_v1_cronjob_renovate.yaml)" >/dev/null && echo signed
   ```

4. Commit, push the branch, merge the pull request.

5. YubiKey, two touches. Push the artifact from a clean checkout of `main` at the merge.

   ```sh
   git switch main && git pull --ff-only
   bin/artifact renovate --push
   flux --context dataverket-prod-admin reconcile kustomization renovate --with-source
   ```

## Proof

```sh
kubectl --context dataverket-prod-readers -n renovate get cronjob renovate \
  -o jsonpath='{.spec.schedule} {.spec.timeZone} {.spec.jobTemplate.spec.template.spec.containers[0].image}{"\n"}'
```

It prints the new schedule or the new image. On 2026-11-24 it printed `0 1,7,13,19 * * * Europe/Oslo` after step 5.

| Seen | Means |
|---|---|
| The old value | Step 5 was run before the merge of step 4, or Flux has not applied yet |
| `check / artifacts` red on the pull request | `rendered/` was not made from the pinned commit. Do step 2 again |
| A schedule that runs at the wrong hours | `timeZone` is missing from the CronJob. A schedule without one is UTC |

## Not part of this

A change to what Renovate proposes in one repository, which is that repository's `renovate.json`. A new bot token
(`renovate-token-lost.md`). A new GitHub token (`renovate-bring-up.md`, step 4).
