---
title: "zot hosts its own config; git is the bootstrap and recovery source"
description: "zot serves the artifact that deploys zot; git is the bootstrap and the way back from a bad one."
type: adr
category: infrastructure
tags:
  - zot
  - registry
  - flux
  - oci
status: accepted
created: 2026-09-17
updated: 2026-09-29
author: dataverket
project: plattform
related:
  - 013-cluster-fetches-registry-through-service.md
---
# 011: zot hosts its own config; git is the bootstrap and recovery source

## Status

Accepted

## Context

zot is delivered gitless: Flux pulls its manifests as an OCI artifact. That artifact must live in a registry that
exists before zot does. The forge's container registry was considered and rejected, because a recreated cluster
would depend on a forge that may not exist yet either.

## Decision

The artifact lives in zot. `apps/zot/source.yaml` is the only thing git applies for zot in steady state.
`bootstrap/zot-from-git.yaml`, a second Kustomization without prune, applies the same directory straight from git
until zot serves its first artifact, and again whenever a bad artifact leaves zot unable to serve. `bootstrap.sh`
applies it and removes it.

## Consequences

- Nothing outside this repository and the cluster is needed to recreate the registry.
- `artifacts/zot` is authored in git and travels as an artifact, the shape every later artifact has.
- A bad artifact cannot lock the registry out: the git path brings it back, then a fixed artifact is pushed.

## Decision Outcome

The registry can be rebuilt from this repository and the cluster alone, and a bad artifact cannot lock it
out.

## Audit

### 2026-09-29

**Status:** Implemented

**Findings:**

| Finding | Where | Assessment |
|---------|-------|------------|
| zot serves its own manifests | `apps/zot/source.yaml` | done |
| git path applied and removed by bootstrap | `bootstrap/zot-from-git.yaml` | done |

**Summary:** In place since 2026-09-17.

**Action Required:** None.
