# Runbook: take a pull request from Renovate to a deployed change

Written 2026-11-22. The pull requests were made that day in a local kind cluster by Renovate 44.251.0; none has yet
been taken to the cluster this way.

## Why

Renovate changes a pin and nothing else. In this repository a pin is rarely the whole change: a chart version
needs `rendered/` made again, a vendored manifest needs its file and its SHA-256, a database image needs a
restart done with care. So a pull request from Renovate is a proposal a person finishes on its branch, merges, and
ships. `check / vendor` and `check / artifacts` stay red until it is finished, and a red pull request is never merged.

## What it touches

| What | Read or written | Needs |
|---|---|---|
| The branch `renovate/<something>` of the pull request | Commits added | A push to the forge |
| `main` | The merge, by the forge's button | A person in the branch rule's merge whitelist |
| The artifact of what changed | Pushed | A YubiKey, two touches |
| Renovate's Secret, the team, the branch rule, `.sops.yaml` | Never touched | |

## Steps

1. Read the pull request: what moves, from which version to which, and when the new one was released. Renovate
   waits seven days after a release it knows the date of. Docker Hub and GitHub give one; `code.forgejo.org`,
   `ghcr.io`, `quay.io` and `registry.k8s.io` do not, so an image from those is proposed the day it appears, and
   the seven days are yours to count from the project's release page. A pull request marked `[security]` fixes a
   known vulnerability in a Go module and did not wait.

2. Check the branch out and finish it by its kind. Commit what the commands write, and push to the same branch:

   ```sh
   git fetch origin && git switch renovate/<something>
   ```

   | The pull request changes | Finish it with |
   |---|---|
   | A chart `version` in `artifacts/<name>/recipe/kustomization.yaml` | `bin/artifact <name>`, and read the diff of `rendered/` against the chart's notes. For `forgejo` also `bin/artifact forgejo-theme`, and the rest of `forge-upgrade.md` |
   | An `image:` in a plain manifest under `artifacts/` | Nothing to make. `bin/image-scan <the new image>` |
   | `imageName` of a database | Nothing to make on the branch; the whole of `postgres-minor-upgrade.md` |
   | `tag=` in `artifacts/zulip/postgres-image.sh` | Set `base=` beside it to `crane digest --platform linux/amd64 ghcr.io/cloudnative-pg/postgresql:<tag>`, then build the image as `artifacts/zulip/README.md` says |
   | The version of a vendored manifest in `share/vendor.sh` and `artifacts/cnpg/kustomization.yaml` | `git mv` the file to its new name, set the row's SHA-256 from `curl -fsSL <url> \| shasum -a 256`, a new minor also the `release-<x.y>` in the URL, then `bin/vendor`; `postgres-minor-upgrade.md` for the rest |
   | The runner or docker tag in `artifacts/forgejo-runners/recipe/values.yaml` | `bin/artifact forgejo-runners`, and `runner-upgrade.md` from its step 1 |
   | The runner chart's commit | Unpack `https://code.forgejo.org/forgejo-helm/forgejo-runner/archive/<commit>.tar.gz` over `artifacts/forgejo-runners/recipe/charts/forgejo-runner/`, then `bin/artifact forgejo-runners` |
   | A commit in `artifacts/<name>/recipe/source.env` | `bin/artifact <name>`; for `renovate`, step 1 of `renovate-bring-up.md` when the image tag moved |
   | `KUBECTL_VERSION` in a Job | Set `KUBECTL_SHA256` beside it from `https://dl.k8s.io/release/<version>/bin/linux/amd64/kubectl.sha256` |
   | `KUBECTL_VERSION` or `HELM_VERSION` in `.forgejo/workflows/check.yaml` | These are the versions `rendered/` is made with. Set the SHA-256 beside it, install the same version here, and render every artifact with it |
   | A chart `version` in a `release.yaml` under `artifacts/` or `infrastructure/` | Nothing to make; Flux installs the chart. Read the chart's notes |
   | The version and SHA-256 of jq, age, grype or yq | Nothing to make. Compare the new SHA-256 with the checksum file of the project's release |
   | An action in `.forgejo/workflows/` | Nothing to make. The version is one the forge's actions org holds |
   | A Go module | Nothing to make here; in a repository with a build, its tests |

3. Prove it, as CI will:

   ```sh
   bin/vendor --check && bin/artifact --check && bin/check-recipients
   ```

4. When every check on the pull request is green, merge it with the forge's button. A merge commit, never a squash
   or a rebase; the forge signs it (decision 036). Renovate's documentation says it leaves a branch alone once
   someone else has pushed to it; that has not been tried here, so read the branch's last commits before the merge.

5. Ship it. A change under `artifacts/<name>/` reaches the cluster only when the artifact is pushed. YubiKey, two
   touches, from a clean checkout of `main` at the merge:

   ```sh
   git switch main && git pull --ff-only
   bin/artifact <name> --push
   ```

   A service with a runbook of its own is shipped by that runbook, since the order and the waiting matter there.

## The dashboard

Each repository Renovate reads has one issue, "Dependency Dashboard", that lists everything it knows:

| Heading | What is under it | A tick does |
|---|---|---|
| Rate-Limited | Updates waiting for their turn; two pull requests are opened an hour | Opens that one on the next run |
| Pending Status Checks | Updates younger than seven days | Opens that one now. For a security release that cannot wait |
| Open | The pull requests | Rebases that one on `main` |
| Detected Dependencies | Every pin Renovate read, by file | Nothing; a pin missing here is a pin `renovate.json` does not cover |
| Repository Problems | What Renovate could not do | Nothing; `renovate-bring-up.md` has the usual ones |

Work from the top of what matters, not from the top of the list: a known-exploited finding of `bin/image-scan`
first, then security releases, then the rest. An update nobody wants is closed as a pull request; by Renovate's
documentation it is then not opened again for that version, which has not been tried here.

## Proof

`main` holds the merge, signed by the forge; the pull request's checks were green at the merge; the artifact's
`current` tag in zot is at the merge commit, which `flux --context dataverket-prod-readers get kustomization <name>`
shows as the applied revision;
and the service answers as its own runbook says. Then `bin/image-scan <the new image>` has nothing open.

| Seen | Means |
|---|---|
| `check / artifacts` red: `rendered/ differs from what recipe/ renders` | Step 2 is not done for this pull request |
| `check / vendor` red: a file is off its pin | The file or the SHA-256 in `share/vendor.sh` is still the old one |
| The Job that downloads kubectl fails its checksum after a merge | `KUBECTL_SHA256` was not set on the branch; set it in a new pull request |
| Renovate opens the same update again | The earlier pull request was merged without its branch being finished, and reverted; or the pin is written in a second place `renovate.json` does not read |
| A pull request for a Postgres or a Forgejo major | `renovate.json` no longer disables it; it is never merged as a pull request |

## Not part of this

Letting Renovate merge: `automerge` is off in every repository and stays off. Accepting a finding of the image
scan (`image-scan.md`). A change to what Renovate reads, which is a change to `renovate.json` and is tried first
with `task local` in the renovate repository.
