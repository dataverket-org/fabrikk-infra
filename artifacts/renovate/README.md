# The renovate artifact

Renovate proposes version updates as pull requests on `git.dataverket.org`. It can open a pull request. It can
never push to a default branch or merge into one.

Three things make that true:

- **A user of its own.** Renovate runs as the user `renovate`. Nobody holds its token.
- **A branch rule per repository.** Only the Owners team may push to `main` or merge into it.
- **A guard before every run.** It checks the rule with Renovate's own token and stops the run when it does not hold.

This file has the facts ("Reference") and the reasons ("Why it is built this way"). The jobs are runbooks:

| Job | Runbook |
|---|---|
| Bring Renovate up on a cluster | `docs/runbooks/renovate-bring-up.md` |
| Give Renovate a repository | `docs/runbooks/renovate-repository.md` |
| Take a pull request from Renovate to a deployed change | `docs/runbooks/renovate-pull-request.md` |
| Change the schedule, the Renovate version or its global settings | `docs/runbooks/renovate-change.md` |
| Run Renovate now, outside its schedule | `docs/runbooks/renovate-run-now.md` |
| Make the bot's token again when its Secret is lost | `docs/runbooks/renovate-token-lost.md` |

## Reference

### What runs

| Fact | Value | Where it is set |
|---|---|---|
| Schedule | 01, 07, 13 and 19, Oslo time | `cronjob.yaml` |
| Renovate version | The image tag, written twice: for the guard and for Renovate | `cronjob.yaml` |
| Which repositories | Those the team `renovate` holds that have a `renovate.json` | The team on the forge; `config.js` |
| Namespace | `renovate` | `namespace.yaml` |
| Delivered as | `platform/renovate-config` in zot | `apps/renovate/source.yaml` |

### What a repository's `renovate.json` sets here

| Setting | Value in `fabrikk-infra` |
|---|---|
| Wait before a release is proposed | Seven days |
| A fix for a known vulnerability in a Go module | No wait; its own pull request, marked `[security]` |
| Grouping | One pull request per artifact, `artifacts/<name>/` |
| New pull requests per hour | No limit |
| Open pull requests at a time | Ten |
| Never proposed | A Postgres major, a Forgejo chart major, a kubectl minor in a Job, our own images |
| Renovate's own image | A pull request of its own, on Mondays. The newest tag, see "Known limits" |
| Action versions | Read from the forge's own `actions` org, not from GitHub |
| Merging | Never by Renovate |

### Files

| File | What |
|---|---|
| `cronjob.yaml` | The CronJob: the schedule, the image, the guard, the security context |
| `config.js` | Renovate's settings for every repository, as the ConfigMap `renovate-config` |
| `namespace.yaml` | The Namespace |
| `bootstrap.yaml` | The Job that makes the bot and its token |
| `guard.mjs` | The guard, mounted from the ConfigMap `renovate-guard` |
| `renovate-github.enc.yaml` | The GitHub token, a cluster file |
| `kustomization.yaml` | What Flux applies |
| `bin/renovate-local` | Renovate on a laptop, for repositories on disk. No token, no changes |

The directory holds plain manifests. Nothing is rendered, so a change to a file is the whole change.

### Secrets

| Secret | Key | Made by | Held by |
|---|---|---|---|
| `renovate/renovate` | `RENOVATE_TOKEN` | The Job `renovate-bootstrap` | The cluster only |
| `renovate/renovate-github` | `RENOVATE_GITHUB_COM_TOKEN` | A person, as `renovate-github.enc.yaml` | The cluster and the operators, through that file |

The forge token has the scopes `write:repository`, `write:issue`, `read:user` and `read:organization`. The GitHub
token has no permissions and reads public repositories only.

### What the CronJob sets

- The guard, as an init container in Renovate's own image.
- A security context: user 12021, no service account token, no added capabilities.
- `RENOVATE_GIT_AUTHOR`, so the bot's commits show as its own.
- The second Secret, `renovate-github`, named as optional.

### Local mode

`bin/renovate-local` runs the image `cronjob.yaml` names, with Podman, on repositories on disk. It prints one line
per update Renovate would propose; the same update in two places of a file is one line. It reads uncommitted
changes of tracked files; a new file is seen after `git add`. It needs no token and changes nothing. It fails when
Renovate refuses the repository's configuration, and prints why.

| Command | What it does |
|---|---|
| `bin/renovate-local` | Every repository in the folder that has a Renovate configuration |
| `bin/renovate-local --list` | Prints those repositories, runs nothing |
| `bin/renovate-local <repository> ...` | These repositories |

The folder is the one this repository is in, or `RENOVATE_FOLDER`. A worktree works too.

### What the guard says

