---
title: "Backups go to the hov1 site, by address, over the public internet"
description: "The copy that matters is off the provider: a versitygw at the hov1 site, reached by IP with its own private CA."
type: adr
category: data
tags:
  - backup
  - cnpg
  - hov1
status: accepted
created: 2026-10-01
updated: 2026-10-01
author: dataverket
project: plattform
related:
  - 009-services-are-named-not-addressed.md
  - 018-one-redundancy-layer-per-kind-of-data.md
  - 021-git-describes-the-cluster.md
---
# 020: Backups go to the hov1 site, by address, over the public internet

## Status

Accepted.

## Context

Cinder and the provider's object storage share one account and one provider. A deleted project, a billing dispute or
an operator's mistake at the provider takes both, so neither is the copy that matters. The hov1 site is a different
building, network and operator, with disk that is already paid for. Its uplink is down more often than a provider's.

## Decision

Every database's base backups and WAL go to `213.128.185.82:443`, a versitygw with the posix backend at the hov1 site
(`backup/hov1`), through CNPG's Barman Cloud plugin: daily base backups, continuous WAL, 14 days. One bucket and one
account per writer, each account owning its bucket and nothing else.

The endpoint is an address, not a name, so that no DNS zone or DNS provider sits in the backup path. TLS is from the
site's own private CA, made offline, root and certificate valid three years; the root is pinned in the cluster.
This is not an exception to 009, which is about how operator tools find a service, not about where a workload
writes.

## Consequences

- Every writer must tolerate hours of the site being unreachable. Postgres keeps every segment the archive has not
  taken, so the WAL-archiving alert at two hours is what turns an outage into a delay instead of a full disk.
- Nothing at the site renews the certificate, so its expiry is to be probed from the cluster (not deployed yet, see
  Audit) and the reissue is a calendar event.
- Bucket versioning stays off: versitygw has no lifecycle rules, so retention is the writers' job.
- An address change is a plaintext diff in `apps/<namespace>/hov1-s3.yaml`; a name for the endpoint can come later.
- A second copy at the provider's object storage, if the site proves too unreliable, is a second `ObjectStore`, not a
  new design.

## Decision Outcome

Both databases archive to the hov1 site, and a restore from it has been tested and timed.

## Related Decisions

The copy off the provider that 018 counts on. A rebuild restores from it (021).

## Audit

### 2026-10-01

**Status:** Implemented

**Findings:**

| Finding | Where | Assessment |
|---------|-------|------------|
| Base backups and WAL to the site | `apps/forgejo/backup.yaml`, `apps/zitadel/backup.yaml` | done since 2026-09-20 |
| Restore test of both clusters | `backup/restore-test/` | passed 2026-09-21; both migrations of the storage plan were restores too |
| WAL and certificate alerts | storage plan, "Operations after the change" | pending: written down, not deployed |

**Summary:** Archiving works for both clusters; the alerts that make an outage cheap are not in place yet.

**Action Required:** Deploy the WAL-archiving and certificate-expiry alerts.
