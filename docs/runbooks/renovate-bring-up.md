# Runbook: bring Renovate up on the forge, and give it a repository

Written 2026-11-22. Steps 2, 3, 4 and 6 ran that day in a local kind cluster on Forgejo 15.0.12; not yet run on the
cluster. Step 5 has not been run anywhere.

## Why

Renovate reads the versions a repository pins and proposes each update as a pull request on the forge. It runs in
the cluster once an hour from `artifacts/renovate/` (`artifacts/renovate/README.md`), as the user `renovate`, whose
token no person holds. What it may write to is a person's decision, made here: a team, and a branch rule per
repository that keeps the bot off the default branch. A guard checks that rule before every run and stops the run
when it does not hold.

## What it touches

| What | Read or written | Needs |
|---|---|---|
| `platform/renovate-config` in zot | Pushed | A YubiKey, two touches |
| The user `renovate` and its token, Secret `renovate/renovate` | Made by the Job `renovate-bootstrap` | Nothing; Flux applies it |
| The team `renovate` in the organization `dataverket`, and a branch rule in each repository | Written on the forge | An owner of the organization, in a browser |
| `artifacts/renovate/renovate-github.enc.yaml` | Written, a cluster file | A token from github.com with no scopes; `sops` with the public keys only |
| `.sops.yaml`, `vaults/`, any other Secret | Never touched | |

## Steps

1. Choose the Renovate that runs. It is the image tag in the renovate repository's `kube/cronjob.yaml`, at the
   commit `artifacts/renovate/recipe/source.env` names. Check who signed that image, then render:

   ```sh
   cosign verify \
     --certificate-identity https://github.com/renovatebot/renovate/.github/workflows/build.yml@refs/heads/main \
     --certificate-oidc-issuer https://token.actions.githubusercontent.com \
     "$(yq '.spec.jobTemplate.spec.template.spec.containers[0].image' artifacts/renovate/rendered/batch_v1_cronjob_renovate.yaml)" >/dev/null && echo signed
   bin/artifact renovate --check
   ```

2. YubiKey, two touches. From a clean checkout of `main`, push the artifact; Flux applies it and the Job runs once:

   ```sh
   bin/artifact renovate --push
   flux --context dataverket-prod-admin reconcile kustomization apps --with-source
   flux --context dataverket-prod-admin reconcile kustomization renovate --with-source
   kubectl --context dataverket-prod-admin -n renovate wait --for=condition=complete job/renovate-bootstrap --timeout=180s
   kubectl --context dataverket-prod-admin -n renovate logs job/renovate-bootstrap
   ```

   The first reconcile makes the Kustomization `renovate`, the second waits until it has applied, the Job
   included. The log ends `user renovate created`, `renovate/renovate created`. From now on the CronJob starts every hour and
   its guard passes with `can write to 0 repositories`: the bot is in no team yet, and Renovate finds nothing.

3. Browser, as an owner of the organization. At `https://git.dataverket.org/org/dataverket/teams/new`:

   | Field | Value |
   |---|---|
   | Name | `renovate` |
   | Repository access | Specific repositories |
   | Permission | Custom access, with **Write** on Code, Issues and Pull requests, and no access to anything else |

   Add the user `renovate` to the team. Add no repository yet. The bot is never put in the Owners team and never
   made a collaborator with admin on a repository: either lets it remove a branch rule, and the guard stops every
   run while it is so.

4. Browser, for each repository Renovate is to read, in this order. The repository needs a `renovate.json`; without
   one Renovate passes it by.

   1. Settings, Branches, the rule for the default branch, or a new rule named after it. Under push: "Whitelist
      restricted push", with the people or teams who may push, and not the team `renovate`. Under merge: "Enable
      merge whitelist", with the same people or teams. Leave the rest as it is; on `fabrikk` the merge styles and
      the status check are set by its own workflow (`apps/forgejo/README.md`, "Merge commits only").
   2. Then, on the team's page, add the repository. An empty repository is not added: the guard refuses one, since
      its first commit would be the bot's.

   The rule comes first: in the other order the guard finds a repository the bot can push to and stops every run
   until the rule is there. Start with `renovate` and `fabrikk-infra`, read a day of pull requests, then add
   `fabrikk`, `swamp-extensions`, `salmon` and `nordhost-integrator`.

