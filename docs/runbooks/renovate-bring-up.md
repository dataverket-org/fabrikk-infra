# Runbook: bring Renovate up on a cluster

Written 2026-11-22, rewritten 2026-11-24. Steps 1, 2 and 4 have run on the cluster. The team of step 3 was made in
the browser there; its two commands have run against a throwaway forge only.

## Why

After this job Renovate runs in the cluster four times a day and can read GitHub. It cannot write to any repository
yet; `renovate-repository.md` gives it one. The job makes three things: the artifact in the cluster, the team on the
forge, and the GitHub token. Reasons and facts are in `artifacts/renovate/README.md`.

## What it touches

| What | Read or written | Needs |
|---|---|---|
| `platform/renovate-config` in zot | Pushed | A YubiKey, two touches per push |
| The user `renovate` and Secret `renovate/renovate` | Made by the Job `renovate-bootstrap` | Nothing; Flux applies it |
| The team `renovate` in the organization `dataverket` | Made on the forge | The `forgejo` definition's token, through swamp |
| `artifacts/renovate/renovate-github.enc.yaml` | Written | A GitHub token with no permissions; a YubiKey touch for the check |
| `.sops.yaml`, `vaults/`, any other Secret | Never touched | |

## Steps

1. Check who signed the Renovate image. It must print `signed`.

   ```sh
   cosign verify \
     --certificate-identity https://github.com/renovatebot/renovate/.github/workflows/build.yml@refs/heads/main \
     --certificate-oidc-issuer https://token.actions.githubusercontent.com \
     "$(yq '.spec.jobTemplate.spec.template.spec.containers[0].image' artifacts/renovate/cronjob.yaml)" >/dev/null && echo signed
   ```

2. YubiKey, two touches. Push the artifact from a clean checkout of `main`. The log must end
   `renovate/renovate created`.

   ```sh
   bin/artifact renovate --push
   flux --context dataverket-prod-admin reconcile kustomization apps --with-source
   flux --context dataverket-prod-admin reconcile kustomization renovate --with-source
   kubectl --context dataverket-prod-admin -n renovate logs job/renovate-bootstrap
   ```

3. Make the team and put the bot in it. Each must report `created` or `added`, or `unchanged` on a rerun.

   ```sh
   swamp behavior run forgejo team_ensure --input org=dataverket --input name=renovate \
     --input 'unitsMap={"repo.code":"write","repo.pulls":"write","repo.issues":"write"}'
   swamp behavior run forgejo team_member_ensure --input org=dataverket --input team=renovate --input username=renovate
   ```

4. Make the GitHub token. A person does this at github.com: Settings, Developer settings, Fine-grained tokens.

   | Field | Value |
   |---|---|
   | Resource owner | The account itself, not an organization |
   | Repository access | Public repositories (read-only) |
   | Permissions | None |

   Copy the token. Pipe it from the clipboard into the cluster file (`pbpaste` for `wl-paste -n` on macOS):

   ```sh
   wl-paste -n | kubectl create secret generic renovate-github --namespace renovate \
       --from-file=RENOVATE_GITHUB_COM_TOKEN=/dev/stdin --dry-run=client -o yaml |
     sops encrypt --filename-override artifacts/renovate/renovate-github.enc.yaml \
       --input-type yaml --output-type yaml /dev/stdin > artifacts/renovate/renovate-github.enc.yaml
   ```

   YubiKey, one touch. Check the token without showing it. It must print `"limit": 5000`.

   ```sh
   sops -d --extract '["data"]["RENOVATE_GITHUB_COM_TOKEN"]' artifacts/renovate/renovate-github.enc.yaml |
     base64 -d | sed 's/^/Authorization: Bearer /' |
     curl -sS -H @- https://api.github.com/rate_limit | jq '{limit: .rate.limit, message}'
   ```

   Commit the file on a branch, merge it, and do step 2 again.

## Proof

```sh
kubectl --context dataverket-prod-readers -n renovate get cronjob renovate -o jsonpath='{.spec.schedule} {.spec.timeZone}{"\n"}'
```

It prints `0 1,7,13,19 * * * Europe/Oslo`. Then start a run as `renovate-run-now.md` says, steps 1 to 4. The guard
prints
`guard: renovate can write to 0 repositories and reaches the default branch of none`.

| Seen | Means |
|---|---|
| `"limit": 60` in step 4 | The file holds no token. Do step 4 again |
| `"message": "Bad credentials"` in step 4 | The clipboard did not hold the token. Do step 4 again |
| The pod of a run is `Pending` for half a minute | The Renovate image, 1.4 GB, is being pulled |
| The Job `renovate-bootstrap` fails with "access token name has been used already" | The Secret is lost and the token lives. `renovate-token-lost.md` |
| The guard prints any other line | `artifacts/renovate/README.md`, "What the guard says" |

## Not part of this

Giving Renovate a repository (`renovate-repository.md`). Changing the schedule or the Renovate version
(`renovate-change.md`). Putting the bot in the Owners team, or making it an admin anywhere: the guard stops every run
while it is so. A copy of the GitHub token in `vaults/operator/`. A new recipient in `.sops.yaml`.