The guard exits 0 with `guard: renovate can write to <n> repositories and reaches the default branch of none`. It
exits 1, and Renovate does not start, with one line per repository at fault:

| Line | Cause |
|---|---|
| `<repo>@main has no branch protection` | The repository is in the team and has no rule |
| `<repo>@main: renovate can push` | The rule's push whitelist is off, or holds the team |
| `<repo>@main: renovate can merge` | The rule's merge whitelist is off, or holds the team |
| `<repo>: renovate administers the repository and can remove its branch rule` | The bot is a collaborator with admin, or in the Owners team |
| `<repo> is empty, so its first commit would be renovate's` | An empty repository is in the team |
| `renovate is a site admin, which no branch rule holds back` | The bot was made an admin of the forge |

### The dashboard issue

Renovate keeps one issue per repository, "Dependency Dashboard".

| Heading | What is under it | A tick does |
|---|---|---|
| Repository Problems | What Renovate could not do | Nothing |
| Rate-Limited | Updates waiting because ten pull requests are open | Opens that one on the next run |
| Pending Status Checks | Updates younger than seven days | Opens that one on the next run |
| Open | The pull requests | Rebases that one on `main` |
| Detected Dependencies | Every pin Renovate read, by file | Nothing |

A pin missing under "Detected Dependencies" is a pin `renovate.json` does not cover.

### Known limits

- The charts of `artifacts/zitadel/release.yaml` and `infrastructure/envoy/release.yaml` are not watched. They come
  from the in-cluster mirror, which Renovate does not read. The dashboard reports the failed lookup.
- `code.forgejo.org`, `ghcr.io`, `quay.io` and `registry.k8s.io` may give no release time. Then the seven days
  cannot be counted and the image is proposed at once. Renovate's own image is one of these: its rule asks for
  three days, and ghcr.io gives no time to count them from.
- The Renovate image is pulled by tag. Its signature is checked by a person before a new tag is used.

## Why it is built this way

### Why a guard, when there is a branch rule

A branch rule is one click to remove, and nothing tells Renovate when it is gone. So every run checks first. The
guard asks the forge what the asking user may do to each default branch (`protected`, `user_can_push`,
`user_can_merge`). It needs no right to read the rule itself.

The guard also refuses three cases a rule cannot cover. A site admin passes every rule. An admin of a repository,
or an owner of its organization, can remove the rule. An empty repository has no branch to protect yet.

### Why the rule comes before the team

A team member with write access can push to `main` until a rule says otherwise. So the rule is made first and the
repository is added to the team after. `docs/runbooks/renovate-repository.md` does both in that order in one run.

On 2026-11-24 `fabrikk-infra` was added to the team by hand before its rule existed. The guard stopped three runs
until the rule was made. Nothing was pushed.

### Why nobody holds the bot's token

The Job makes the user with a random password nobody keeps, and writes the token straight into the Secret. A token
no person has cannot leak from a person. A lost Secret is replaced, not restored
(`docs/runbooks/renovate-token-lost.md`).

The Job's Role allows `exec` on every pod in the namespace `forgejo`, the database's included, because `exec`
cannot be limited to one pod by name. Only the Job's ServiceAccount holds that Role. The CronJob runs with no
service account token.

### Why the GitHub token is not in the operators' store

The token opens nothing. It only makes GitHub count Renovate's reads against an account, 5000 an hour, and not
against the cluster's address, 60 an hour. The operators can read it from the cluster file. A lost one is replaced
by a new one. A second copy would only be a second place to rotate.

### Why Renovate cannot finish its own pull request

Renovate changes a pin and nothing else. Here a pin is rarely the whole change: a chart version needs `rendered/`
made again, and a vendored file needs its checksum. The checks `vendor` and `artifacts` stay red until a person has
done that on the branch. Decision 028 says why the rendering is kept in git.

### Why Renovate lives in this repository

Until 2026-11-24 the CronJob and `config.js` lived in a repository of their own, `dataverket/renovate`, and this
artifact pinned one commit of it. A change to the schedule then took a merge there, a new pin here and a push. Now
it is one pull request and a push, and Renovate's pull request for its own image is the whole change. Local mode
moved here with it, so a laptop and the cluster still run the same image.

### What was tested

On Forgejo 15.0.12 in a kind cluster on 2026-11-22, with the bot in a team with write on one repository, the guard
gave each line of "What the guard says" for its cause, and passed when push and merge were limited to people. With
that rule the bot's token was refused a push to `main`, a merge of its own pull request and the removal of the
rule. It was allowed a push to a `renovate/` branch.

On the cluster on 2026-11-24 the guard stopped three runs for `has no branch protection`, then passed with two
repositories. Renovate opened the dashboard in both and two `[security]` pull requests in `fabrikk-infra`.
