---
title: "The control plane also carries the cluster's names and certificates"
description: "cert-manager, external-dns and the DNS provider webhook run on the control planes, as the cloud credential's holders do; the webhook is three replicas spread over them, everything else one; Flux stays on the workers because it writes to the etcd disk."
type: adr
category: architecture
tags:
  - talos
  - scheduling
  - cert-manager
  - external-dns
  - credentials
status: accepted
created: 2026-10-06
updated: 2026-10-06
author: dataverket
project: plattform
related:
  - 001-credential-tiers.md
  - 024-two-roles-the-control-plane-carries-kubernetes-and-the-cloud-credential.md
---
# 027: The control plane also carries the cluster's names and certificates

## Status

Accepted. Supersedes one sentence of 024: cert-manager and external-dns are no longer among the operators the
workers carry. Applied the same day.

## Context

024 puts the cloud credential's holders, the cloud controller and the Cinder CSI controller, on the control planes,
because that credential reaches everything in the project and a worker compromise must not reach it. It lists
cert-manager and external-dns with the operators the workers carry.

The credential those two hold reaches further. Today it is the DirectAdmin login for `dataverket.org` and
`dvkt.no`, mounted by external-dns, by cert-manager's DNS-01 solver and by the provider webhook: with it any record
in both zones can be rewritten, the apex and MX included, and a certificate obtained for any name. The deSEC plan
(`docs/plans/2026-10-dns-desec.md`) shrinks it to per-zone bounded tokens, which is the larger part of the fix and
is still due. Where the pod runs is the other part: a Secret is on the node that runs the pod, so a worker
compromise reaches it there, while the API-level exposure through etcd and RBAC is the same on either node.

Operationally nothing speaks against the control planes for these two. Neither writes to disk, so 024's argument
against Flux, source-controller's clones and artifacts on the disk etcd fsyncs to, does not apply. They are small
reconcilers with leader election, cert-manager's webhook apart, which is stateless and in the admission path:
while it is down, no Certificate or Issuer can be applied. What the control planes gain is about 500 MiB of
requests per node, egress to Let's Encrypt and the DNS provider, and placement configuration in two charts and one
manifest.

Static pods were considered and rejected: a static pod cannot reference a Secret or a ServiceAccount, so the
credential would land in the Talos machine config and on the node's disk in clear, and the component would leave
Flux's hands. A DaemonSet was rejected: the chart has no DaemonSet form for the webhook, and a leader-elected
controller on every node is idle copies, while external-dns has no leader election and two copies race on the
provider's API. A proportional autoscaler that follows the control-plane count was considered and not started: a
stateless webhook needs availability, not a count that tracks the nodes.

## Decision

The control plane carries, besides Kubernetes, the CNI, DNS and the cloud credential's holders, the components that
hold the credentials for the cluster's names and certificates: cert-manager's controller, webhook and cainjector,
external-dns, and the DNS provider webhook they share a Secret with.

- **Replicas.** The cert-manager webhook runs three, spread softly over the control planes by hostname
  (`whenUnsatisfiable: ScheduleAnyway`), with a disruption budget of one available, so a control plane drain never
  closes the admission path and never stalls on the budget. Everything else runs one replica, and a reschedule is
  its failover; external-dns never runs more than one.
- **Priority.** All of them run as `system-cluster-critical`.
- **The same manifests at every size.** On a single node the three webhook replicas share the one node; at three
  they are one per node; at five they cover three. No overlay sets a count.
- **Flux stays on the workers**, for the reason 024 gives: it writes to the etcd disk.

The rule 024 states becomes: the control plane carries Kubernetes and whatever holds a credential whose reach
exceeds the cluster's own, provided it does not write to disk; the workers carry everything else.

## Consequences

- `infrastructure/cert-manager/release.yaml`: node selector, toleration and priority on the controller, the
  webhook and cainjector; the webhook at three replicas with the spread and the budget. `startupapicheck` is a
  one-shot Job and is left alone.
- `infrastructure/external-dns/release.yaml` and `infrastructure/nordhost-webhook/deployment.yaml`: node selector,
  toleration and priority.
- Each control plane carries about 500 MiB more of requests, out of the 2 GiB 024 keeps free for the API server and
  etcd at fifty workers; at that size the control planes are larger machines in any case.
- Control planes now make outbound connections to the certificate authority and the DNS provider. An egress rule
  for control planes, when one exists, names them.
- A Talos upgrade of a control plane restarts the single-replica components there; the webhook stays up on the
  other two. No disruption budget exists on a single-replica component.
- The deSEC move stays the main fix for the credential's reach; this decision does not replace it.

## Decision Outcome

A worker compromise reaches neither the cloud account nor the zones nor the certificate authority, and the
cluster's names and certificates keep converging while the worker pool is rebuilt.

## Related Decisions

Two roles (024), whose line this moves by one class of credential; credentials are held in tiers (001), which says
why the credential is also made smaller.

## Audit

### 2026-10-06

**Status:** Implemented

**Findings:**

| Finding | Where | Assessment |
|---------|-------|------------|
| cert-manager on the control planes, webhook at three with spread and budget | `infrastructure/cert-manager/release.yaml` | in git |
| external-dns and the provider webhook on the control planes | `infrastructure/external-dns/release.yaml`, `infrastructure/nordhost-webhook/deployment.yaml` | in git |
| Pods running on control planes | the cluster, read 2026-10-06 20:38 UTC | done: controller and cainjector on ctrl-3, external-dns on ctrl-1, the provider webhook on ctrl-3, the cert-manager webhook one replica on each of ctrl-1, ctrl-2 and ctrl-3, all Ready |
| Per-zone bounded tokens | `docs/plans/2026-10-dns-desec.md` | not done |

**Summary:** Written, applied and read the same day. Flux applied it on its first fetch after the forge outage of
2026-10-06, through the HelmReleases; the rendered artifact of decision 028 carries the same placement.

**Action Required:** None for the placement; the bounded tokens are the deSEC plan's.
