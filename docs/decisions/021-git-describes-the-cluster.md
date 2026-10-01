---
title: "Git describes the cluster; a rebuild restores its databases"
description: "Every change ends with the cluster matching git, and each database's recovery source is in git, so Flux rebuilds the cluster with its data."
type: adr
category: architecture
tags:
  - flux
  - cnpg
  - recovery
status: accepted
created: 2026-10-01
updated: 2026-10-01
author: dataverket
project: plattform
related:
  - 011-zot-hosts-its-own-config.md
  - 017-workers-are-replaced-never-changed-in-place.md
  - 018-one-redundancy-layer-per-kind-of-data.md
  - 020-backups-go-to-the-hov1-site.md
---
# 021: Git describes the cluster; a rebuild restores its databases

## Status

Accepted.

## Context

Flux rebuilds what git describes and nothing else. A change made by hand and never committed is lost in a rebuild,
and a database that git describes with `initdb` comes back empty. Forgejo is also where Flux reads this repository,
so the cluster that has lost Forgejo has lost its own source.

## Decision

Every change ends with the cluster matching git. A suspend, a scale, a copy, a PV patch or a one-off Job is
scaffolding: done by hand, gone when the change ends, never the only record of anything.

Every CNPG cluster in git carries `bootstrap.recovery` from the archive it writes itself, so a rebuild restores it
from the hov1 site (020) instead of starting it empty. A restored cluster cannot archive into the archive it came
from, so a rebuild first moves each plugin `serverName` to the next number; `bin/check-recovery-names` says which, and
`bootstrap.sh` runs it on a fresh cluster, after making sure the checkout is what the source serves. That commit never
reaches a branch the old cluster's Flux reads while the old cluster runs: plugin parameters are live, so it would
start writing to the new name, and the restore would find that archive taken.

While Forgejo is gone, Flux reads the GitHub mirror `github.com/dataverket-org/fabrikk-infra`, read-only;
`bootstrap.sh --source github` sets that up, and a commit afterwards points Flux back at `git.dataverket.org`.

## Consequences

- A rebuild loses only what had not reached git or the archive: the repositories' volume comes back from the GitHub
  mirrors by hand, and zot and the runner caches come back empty.
- The recovery source moves to the new archive the day a migrated cluster's first backup completes; until then a
  rebuild would restore the state of the migration.
- No new `Backup` object is committed: applied with its `Cluster` on a rebuild it fires during recovery, fails and is
  never retried. The two committed today, `forgejo-postgres-first` and `zitadel-db-first`, leave git on 2026-10-14
  and 2026-10-15. `bootstrap.sh` takes the first base backups instead.
- A rebuild test in a lab cluster needs its own branch, which `bootstrap.sh` does not offer yet: it bootstraps from
  `main`.
- Machines are below Flux. Their patches are files in git, and the server group, servers and machine set are made by
  swamp's models from them (017).

## Decision Outcome

Flux, the GitHub mirror and the hov1 archive are enough to bring the cluster back with its databases.

## Related Decisions

Restores from 020. 011 is the same idea for zot's config.

## Audit

### 2026-10-01

**Status:** Pending

**Findings:**

| Finding | Where | Assessment |
|---------|-------|------------|
| `bootstrap.recovery` from each cluster's own archive | `apps/forgejo/postgres.yaml`, `apps/zitadel/postgres.yaml` | done |
| The `serverName` check and the source option | `bin/check-recovery-names`, `bootstrap.sh` | done, tested against the repository, not in a rebuild |
| A rebuild from the mirror | nowhere yet | pending |

**Summary:** Everything a rebuild needs is in git; no rebuild has been run.

**Action Required:** A branch option for `bootstrap.sh`, then a rebuild test in a lab cluster.