5. A token for github.com. Renovate reads the releases of jq, grype, yq, age, kubectl, CloudNativePG and Flux
   there, and without a login GitHub allows 60 requests an hour: on 2026-11-22 every one of those lookups was
   skipped for want of it. The token opens nothing; it only counts the requests against an account. A person
   makes it at `https://github.com/settings/tokens`, classic, with no scope ticked and an expiry, and it goes from
   the clipboard into a cluster file, never into an argument or a shell variable:

   ```sh
   wl-paste -n | kubectl create secret generic renovate-github --namespace renovate \
       --from-file=RENOVATE_GITHUB_COM_TOKEN=/dev/stdin --dry-run=client -o yaml |
     sops encrypt --filename-override artifacts/renovate/renovate-github.enc.yaml \
       --input-type yaml --output-type yaml /dev/stdin > artifacts/renovate/renovate-github.enc.yaml
   bin/check-recipients
   ```

   `wl-paste -n` is the clipboard on Wayland without a trailing newline; `pbpaste` on macOS. The value is born in
   the cluster files and exists nowhere else, so nothing is copied between stores. Add
   `renovate-github.enc.yaml` to the `resources` of `artifacts/renovate/kustomization.yaml`, commit both on a branch,
   merge, and push the artifact as in step 2. The actions a workflow uses are not read at GitHub but on the forge's
   own actions org, and need no token.

6. Read the first run after a repository was added:

   ```sh
   kubectl --context dataverket-prod-admin -n renovate get jobs --sort-by=.status.startTime | tail -3
   kubectl --context dataverket-prod-admin -n renovate logs job/<the newest> -c guard
   kubectl --context dataverket-prod-admin -n renovate logs job/<the newest> -c renovate | grep -E '^ ?(INFO|WARN|ERROR)'
   ```

   Or start one now: `kubectl --context dataverket-prod-admin -n renovate create job first --from=cronjob/renovate`.

## Proof

The guard's line is `guard: renovate can write to <n> repositories and reaches the default branch of none`, with
`<n>` the repositories of step 4. Each of them has an issue "Dependency Dashboard" by `renovate`, and at most two
new pull requests an hour; the rest wait on the dashboard under "Rate-Limited", and a tick there opens one on the
next run. In kind on 2026-11-22, against a copy of this repository: two pull requests marked `[security]` at once,
five updates under "Pending Status Checks" for being younger than seven days, 22 rate-limited, and Postgres 19 not
proposed.

| Seen | Means |
|---|---|
| The Job failed, the guard says `<repo>@main has no branch protection` | The repository was added to the team before its rule; make the rule (step 4) |
| The guard says `renovate can push` or `renovate can merge` | The rule's push or merge whitelist is off, or holds the team `renovate` |
| The guard says `renovate is a site admin` | Someone made the bot an admin. Take it away in the forge's admin pages; no branch rule holds an admin back |
| The guard says `renovate administers the repository` | The bot is a collaborator with admin there, or in the Owners team. Take it out |
| The guard says `<repo> is empty` | An empty repository was added to the team. Take it out until it has a first commit and a rule |
| `renovate-bootstrap` fails with "access token name has been used already" | The Secret is gone and the token lives; "A lost Secret" below |
| The dashboard says "GitHub token is required for some dependencies" | Step 5 is not done, or the token has expired |
| No dashboard issue in a repository | It has no `renovate.json` on its default branch, or the team does not hold it |

The guard was tested against each of the first five rows on 2026-11-22, and with the full rule in place the bot's
own token was refused a push to `main`, a merge of its own pull request and the removal of the rule
(`artifacts/renovate/README.md`).

## A lost Secret

When the Secret `renovate/renovate` is gone and the token still lives on the forge, the Job cannot make a second
token of the same name, and nobody can delete the first through the API, since the forge refuses basic
authentication. `dataverket-prod-admin`: delete the token's row in the database and the failed Job, and let Flux
make the Job again:

```sh
kubectl cnpg psql forgejo-postgres -n forgejo --context dataverket-prod-admin -- -d forgejo \
  -c "DELETE FROM access_token WHERE name = 'renovate-cluster' AND uid = (SELECT id FROM \"user\" WHERE lower_name = 'renovate');"
kubectl --context dataverket-prod-admin -n renovate delete job renovate-bootstrap --ignore-not-found
flux --context dataverket-prod-admin reconcile kustomization renovate --with-source
kubectl --context dataverket-prod-admin -n renovate logs job/renovate-bootstrap
```

`DELETE 1`, then `renovate/renovate created`. Done in kind on 2026-11-22 with the same statement through `psql` in
the database pod: the Job made a new Secret and the guard passed with the new token.

## Not part of this

Merging what Renovate proposes (`renovate-pull-request.md`). Giving the bot any right beyond the team's: it is never
an owner, an admin or in a whitelist. A recipient for the new cluster file: `.sops.yaml` already names who reads
`artifacts/**/*.enc.yaml`, and this job adds nobody. Renovate's global configuration, which lives in the renovate
repository's `kube/config.js`.
