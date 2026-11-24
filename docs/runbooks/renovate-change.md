# Runbook: change Renovate's schedule, version or global settings

Written 2026-11-24, rewritten that day when Renovate's files moved into this repository. Run on the cluster that
day for the schedule, by the three steps the files then took; the steps below have not yet run on the cluster.

## Why

After this job the cluster runs Renovate with a new schedule, a new Renovate version, or new global settings. All
three are files in `artifacts/renovate/`, so the change is one pull request and one push.

A repository's own `renovate.json` needs none of this. Renovate reads it on every run.

## What it touches

| What | Read or written | Needs |
|---|---|---|
| `artifacts/renovate/cronjob.yaml` or `config.js` | Changed, on a branch | A merge by a member of Owners |
| `platform/renovate-config` in zot | Pushed | A YubiKey, two touches |
| The bot, its token, the team, the branch rules | Never touched | |

## Steps

1. Make the change on a branch. For a new version Renovate opens the pull request itself, on a Monday, and this
   step is done.

   | To change | Edit |
   |---|---|
   | The schedule | `schedule` in `cronjob.yaml`. Keep `timeZone` |
   | The Renovate version | The image tag in `cronjob.yaml`, in both places |
   | Which repositories, or a setting for all of them | `config.js` |

2. Only for a new Renovate version: check who signed the new image. It must print `signed`. Then try the image on
   this repository, from its root. It must print update lines or `up to date`, and no line that starts `!!!`.

   ```sh
   cosign verify \
     --certificate-identity https://github.com/renovatebot/renovate/.github/workflows/build.yml@refs/heads/main \
     --certificate-oidc-issuer https://token.actions.githubusercontent.com \
     "$(yq '.spec.jobTemplate.spec.template.spec.containers[0].image' artifacts/renovate/cronjob.yaml)" >/dev/null && echo signed
   bin/renovate-local "${PWD##*/}"
   ```

3. Commit, push the branch, merge the pull request.

4. YubiKey, two touches. Push the artifact from a clean checkout of `main` at the merge.

   ```sh
   git switch main && git pull --ff-only
   bin/artifact renovate --push
   flux --context dataverket-prod-admin reconcile kustomization renovate --with-source
   ```

## Proof

```sh
kubectl --context dataverket-prod-readers -n renovate get cronjob renovate \
  -o jsonpath='{.spec.schedule} {.spec.timeZone} {.spec.jobTemplate.spec.template.spec.containers[0].image} {.spec.jobTemplate.spec.template.spec.initContainers[0].image}{"\n"}'
```

It prints the new schedule or the new image. The two images are the same. On 2026-11-24 the schedule read
`0 1,7,13,19 * * * Europe/Oslo` after the push.

| Seen | Means |
|---|---|
| The old value | Step 4 was run before the merge of step 3, or Flux has not applied yet |
| Two different images | The tag was changed in one place only. Do step 1 again |
| A schedule that runs at the wrong hours | `timeZone` is missing from the CronJob. A schedule without one is UTC |
| `Renovate stopped early. Repository result: config-validation` in step 2 | The new version does not accept `renovate.json`. The line above names the setting |
| `Renovate's log does not list the updates` in step 2 | The new version writes its log in another form. `bin/renovate-local` needs a change before the version is used |

## Not part of this

A change to what Renovate proposes in one repository, which is that repository's `renovate.json`. A new bot token
(`renovate-token-lost.md`). A new GitHub token (`renovate-bring-up.md`, step 4).
