# The renovate artifact

Renovate for the repositories on `git.dataverket.org`: a CronJob that opens pull requests four times a day, as a user of
its own, and can merge none of them. The CronJob and its configuration are the renovate repository's `kube/`,
`git.dataverket.org/dataverket/renovate`, rendered here in the factory (decision 028) at a pinned commit, pushed by
`bin/artifact renovate --push` into zot as `platform/renovate-config`, and applied by the Kustomization in
`apps/renovate/source.yaml`. Nothing here depends on swamp. Bringing it up, and what a person does when it proposes
something: `docs/runbooks/renovate-bring-up.md` and `docs/runbooks/renovate-pull-request.md`.

## Contents

| File | What |
|---|---|
| `recipe/source.env` | The renovate repository and the commit of it that runs |
| `recipe/kustomization.yaml` | The cluster's patch of the CronJob; `render.sh` runs it inside a checkout of the renovate repository |
| `render.sh` | The bespoke renderer `bin/artifact renovate` runs: writes `rendered/`; `--check` proves it true to the recipe |
| `rendered/` | The Namespace, the CronJob and its ConfigMap, one file each. Written by `render.sh`, never by hand |
| `bootstrap.yaml` | The Job that makes the bot and its token, with its ServiceAccount and Roles |
| `guard.mjs` | What runs before Renovate on every run, mounted from the ConfigMap `renovate-guard` |
| `renovate-github.enc.yaml` | The GitHub token Renovate reads upstream releases with, a cluster file |
| `kustomization.yaml` | What Flux applies: `rendered/`, the Job and the guard's ConfigMap |

## What the patch adds

- **The guard**, an init container in Renovate's own image, so there is one image to pin.
- **A security context**: Renovate's own user 12021, no service account token, no added capabilities.
- **`RENOVATE_GIT_AUTHOR`**, the bot's name and its address on the forge, so its commits are shown as its own.
- **A second Secret**, `renovate-github`, with `RENOVATE_GITHUB_COM_TOKEN`: the cluster file
  `renovate-github.enc.yaml`, since 2026-11-24. The token is a fine-grained GitHub token with no permissions, for
  public repositories only. It opens nothing; with it GitHub counts Renovate's reads of upstream releases against an
  account, 5000 an hour, and without it against the cluster's address, 60 an hour, which skipped every lookup there.
  The CronJob names the Secret as optional, so a cluster without it still runs. The value is in this file and
  nowhere else; a lost or expired one is replaced with a new token (`docs/runbooks/renovate-bring-up.md`, step 5).

The version of Renovate is the image tag in the renovate repository's `kube/cronjob.yaml`. A new version is a new
`RENOVATE_COMMIT` in `recipe/source.env`, rendered and pushed. The image is pulled by tag; who signed a tag is read
with `cosign verify`, as the renovate repository's README shows.

## The bot and its token

The Job `renovate-bootstrap` runs once per cluster, as the actions mirror's does (`apps/forgejo/README.md`): it makes
the user `renovate` through the `forgejo` CLI in the forgejo pod, with a random password nobody keeps, and a token
named `renovate-cluster`, written straight into Secret `renovate/renovate` and nowhere else. The token carries
`write:repository`, `write:issue`, `read:user` and `read:organization`, what Renovate's Forgejo platform asks for. A
rerun while the Secret exists is a no-op. The Role in `forgejo` allows `exec` on that namespace's pods, the
database's included, since `exec` cannot be limited to one pod by name; the ServiceAccount that holds it is the
Job's alone, and the CronJob runs with no service account token.

The user is never an admin and owns nothing. What it may write to is decided by a person: the team `renovate` in
the organization, and the branch rule of each repository the team holds.

## The guard

A repository's branch rule is what keeps the bot off its default branch, and a rule is one click to remove. So
Renovate does not trust it; before every run `guard.mjs` asks the forge, with Renovate's own token:

1. Is the token's user a site admin? An admin passes every branch rule.
2. For each repository the user can write to, mirrors and archived ones aside: does the user administer it, as a
   collaborator or as an owner of its organization? An admin of a repository can remove its branch rule.
3. Is the repository empty? Its first commit makes the default branch, and no rule is there yet.
4. Is the default branch protected, and may this user push to it or merge into it? The forge answers for the
   asking user (`protected`, `user_can_push` and `user_can_merge` on the branch), so the guard needs no right to
   read the rule itself.

Any yes and the guard exits 1, the Job fails, and Renovate has not started. The log names every repository at
fault. A failed Job is the signal, as with the actions mirror.

Tested on Forgejo 15.0.12 in a kind cluster on 2026-11-22, with the bot in a team with write on one repository:

| The repository's default branch | The guard |
|---|---|
| No rule | Refuses: `has no branch protection` |
| A rule with push open | Refuses: `renovate can push` |
| Push limited to people, merge open | Refuses: `renovate can merge` |
| Push and merge limited to people | Passes, and Renovate opened a pull request and its dashboard issue |
| The same, with the bot made an admin | Refuses: `is a site admin` |
| The same, with the bot a collaborator with admin on the repository | Refuses: `administers the repository and can remove its branch rule` |
| The same, with the bot in the organization's Owners team | Refuses, with that line for every repository of the organization |
| An empty repository the bot's team holds | Refuses: `is empty, so its first commit would be renovate's` |

With the last rule in place, the bot's own token was refused a push to `main` (`pre-receive hook declined`), a merge
of its own pull request (405, `User not allowed to merge PR`) and the removal of the rule (403), and was allowed a
push to a `renovate/` branch.
