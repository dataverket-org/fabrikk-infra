---
title: "Upstream charts are rendered in the factory and shipped as artifacts, chart by chart"
description: "A chart is inflated by kustomize on the operator's machine into a committed rendered tree, reviewed as a diff, shipped as a signed OCI artifact and applied by Flux; helm-controller leaves the cluster when the last HelmRelease does; cert-manager and external-dns go first."
type: adr
category: architecture
tags:
  - flux
  - helm
  - kustomize
  - oci
  - delivery
status: proposed
created: 2026-10-06
updated: 2026-10-06
author: dataverket
project: plattform
related:
  - 011-zot-hosts-its-own-config.md
  - 012-zot-as-plain-manifests.md
  - 013-cluster-fetches-registry-through-service.md
  - 021-git-describes-the-cluster.md
  - 027-the-control-plane-carries-the-names-and-certificates.md
---
# 028: Upstream charts are rendered in the factory and shipped as artifacts, chart by chart

## Status

Proposed. The first artifact, cert-manager and external-dns, is built in git on a branch and not yet applied; the
handover from helm-controller is written in `artifacts/cert-manager/README.md`.

## Context

Six upstream charts run here as HelmReleases. helm-controller inflates each one inside the cluster, from a chart
repository outside it, and applies the result where no one reads it: a chart upgrade is a version number in a
HelmRelease and its effect is seen only after the fact. `docs/research/2026-10-rendered-manifests-over-oci.md` and
`docs/research/2026-10-render-toolchain.md` worked through the alternative and found it the shape the product side
already uses: render in the factory, pin by digest, commit the rendered output, sign, ship, never join in the
cluster. zot and versitygw already arrive as artifacts of plain manifests (011, 012, 013); what was missing was a
chart as the input.

Decision 027 moved cert-manager and external-dns to the control planes, which touched both HelmReleases anyway and
made them the natural first pair: they render to 70 objects with no hook but a start-up check that can be turned
off, and no Secret.

## Decision

An upstream chart is rendered in the factory and shipped as an artifact, one chart at a time, and the HelmRelease
that ran it is removed once the artifact is applied and read as healthy.

- **Kustomize is the only renderer.** `artifacts/<name>/recipe/kustomization.yaml` names the chart, its version
  and its values in `helmCharts`, with any hand-written manifests as `resources`; `kubectl kustomize --enable-helm`
  inflates it. Helm runs on the operator's machine and never in the cluster.
- **The rendered tree is committed.** `artifacts/<name>/rendered/`, one file per object, written by `render.sh`
  and never by hand. The diff of it is the review of a chart upgrade. `render.sh --check` proves it true to the
  recipe, and `push.sh` refuses to ship otherwise.
- **The render refuses two things.** A Secret, since a value in the rendered tree is a value in git in clear;
  secrets travel encrypted next to the tree, as zot's do, and Flux decrypts them. A Job, since a Helm hook rendered
  is a Job that cannot be re-run; a hook is disabled, or carried as a plain manifest on purpose.
- **Shipped and applied as zot is.** `push.sh` pushes the tree and the encrypted Secret into zot, tagged by commit
  and `current`; an `OCIRepository` on the Service name and a `Kustomization` apply it. A from-git Kustomization in
  `bootstrap/` covers a fresh cluster, until zot serves.
- **The CRDs can never be pruned.** They carry `kustomize.toolkit.fluxcd.io/prune: disabled`, because a CRD
  deleted deletes every object of its kind.
- **The handover keeps every object.** The HelmRelease is given `uninstall.deletionPropagation: orphan`, the
  artifact is applied beside it, and only then is the HelmRelease removed. Nothing is deleted on the way.

## Consequences

- `artifacts/cert-manager/`: the recipe for cert-manager v1.20.3 and external-dns 1.21.1 with the placement of 027,
  the nordhost webhook and the ClusterIssuer as plain manifests, 70 rendered objects, `render.sh`, `push.sh`.
  `infrastructure/cert-manager/source.yaml` applies it; `bootstrap/cert-manager-from-git.yaml` is the fallback. The
  two HelmReleases carry the orphan setting and are removed in the step after the artifact is read as healthy.
- The cluster stops reading `charts.jetstack.io` and the external-dns chart repository; the operator's machine
  reads them at render time, until a chart mirror in zot exists.
- `helm` joins the operator toolchain. The start-up check Job of cert-manager is gone; `kubectl get certificate`
  is the check.
- envoy, zitadel, forgejo, CNPG and the static provisioner follow one by one. envoy and zitadel depend on hooks,
  which is the open question the research names; a decision on each closes it.
- helm-controller is removed from Flux when the last HelmRelease is.
- Signing is per site, with a cosign key pair kept as one sops file in `vaults/operator/<site>/cosign.enc.json`,
  read by a person at `push.sh` time and by nothing unattended; the public half is a Secret in
  `clusters/production/`, and each `OCIRepository` carries its `verify` block, switched on once the artifact has
  been pushed signed. A release runner, when it exists, signs with a key of its own.

## Decision Outcome

A chart upgrade is a diff a person reads before it is shipped, the cluster holds no chart repository in its
reconcile path, and what runs is what git says, object by object.

## Related Decisions

zot hosts its own config (011) and is plain manifests (012); the cluster fetches its registry through the Service
(013); git describes the cluster (021); the placement this first artifact carries (027).

## Audit

### 2026-10-06

**Status:** Not implemented

**Findings:**

| Finding | Where | Assessment |
|---------|-------|------------|
| Recipe, rendered tree, scripts | `artifacts/cert-manager/` | in git on the branch; renders reproducibly, 70 objects, no Secret, no Job |
| OCI source and Kustomization | `infrastructure/cert-manager/source.yaml` | in git on the branch |
| From-git fallback | `bootstrap/cert-manager-from-git.yaml` | in git on the branch |
| Orphan on the HelmReleases | `infrastructure/{cert-manager,external-dns}/release.yaml` | in git on the branch |
| Artifact pushed and applied | zot, the cluster | not done |
| HelmReleases removed | `infrastructure/` | not done; step 3 of the handover |

**Summary:** Built and rendered on 2026-10-06; applying is the handover in `artifacts/cert-manager/README.md`.

**Action Required:** Run the handover's four steps, reading the cluster between each.
