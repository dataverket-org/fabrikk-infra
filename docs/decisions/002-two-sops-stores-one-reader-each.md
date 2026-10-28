---
title: "Two SOPS stores, one reader each"
description: "One key per decrypting process; neither store's key is ever a recipient of the other store's files."
type: adr
category: security
tags:
  - sops
  - age
  - credentials
  - flux
status: accepted
created: 2026-09-29
updated: 2026-09-29
author: dataverket
project: plattform
related:
  - 001-credential-tiers.md
  - 003-cluster-sops-key-never-leaves-the-cluster.md
---
# 002: Two SOPS stores, one reader each

## Status

Accepted

## Context

Two SOPS stores live here with different readers: the Flux files, which the cluster decrypts on apply, and the
swamp vault, which the swamp host decrypts on every model run. Both are encrypted to public keys anyone can add
to, so there is a standing temptation to make the swamp host a recipient of the cluster files, or the cluster a
recipient of the vault, whenever a value is wanted in both places.

## Decision

One key per decrypting process, named after the process, and the name is what `.sops.yaml`, the vault config and
the plans call it.

- `cluster-dataverket-prod` decrypts the Flux files and nothing else. A second cluster gets its own
  `cluster-<name>` key.
- `swamp-fabrikk-infra` decrypts the vault and nothing else. A second swamp repository gets its own `swamp-<repo>`
  key, never a copy of this one.
- A value that has to exist in both stores is copied by a human with a YubiKey, from the store where it was born,
  and the commit message says so. The origin is the source of record and rotation starts there.

## Consequences

- `sops updatekeys` and the copy are never automated, which keeps them rare and reviewed.
- A leak of the swamp host's key costs the vault, which is mirrored to GitHub with the rest of this repository,
  and not the cluster manifests beside it. Re-keying after such a leak is the vault alone.
- The rule is about the repository at rest and about re-keying, nothing more. The swamp host can still read a
  live cluster Secret through the API with an admin kubeconfig; what bounds that is invariant 2 of 001.
- `bin/check-recipients` enforces it, so it does not depend on anyone remembering.

## Decision Outcome

A leak is bounded to one store, and re-keying after one is a job on one store rather than on every
encrypted file in the repository.

## Related Decisions

Follows 001. Refines 003 and 006.

## Audit

### 2026-09-29

**Status:** Implemented

**Findings:**

| Finding | Where | Assessment |
|---------|-------|------------|
| Each identity declared once as an anchor | `.sops.yaml` | done |
| Every rule names identities by alias | `.sops.yaml` | done |
| All 16 encrypted files match their rule | `bin/check-recipients` | verified |

**Summary:** Applied 2026-09-29. The check was proved against both failures it exists for: a vault file carrying
the cluster key, and a file no rule covers.

**Action Required:** Wire the check into CI when this repository has any.

### 2026-10-28

**Status:** Clarified

**Findings:**

| Finding | Where | Assessment |
|---------|-------|------------|
| A second swamp host for the same repository is a second decrypting process | `.sops.yaml`, README Secrets | its own key, generated on that host, never a copy of the first |
| One file name on every host, `swamp-fabrikk-infra.txt`, since the vault config names the key by name | `vaults/@dataverket/sops/` | unchanged; the public key is what tells hosts apart |
| Each host's public key listed as `swamp-fabrikk-infra.<host>`, a recipient of `vaults/infra/` only | `.sops.yaml` | the key of 2026-09-20 keeps its plain name: its file is on no host checked (jubilato, 2026-10-28), so its holder is to be confirmed or the entry removed by an operator; no recipient changed |

**Summary:** The decision said a second repository gets its own key. A second host running the same repository, for
the shared S3 datastore on osl1, follows the same rule: one key per process, and a host is a process. The copy the
rule forbids was weighed and declined, because two hosts on one key cannot be revoked apart and the key would become
material at rest in the repository.

**Action Required:** The other operator's host, by its owner with their own YubiKey; the holder of the key of
2026-09-20, or its removal.

### 2026-10-28 (later the same day)

**Status:** Implemented for the first host

**Findings:**

| Finding | Where | Assessment |
|---------|-------|------------|
| `swamp-fabrikk-infra.jubilato`, generated on the laptop, a recipient of `vaults/infra/` only | `.sops.yaml`, the vault config, nine files re-encrypted | done, `docs/runbooks/swamp-host-key.md` |
| Vault reads on that host without a touch | `swamp vault audit-trail --vault infra` | verified: forgejo, codeberg and github from a non-interactive shell |

**Summary:** The runbook was run once, on jubilato. The key of 2026-09-20 stays a recipient until its holder is found.

**Action Required:** The other operator's host; the key of 2026-09-20.
