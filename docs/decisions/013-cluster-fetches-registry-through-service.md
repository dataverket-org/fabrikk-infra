---
title: "The cluster fetches its own registry through the Service, not the public name"
description: "The cluster pulls its own registry through the Service, so the edge being broken cannot lock it out."
type: adr
category: infrastructure
tags:
  - zot
  - registry
  - dns
  - flux
status: accepted
created: 2026-09-17
updated: 2026-09-29
author: dataverket
project: plattform
related:
  - 011-zot-hosts-its-own-config.md
---
# 013: The cluster fetches its own registry through the Service, not the public name

## Status

Accepted

## Context

The first pointer used `registry.dataverket.org`. Its first lookup ran before external-dns had created the record,
and the zone's negative TTL is three hours, so the upstream resolver kept answering NXDOMAIN. That exposed the real
problem: the registry's own config depended on external DNS, the LoadBalancer and the certificate.

## Decision

`apps/zot/source.yaml` pulls from `zot.zot.svc.cluster.local:5000` with `insecure: true`. This is the one
deliberate exception to "one name for the registry", and it exists to survive the edge being broken. Everything
that consumes artifacts, on this cluster or elsewhere, uses the public name; pushes use the public name; cosign
signatures are made against it.

## Consequences

- Plain HTTP inside the cluster network for this one fetch, until zot gets an internal certificate.
- The internal name is a per-cluster fact and is recorded in the README's names table.
- When a second cluster exists, per-cluster names move into a ConfigMap under `clusters/<name>/` and
  `postBuild.substituteFrom`. Not before.

## Decision Outcome

Flux keeps reconciling zot when external DNS, the LoadBalancer or the certificate is broken, which is when
it matters most.

## Related Decisions

Refines 011.

## Audit

### 2026-09-29

**Status:** Implemented

**Findings:**

| Finding | Where | Assessment |
|---------|-------|------------|
| Internal Service name in the pointer | `apps/zot/source.yaml` | done |

**Summary:** In place since 2026-09-17, after an NXDOMAIN cached for three hours made the dependency obvious.

**Action Required:** Give zot an internal certificate so the fetch need not be plain HTTP.
