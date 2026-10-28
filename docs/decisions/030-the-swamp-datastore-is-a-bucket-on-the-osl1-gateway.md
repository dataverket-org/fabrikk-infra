---
title: "The swamp datastore is a bucket on the osl1 gateway, shared by every operator host"
description: "Swamp's data lives in bucket swamp-fabrikk-infra on Dataverket's S3 at osl1, written by one account that every operator host holds; versioning and object lock stay off until the lifecycle program exists."
type: adr
category: data
tags:
  - swamp
  - s3
  - versitygw
  - datastore
status: accepted
created: 2026-10-28
updated: 2026-10-28
author: dataverket
project: plattform
related:
  - 001-credential-tiers.md
  - 002-two-sops-stores-one-reader-each.md
  - 016-operator-values-live-in-vaults-operator.md
  - 020-backups-go-to-the-hov1-site.md
  - 029-s3-in-the-cluster-is-one-versitygw-per-org-on-one-volume.md
---
# 030: The swamp datastore is a bucket on the osl1 gateway, shared by every operator host

## Status

Accepted 2026-10-28. The datastore runs; a host joins through `docs/runbooks/swamp-host-key.md` and the key copy.

## Context

The swamp repository's data, every model run's records and every workflow run, lived in `.swamp/` on one
operator's host. A second operator running the same models would start from nothing and the two would never see
each other's runs. Swamp's answer is an external datastore with a local cache per host, and `@swamp/s3-datastore`
takes any S3 endpoint whose conditional writes it can prove, since its lock rests on them. Dataverket's S3 at osl1
(029) is such an endpoint and is already operated here.

## Decision

| Part | Decided |
|---|---|
| Where | Bucket `swamp-fabrikk-infra`, prefix `fabrikk-infra`, on `https://dataverket.s3.osl1.dvkt.no`, path-style, region `us-east-1`; `@swamp/s3-datastore`, pulled as is (026), format 2 |
| Who writes | One account, `swamp-fabrikk-infra`, role `user`, owner of that bucket and nothing else, as 029 shapes every writer. Every operator host holds the same key pair, because the `user` role sees only buckets it owns and a bucket has one owner |
| Where the key lives | Born in `vaults/operator/osl1/swamp-fabrikk-infra.enc.json`, two fields for `sops exec-env`; each host copies it once, with a touch, into the AWS default profile. Tier 3 with a human owner (001), like the process key that opens the vault |
| Versioning, object lock | Off. The datastore rewrites its index shards on every sync and garbage-collects superseded chunks; versitygw has no lifecycle rules, so a versioned bucket would keep every superseded shard forever on the 20 GiB volume Zulip shares. Lock needs versioning. Both wait for `docs/plans/2026-10-versitygw-lifecycle.md`, whose step 6 names exactly this: an osl1 bucket that wants lock |
| Each host's vault key | Unchanged by this record: one process key per host (002, audit of 2026-10-28) |

## Consequences

- Every operator host sees every run, and a host that is rebuilt hydrates from the bucket.
- The gateway now holds data that exists nowhere else and matters more than Zulip's uploads, which is the
  condition `docs/plans/2026-10-s3-osl1-backup.md` set for itself. The plan is due.
- One key pair on two hosts cannot be revoked apart. A rotation is `user.sh --rotate`, a new file in the operator
  store, and a copy to every host, during which no host syncs. Per-person S3 credentials are
  `docs/plans/2026-10-s3-zitadel.md`.
- What protects the data meanwhile: the bucket, a full local cache on each host, Cinder's three copies of the
  volume, and git for every definition, workflow and extension.
- versitygw v1.9.0 honours `If-None-Match` and `If-Match` on `PutObject`, proven by the setup's probe. That fact
  is now in `artifacts/versitygw/README.md`.
- `osl1-s3 check` keeps its three expected findings: the new bucket is owned by its same-named account.

## Decision Outcome

The two operators work against one datastore on Dataverket's own S3, with one more writer on the osl1 gateway and
no new reader of any sops store.

## Related Decisions

Follows 001, 002, 016 and 029. Makes the backup in 020's shape due for osl1.

## Audit

### 2026-10-28

**Status:** Implemented for the first host

**Findings:**

| Finding | Where | Assessment |
|---------|-------|------------|
| Account and bucket on osl1 | `osl1-s3` inventory | done, `user.sh` on 2026-10-28 |
| Key pair in the operator store, copied to the first host | `vaults/operator/osl1/swamp-fabrikk-infra.enc.json` | done |
| The first host's own vault key, so unattended runs read the vault there | `swamp-fabrikk-infra-jubilato` in `.sops.yaml` | done, decision 002's audit |
| Datastore set up, local data migrated, bucket healthy | `.swamp.yaml`, `swamp datastore status` | done; 5348 files pushed |
| The other operator's host | `docs/runbooks/swamp-host-key.md`, then the key copy | pending, its owner's job |
| Backup of the gateway | `docs/plans/2026-10-s3-osl1-backup.md` | due since this record |

**Summary:** The first host writes to the bucket; the second joins when its vault key and the key copy are in place.

**Action Required:** The other operator's host; the backup plan.
