---
title: "One redundancy layer per kind of data"
description: "Zitadel's database replicates itself on worker disks as the rehearsal for bare metal; every other database is one instance on Cinder."
type: adr
category: data
tags:
  - cnpg
  - cinder
  - storage
status: accepted
created: 2026-10-01
updated: 2026-10-01
author: dataverket
project: plattform
related:
  - 014-local-pvs-through-the-static-provisioner.md
  - 017-workers-are-replaced-never-changed-in-place.md
  - 020-backups-go-to-the-hov1-site.md
---
# 018: One redundancy layer per kind of data

## Status

Accepted.

## Context

Until the storage plan's steps 2 and 6, on 2026-09-30 for Forgejo and 2026-10-01 for Zitadel, each database ran
three CNPG instances on three Cinder volumes, and Cinder keeps three copies of each volume: nine copies of one
database, paid for as SSD. Two layers that both replicate protect against the same
failure twice and against nothing new. A database that replicates itself does not need a replicated volume under it,
and one on a replicated volume does not need to replicate itself.

## Decision

Each kind of data gets one redundancy layer.

| Data | Layer | Where |
|---|---|---|
| Zitadel's database | CNPG, three instances, one synchronous replica (`method: any`, `number: 1`) | each worker's `u-pg-zitadel` partition, a `local` PV (014) |
| Every other database, Forgejo's and Zulip's included | Cinder's three copies | one CNPG instance on one Cinder volume |
| Repositories, registry, runner caches | Cinder's three copies | one volume each |

Zitadel's database is on worker disks as the rehearsal for bare-metal nodes with NVMe, where local disks are the only
disks. It is not there for the saving, about 60 NOK a month against three 10 GB Cinder volumes. Every database also
has the copy that matters off the provider (020).

## Consequences

- A worker dying loses one Zitadel replica and no acknowledged commit; CNPG promotes the synchronous one with no
  volume to reattach. A worker dying with a single-instance database on it is that database down until Cinder
  reattaches its volume, minutes.
- Zitadel's commits share the worker's root disk with images and logs. On `m5.large` that disk is capped at 500
  IOPS and 100 MiB/s each way. The storage plan's `pgbench` gate measured Postgres on it at 19.4 ms a transaction
  under a saturating load against 6.0 ms on Cinder, which failed the gate's own criterion; it was accepted, since
  Zitadel commits a few events per login and the cap leaves it room. On bare metal the gate is moot.
- Zitadel's partition is a fixed 11 GiB; outgrowing it is recreating the cluster on Cinder from the archive.
- Replacing a worker that holds a replica is not self-healing (017).

## Decision Outcome

Cinder held 388 GB of SSD before and holds 60 GB of SSD and 10 GB of Standard after, with one copy of every
database off the provider.

## Related Decisions

The mechanism under Zitadel's database is 014; the workers it lives on are 017; the off-site copy is 020.

## Audit

### 2026-10-01

**Status:** Implemented

**Findings:**

| Finding | Where | Assessment |
|---------|-------|------------|
| Forgejo's database one instance on 10 GB | `apps/forgejo/postgres.yaml` | done 2026-09-30 |
| Zitadel's database on three `local` PVs, one synchronous replica | `apps/zitadel/postgres.yaml` | done 2026-10-01 |
| No database replicated on top of Cinder | `apps/` | done |

**Summary:** Steps 2 and 6 of `docs/plans/2026-09-storage-building-blocks.md`.

**Action Required:** None.
