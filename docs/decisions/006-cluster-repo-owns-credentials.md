---
title: "A credential the cluster uses is authored here; the factory copies it"
description: "A credential the cluster uses is authored here and copied outward, never the other way around."
type: adr
category: architecture
tags:
  - credentials
  - boundaries
  - registry
status: accepted
created: 2026-09-17
updated: 2026-09-29
author: dataverket
project: plattform
related:
  - 002-two-sops-stores-one-reader-each.md
---
# 006: A credential the cluster uses is authored here; the factory copies it

## Status

Accepted

## Context

The software factory (`fabrikk`) keeps its own vault. Some credentials, such as the registry push user, are needed
by both the cluster and the factory. Two sources of truth drift.

## Decision

A credential the cluster uses is authored here as an encrypted Secret manifest and is the source of record. When
the factory needs the same value, it is copied from here into the factory's vault, and the commit says so. Never
the other way around.

## Consequences

- Rotation starts here: change the `*.enc.yaml`, push the artifact or merge, then copy.
- The first credential born this way is `fabrikk-ci` (`artifacts/zot/zot-ci-credentials.enc.yaml`, copied to the
  vault as `registry/ci_username` and `registry/ci_password`).
- Inside this repository the same rule reads as "origin first", which is 002.

## Decision Outcome

One place to change a shared credential, and a commit that says where a copy came from.

## Related Decisions

Refined by 001 and 002.

## Audit

### 2026-09-29

**Status:** Implemented

**Findings:**

| Finding | Where | Assessment |
|---------|-------|------------|
| `fabrikk-ci` authored here | `artifacts/zot/zot-ci-credentials.enc.yaml` | done |
| Copied into the vault under its own names | `vaults/infra/registry/` | done |

**Summary:** In place since 2026-09-17. Older hand-applied secrets are still being migrated one at a time.

**Action Required:** Migrate the remaining hand-applied secrets: Forgejo admin, mailer and OAuth, the Zitadel
masterkey, `cloud.conf`.
