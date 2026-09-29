---
title: "zot is plain manifests, not a Helm chart"
description: "zot is a hand-written StatefulSet with a pinned digest, not a chart to render and track."
type: adr
category: infrastructure
tags:
  - zot
  - registry
  - manifests
status: accepted
created: 2026-09-17
updated: 2026-09-29
author: dataverket
project: plattform
related:
  - 011-zot-hosts-its-own-config.md
---
# 012: zot is plain manifests, not a Helm chart

## Status

Accepted

## Context

Upstream ships a Helm chart for zot. Everything else in `apps/` is a HelmRelease.

## Decision

`artifacts/zot/` is a StatefulSet, a Service, a ConfigMap, two Secrets and two HTTPRoutes, written by hand, image
pinned by digest. The chart wraps exactly those objects and would add helm at build time and a chart version to
track, for nothing.

## Consequences

- The artifact is the authored directory itself, pushed as-is. Nothing is rendered or templated, in a build or in
  the cluster.
- Upgrading zot is changing one digest.
- The security posture (non-root, read-only root filesystem, no capabilities) is explicit in the file rather than
  a values key.

## Decision Outcome

Upgrading zot is one digest, and its security posture is readable in the file rather than in a values key.

## Audit

### 2026-09-29

**Status:** Implemented

**Findings:**

| Finding | Where | Assessment |
|---------|-------|------------|
| Authored directory pushed as-is | `artifacts/zot/` | done |
| Image pinned by digest | `artifacts/zot/` | done |

**Summary:** In place since 2026-09-17.

**Action Required:** None.
