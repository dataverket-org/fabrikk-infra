---
title: "Upstream manifests are vendored, pinned by hash; a Flux build needs no network"
description: "A manifest the cluster applies from an upstream release is kept in the repository at its pinned version with its SHA-256 in share/vendor.sh, fetched by bin/vendor and proven by bin/vendor --check in the pre-commit hook; a kustomization never names a URL, so a reconcile depends on nothing but our own source."
type: adr
category: infrastructure
tags:
  - flux
  - kustomize
  - supply-chain
  - cnpg
status: accepted
created: 2026-11-08
updated: 2026-11-08
author: dataverket
project: plattform
related:
  - 013-cluster-fetches-registry-through-service.md
  - 021-git-describes-the-cluster.md
  - 028-upstream-charts-are-rendered-in-the-factory.md
  - 034-three-layers-upstream-site-tenant-and-where-a-tenant-sits-in-a-name.md
---
# 035: Upstream manifests are vendored, pinned by hash; a Flux build needs no network

## Status

Accepted 2026-11-08. Applied the same day to the two manifests that were URLs: CloudNativePG 1.30.0 and its Barman
Cloud plugin v0.15.0.

## Context

`infrastructure/cnpg-operator` and `infrastructure/cnpg-barman-plugin` were each one line: a kustomization whose
resource was a URL at GitHub, pinned by the version in the path. Kustomize fetches such a URL at every build, on the
cluster, in the kustomize-controller pod. On 2026-11-08 GitHub's release downloads answered 504 for an hour; the
plugin's manifest could not be fetched, the `infrastructure` build failed, and every Kustomization that depends on
`infrastructure` — zot, www, offentlig-data, Zulip — refused to proceed. Nothing running changed, but nothing could
be changed either, rollbacks included, until a service we do not run recovered. A rebuild of the cluster from git
(021) would have had no CNPG at all. The two URLs also sat on two different GitHub services (release assets and raw
content), so one build had two independent ways to fail. 034 had just said of our own sites that upstream means
source and mirror, never a runtime dependency; the platform's own reconcile loop was the exception.

## Decision

| | |
|---|---|
| What is vendored | Any manifest the cluster applies that is published as a file by an upstream release: today CNPG's operator and its Barman plugin. A chart is 028's case and is rendered, not vendored |
| Where | In the directory whose kustomization applies it, named with its version: `infrastructure/cnpg-operator/cnpg-1.30.0.yaml` |
| The pin | `share/vendor.sh` holds one row per manifest: directory, file, the URL it came from, its SHA-256. The hash is the pin; a release that changes under its URL is refused, not taken |
| Fetching | `bin/vendor` (`task vendor`) fetches a manifest that is missing or off its pin, refuses an HTML error page sent with a success status, verifies the hash, and writes the file for a commit |
| Proving | `bin/vendor --check` (`task vendor-check`) verifies every committed copy against its pin with no network; the pre-commit hook runs it beside `check-recipients` |
| Bumping | Change the row (URL and hash), run `bin/vendor`, commit file and row together; the kustomization names the new file |
| Never | A kustomization resource that is a URL |

## Consequences

- A Flux build of `infrastructure` reads only the repository. Its dependency set is `git.dataverket.org`, or GitHub's
  mirror of us for a rebuild (021), which is our own source, not someone else's release.
- About 1.3 MB of upstream YAML is in git and grows with each bump; the old file leaves when the new one lands, so
  the working tree holds one version per manifest.
- The hash is taken from whatever the URL served when the row was written. The first fetch is trusted as the
  upstream is; what the pin adds is that the content cannot change afterwards without a visible commit. An upstream
  that publishes checksums or signatures can be checked against them when the row is written; neither of today's
  two does.
- The pre-commit hook gains a check that runs in milliseconds and needs no YubiKey.
- The pattern waits for the next URL someone is tempted to write into a kustomization; the row is cheaper than the
  outage.

## Decision Outcome

What the cluster is built from is in the repository, all of it. Upstream is where a version is taken from once, with
a hash to say which; it is not asked again at build time, so an outage upstream cannot stop a change, a rollback or a
rebuild here.

## Related Decisions

013 removed the registry from the cluster's own fetch path; this removes GitHub from the build path. 028 covers the
other way upstream content enters, rendered from charts into a committed `rendered/`. 021 keeps GitHub as the
rebuild source of *our* repository, which this makes sufficient. 034's rule for sites, applied to the platform's own
loop.

## Audit

### 2026-11-08

The operator's manifest was fetched from raw content; the plugin's from GitHub's API asset endpoint, since the
release-download CDN was still answering 504 — the same file by asset id, 45029 bytes, its image `v0.15.0`, as the
running plugin. The vendored build of `infrastructure` gives 86 objects offline; the remote-fetching build of the
same tree could not be run locally that hour, which was the point.
