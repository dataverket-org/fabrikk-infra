---
title: "The models that reach this cluster live here, not in the factory"
description: "Every model whose credential reaches what this repository deploys lives here, not in the factory."
type: adr
category: architecture
tags:
  - swamp
  - models
  - boundaries
status: accepted
created: 2026-09-18
updated: 2026-09-29
author: dataverket
project: plattform
related:
  - 006-cluster-repo-owns-credentials.md
---
# 005: The models that reach this cluster live here, not in the factory

## Status

Accepted

## Context

The software factory (`fabrikk`) carried, next to its loop, the swamp models a human uses to operate what this
repository deploys: the cluster through an admin kube context, the Talos fleet, the registry's push side, the
release runner, and forge-wide settings. A workbench runs an agent, and whatever that agent can reach, a mistake
can reach.

## Decision

This repository has its own swamp (`swamp repo init`, 2026-09-18) and its own vault, `infra`, and holds every
model whose credential reaches what it deploys. The factory keeps a repository-scoped forge token and anonymous
registry reads, nothing more.

The boundary is structural: no such credential exists in `fabrikk`, and its `models/` and `workflows/` are
protected paths, so an instance that would cross it is a change a human sees.

## Consequences

- Operating the cluster, the fleet, the registry mirror, the release runner and forge-wide settings means this
  checkout.
- The credentials moved with the models and kept their names. The Omni keys have since left the vault entirely
  (001); what remains is the forge, codeberg, GitHub and registry tokens.
- 006 still holds, so the registry credential's source of record stays `artifacts/zot/`, copied into `infra`.
- The factory's `uat` and `promoting` stages, once built, read the environment from the outside (health endpoint,
  registry) and retag from CI, never through a model from here.

## Decision Outcome

An agent working in the factory cannot reach the cluster by mistake, because the credential that would let
it is not in that checkout at all.

## Audit

### 2026-09-29

**Status:** Implemented

**Findings:**

| Finding | Where | Assessment |
|---------|-------|------------|
| Models and `infra` vault live here | `models/`, `vaults/infra/` | done |
| Factory keeps a repository-scoped forge token only | `fabrikk` | done |

**Summary:** Applied 2026-09-18.

**Action Required:** None.
