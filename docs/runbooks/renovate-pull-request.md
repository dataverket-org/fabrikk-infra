# Runbook: take a pull request from Renovate to a deployed change

Written 2026-11-22, updated 2026-11-24 after Renovate's first real run. Renovate has opened pull requests here
since that day; none has yet been taken to the cluster this way.

## Why

After this job a pull request from Renovate is merged and its change runs in the cluster. Renovate only changes a
pin, so a person finishes the pull request on its branch, merges it, and pushes the artifact. A red pull request is
never merged: `check / vendor` and `check / artifacts` stay red until the branch is finished.

Renovate opens one pull request per artifact, so one pull request is one render and one push.
`artifacts/renovate/README.md` has the settings and the dashboard's headings.

## What it touches

| What | Read or written | Needs |
|---|---|---|
| The branch `renovate/<something>` of the pull request | Commits added | A push to the forge |
| `main` | The merge, by the forge's button | A person in the branch rule's merge whitelist |
| The artifact of what changed | Pushed | A YubiKey, two touches |
| Renovate's Secret, the team, the branch rule, `.sops.yaml` | Never touched | |

## Steps

1. Read the pull request: every pin it moves, from which version to which, and when each new version was
   released. Images from `code.forgejo.org`, `ghcr.io`, `quay.io` and `registry.k8s.io` may be proposed the day
   they appear; for those, read the release date on the project's page and count the seven days yourself.

2. Check the branch out. Finish each pin it moves by its kind, in the table below, then render the artifact once.
   Commit what the commands write and push to the same branch. Put a pin you do not want back by hand.

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

4. When every check is green, merge with the forge's button. Use a merge commit, never a squash or a rebase. The
   forge signs the merge (decision 036). Read the branch's last commits first: whether Renovate leaves a branch
   alone after a person has pushed to it has not been tried here.

5. Ship it. A change under `artifacts/<name>/` reaches the cluster only when the artifact is pushed. YubiKey, two
   touches, from a clean checkout of `main` at the merge:

   ```sh
   git switch main && git pull --ff-only
   bin/artifact <name> --push
   ```

   A service with a runbook of its own is shipped by that runbook, since the order and the waiting matter there.

## Which pull request first

1. A known-exploited finding of `bin/image-scan`.
2. A pull request marked `[security]`.
3. The rest.

An update that waits under "Pending Status Checks" or "Rate-Limited" on the dashboard issue is opened by a tick, on
the next run. Runs are at 01, 07, 13 and 19 Oslo time; `renovate-repository.md`, step 4, starts one now. An update
nobody wants is closed as a pull request. By Renovate's documentation it is then not opened again for that
version; that has not been tried here.

## Proof

```sh
flux --context dataverket-prod-readers get kustomization <name>
bin/image-scan <the new image>
```

The first shows the merge commit as the applied revision. The second has nothing open. `main` holds the merge,
signed by the forge, and the service answers as its own runbook says.

| Seen | Means |
|---|---|
| `check / artifacts` red: `rendered/ differs from what recipe/ renders` | Step 2 is not done for this pull request |
| `check / vendor` red: a file is off its pin | The file or the SHA-256 in `share/vendor.sh` is still the old one |
| The Job that downloads kubectl fails its checksum after a merge | `KUBECTL_SHA256` was not set on the branch; set it in a new pull request |
| Renovate opens the same update again | The earlier pull request was merged without its branch being finished, and reverted; or the pin is written in a second place `renovate.json` does not read |
| A pull request for a Postgres or a Forgejo major | `renovate.json` no longer disables it; it is never merged as a pull request |
| One pull request per image again, not per artifact | The rule with `groupName` is gone from `renovate.json`, or the file is under a path it does not match |
| Renovate closes its own pull requests and opens others | The grouping or a version changed between runs; the new ones replace the old |

## Not part of this

Letting Renovate merge: `automerge` is off in every repository and stays off, and the branch rule of
`renovate-bring-up.md` refuses its merge whatever the configuration says. Accepting a finding of the image
scan (`image-scan.md`). A change to what Renovate reads, which is a change to `renovate.json` and is tried first
with `task local` in the renovate repository.
