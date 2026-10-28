---
title: "S3 in the cluster is one versitygw per org, on one volume"
description: "An org's S3 is its own versitygw on one Cinder volume, named <org>.s3.osl1.dvkt.no and path-style; accounts are made with versitygw's own admin CLI, and object lock is available but unused."
type: adr
category: infrastructure
tags:
  - s3
  - versitygw
  - storage
status: accepted
created: 2026-10-15
updated: 2026-10-15
author: dataverket
project: plattform
related:
  - 013-cluster-fetches-registry-through-service.md
  - 015-kubernetes-authenticates-against-zitadel.md
  - 018-one-redundancy-layer-per-kind-of-data.md
  - 020-backups-go-to-the-hov1-site.md
---
# 029: S3 in the cluster is one versitygw per org, on one volume

## Status

Accepted 2026-10-15. The gateway runs (`artifacts/versitygw/`), Zulip's two buckets are its first data; its backup is
`docs/plans/2026-10-s3-osl1-backup.md`, deferred.

## Context

Zulip's uploads need an S3 endpoint a service reads on every request, and the hov1 site, the backup target over the
public internet (020), is the wrong place for that. versitygw is already Dataverket's S3 at hov1, with a swamp
extension and runbooks. The tenants model in `kode/fabrikk` (`docs/explanation/sentral.md`) makes a tenant a Zitadel
org, so the shape had to fit more than one org, compared on 2026-10-04 against one radosgw for every org.

## Decision

| Part | Decided |
|---|---|
| Shape | One versitygw per org, posix backend, on one Cinder volume (`csi-cinder-standard-retain`): the volume is its one redundancy layer (018), the off-provider copy is hov1 (020). Dataverket is the first org, at the osl1 site |
| Name | `<org>.s3.osl1.dvkt.no` under one wildcard listener, path-style only; the bare `s3.osl1.dvkt.no` is never a tenant's. In-cluster writers that serve every file themselves use the Service, `versitygw.versitygw.svc.cluster.local:7070`; a writer that hands out URLs, as Zulip does, uses the public name |
| Accounts | Made by a person with versitygw's own admin CLI inside the pod (`artifacts/versitygw/user.sh`), so the root key pair never leaves it; the secret goes straight into `sops --encrypt`. `@dataverket/versitygw` stays read-only: `inventory` and `check` through the `osl1-s3` model |
| Ownership | One account per writer, role `user`, owner of its buckets; a writer may own more than one |
| Object lock | Available, since the gateway runs with a versioning directory, and used by no bucket. Proving it, and the lifecycle a locked, versioned bucket needs (`docs/plans/2026-10-versitygw-lifecycle.md`), wait for a writer that wants it |
| Identity | versitygw's internal IAM until a person needs S3 with expiring credentials; Zitadel federation is `docs/plans/2026-10-s3-zitadel.md` |

## Consequences

- An org's bucket namespace, `ListBuckets`, IAM store and root key are its own by construction, and onboarding an
  org is the same manifests with a new label and a new volume. Each gateway is `ReadWriteOnce` and pinned to one
  worker, and Nova caps volumes per instance, so the number of orgs per worker has a ceiling to measure first.
- Envoy keeps one endpoint: the org travels in the hostname, the one field SigV4 signs as sent and anonymous
  requests also carry. A path prefix per org cannot work, since the first segment is the bucket and the client
  signed the path it sent. If a bare hostname is ever a product requirement, the fallback is a route per bucket on
  `s3.osl1.dvkt.no`, at the cost of a global bucket namespace.
- radosgw is the answer when the number of orgs or the volume of data makes N pinned gateways silly, or when bare
  metal makes Ceph the storage anyway. Moving an org between the two is an S3-to-S3 copy.
- versitygw has no lifecycle rules, so a versioned bucket keeps every non-current version until a client deletes it.
- `check` reports a bucket not owned by its same-named account and a world-readable bucket; Zulip's two buckets
  are owned by `zulip`, and `zulip-avatars` is public on purpose, so those three findings are expected.
- Until its backup runs, the gateway's data has Cinder's three copies and nothing else.

## Decision Outcome

Dataverket's S3 is `https://dataverket.s3.osl1.dvkt.no`, versitygw v1.9.0 on a 20 GiB volume, read through
`osl1-s3`, with accounts made in the pod and their Secrets in sops. A second org is a second gateway.

## Audit

### 2026-10-15

**Status:** Implemented for the first org

**Findings:**

| Finding | Where | Assessment |
|---------|-------|------------|
| Gateway, listener, route, certificate | `artifacts/versitygw/`, `infrastructure/envoy/gateway.yaml` | applied 2026-10-04; v1.9.0 since 2026-10-15 for versitygw #2398 and #2495 |
| A 2 GiB PUT in one request through Envoy | `artifacts/zulip/s3proof -big` | 9 min 36 s, no route timeout |
| Accounts in the pod | `artifacts/versitygw/user.sh` | `zulip`, owner of `zulip-uploads` and `zulip-avatars` |
| Read through swamp | model `osl1-s3` | `inventory` holds no secret; `check` finds only the three expected findings |
| Zulip's S3 use | `artifacts/zulip/s3proof` | 13 of 13 proofs on tusd's AWS SDK |
| Backup | `docs/plans/2026-10-s3-osl1-backup.md` | deferred |
| Object lock | no bucket | deferred |

**Summary:** One gateway for Dataverket runs with Zulip's buckets on it and no backup yet.

**Action Required:** The backup, `docs/plans/2026-10-s3-osl1-backup.md`; object lock when a writer wants it.

### 2026-10-28

**Status:** Implemented, a second writer

**Findings:**

| Finding | Where | Assessment |
|---------|-------|------------|
| A second account, `swamp-fabrikk-infra`, owner of its same-named bucket, made with `user.sh` | `osl1-s3` inventory | done; the writer is swamp on every operator host, decision 030 |
| Conditional writes on `PutObject` | `artifacts/versitygw/README.md` | proven by the datastore's setup probe |
| Backup | `docs/plans/2026-10-s3-osl1-backup.md` | due: the gateway now holds data that exists nowhere else |
| Object lock | no bucket | still deferred; the datastore is the writer that will want it, after the lifecycle program |

**Summary:** The gateway's second writer is this repository's own datastore, which makes the backup plan due.

**Action Required:** The backup plan.
