---
title: "Two roles: the control plane carries Kubernetes and the cloud credential, workers carry everything else"
description: "Control plane and worker, nothing else, from one Talos container to five and fifty; the edge is a DaemonSet on the workers, and the cloud credential exists only on control plane nodes."
type: adr
category: architecture
tags:
  - talos
  - scheduling
  - envoy
  - octavia
  - cloud-credential
status: accepted
created: 2026-10-05
updated: 2026-10-05
author: dataverket
project: plattform
related:
  - 017-workers-are-replaced-never-changed-in-place.md
  - 018-one-redundancy-layer-per-kind-of-data.md
  - 021-git-describes-the-cluster.md
---
# 024: Two roles: the control plane carries Kubernetes and the cloud credential, workers carry everything else

## Status

Accepted.

## Context

This cluster is the model for a later Kubernetes offering, and that offering has to scale from one Talos node in a
container to five control planes and fifty workers with the same manifests. The control planes here are `c5.large`,
two vCPUs and 4 GiB, on a root disk capped at 500 IOPS, and etcd fsyncs every write to it. On 2026-10-04 the one
Envoy proxy made every Octavia pool read `Degraded`, since with `externalTrafficPolicy: Local` only the worker that
runs a proxy answers the load balancer's health monitor, and three replicas spread by hostname fixed it for exactly
three workers and no other number.

SUSE Rancher's production checklist and RKE2 use three roles, etcd, control plane and worker, and never put the
worker role on the first two; OpenShift adds a fourth, infra nodes, for its router, registry and monitoring. Both
run only Kubernetes, the CNI, DNS and the cloud controller on the control planes. RKE2 runs its ingress as a
DaemonSet on every agent and refuses to deploy it on tainted servers. The one add-on Rancher prefers on control
planes is its own steady agent, not an operator that writes artifacts to disk.

## Decision

Two roles, Talos' own machine types, and no third.

- **The control plane carries Kubernetes, the CNI, DNS, and whatever holds the cloud credential**: the cloud
  controller manager and the Cinder CSI controller, which both mount `cloud-config`. The credential that reaches
  every volume, load balancer and address of the project exists on no worker.
- **Workers carry everything else**: the operators (Flux, cert-manager, CNPG, external-dns, the Envoy controller),
  the edge, the databases, the applications and the runners. Platform services are protected on shared workers by
  priority, requests, budgets and spread, not by a node role.
- **The edge is a DaemonSet on the workers.** One Envoy per worker at any count, so every load balancer member is
  healthy with `Local`, and the proxy count never has to follow the node count.
- **The only knob along the ladder is Talos' `allowSchedulingOnControlPlanes`**: on at one node, off the moment a
  worker exists. A cloud-specific piece, Cinder CSI, the cloud controller, Octavia, is an environment overlay on a
  base that runs on a single Talos container.

Why the operators stay off the control planes, specifically: Flux's source-controller writes every clone and
artifact to the disk etcd fsyncs to, and kustomize-controller builds and decrypts in bursts; the control plane's
free 2 GiB is what the API server and etcd grow into at fifty workers; a control plane drain, which Talos upgrades
do one node at a time, would restart single-replica operators and a budget on one could stall the upgrade; the
control plane's network surface stays the API, etcd and the Talos API; and "workers for everything" needs no
toleration in any chart, so a forgotten one lands right.

## Consequences

- `infrastructure/envoy/envoyproxy.yaml` runs the proxies as `envoyDaemonSet`; a disruption budget and an
  autoscaler do not apply and are not set. A rolling update takes one worker at a time. The proxy requests 256 MiB
  against a working set of 46 MiB measured from the kubelet on 2026-10-04, where the chart's default asks 512 MiB.
- `infrastructure/cinder-csi-provider/controller-ds.yaml` carries the cloud controller's node affinity and
  tolerations. A control plane drain restarts it; an attach in flight retries.
- An offering's node pools are counts of these two roles. A worker pool reserved for the edge or for runners is
  a label on workers, never a role.
- A single-node cluster schedules on its control plane and runs the proxy DaemonSet there.

## Decision Outcome

The same manifests place every component correctly at one node, at three and three, and at five and fifty, and a
worker compromise cannot reach the cloud account.

## Related Decisions

Workers are replaced, never changed (017); each kind of data has one redundancy layer on the workers (018); git
describes the cluster, including this placement (021).

## Audit

### 2026-10-05

**Status:** Implemented

**Findings:**

| Finding | Where | Assessment |
|---------|-------|------------|
| Envoy as a DaemonSet on the workers | `infrastructure/envoy/envoyproxy.yaml` | applied 2026-10-05 |
| CSI controller on the control planes | `infrastructure/cinder-csi-provider/controller-ds.yaml` | applied 2026-10-05 |
| Priority classes on the platform namespaces | `apps/`, `infrastructure/` | pending |
| The one-node base and the cloud overlay | `docs/research/2026-10-render-toolchain.md` | not built |

**Summary:** The two placements are in git; the one-node form of the baseline is the render toolchain's work.

**Action Required:** Set `system-cluster-critical` on the platform operators when their charts are next touched.
