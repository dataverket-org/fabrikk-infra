---
title: "Kubernetes authenticates against Zitadel, not Omni"
description: "An OIDC token from Zitadel that lives minutes, and RBAC bound to Zitadel groups, not an Omni flag."
type: adr
category: security
tags:
  - zitadel
  - oidc
  - kubernetes
  - omni
status: proposed
created: 2026-09-29
updated: 2026-09-29
author: dataverket
project: plattform
related:
  - 001-credential-tiers.md
  - 009-services-are-named-not-addressed.md
  - 010-omni-is-not-the-long-term-control-plane.md
---
# 015: Kubernetes authenticates against Zitadel, not Omni

## Status

Proposed

## Context

`omnictl kubeconfig` already writes an OIDC kubeconfig that kubelogin drives; Omni is the identity provider for
Kubernetes here, and has been all along. We opt out of it with `--service-account`, which writes a bearer token
into `~/.kube/config` for the session's lifetime, because a materialised credential is what an unattended run can
use and an `exec` plugin opens a browser.

That leaves the cluster's authentication inside the thing 010 says is not part of future designs, and it leaves
tier 2 holding an eight hour token in a file when an OIDC token would live minutes. Zitadel already runs in this
cluster and already fronts Forgejo.

## Decision

The API server takes Zitadel as its OIDC issuer, and Omni stops being the identity provider for Kubernetes.

- Operators reach the cluster with `kubelogin` against Zitadel. The kube context carries no credential, as the
  talos context already does not.
- RBAC binds Zitadel groups. The readers and admin split stops being an `omnictl --groups` flag and becomes
  ClusterRoleBindings under `infrastructure/`, reconciled by Flux like everything else.
- Automation authenticates as a Zitadel service user with client credentials, not by driving a browser.
- The Omni service-account kubeconfig stays available for as long as Omni does, as a second way in.

## Consequences

- Tier 2 for Kubernetes stops being a file with a credential in it. What expires is a cached token measured in
  minutes rather than a token in a config file measured in hours.
- `admin:kube-admin` and `admin:kube-readers` stop minting. The context becomes static configuration written
  once, and the session has that much less to renew.
- The refresh token beside the ID token is the open question. A long-lived one re-authenticates a person with
  nobody present, which is what invariant 1 exists to refuse, and its lifetime in Zitadel is therefore a policy
  decision rather than a default to accept.
- It needs a route to the API server that is not Omni's proxy, because that proxy authenticates callers with
  Omni's own identity and will not carry a Zitadel token. This decision is not implementable before the overlay
  in `docs/plans/2026-09-break-glass.md`.
- Zitadel would guard the cluster it runs in. A broken cluster means no authentication to fix the cluster, so the
  `os:admin` break-glass path stops being prudence and becomes a requirement.
- It answers what 010 leaves open: a replacement for Omni has to mint credentials with a lifetime on the
  authority of a human login, and this is the first service where Dataverket does that for itself.

## Decision Outcome

Day to day access to the cluster that does not pass through Omni, credentials that live minutes instead of hours,
and the readers and admin split visible in git rather than in an argument someone remembered to pass.

## Related Decisions

Follows 001 and 010. The context stays named rather than addressed, so 009 is unchanged.

## Audit

### 2026-09-29

**Status:** Pending

**Findings:**

| Finding | Where | Assessment |
|---------|-------|------------|
| Decision recorded, nothing built | `docs/plans/2026-09-kubernetes-identity.md` | proposed |
| Route to the API server | the overlay in the break-glass plan | not built |
| Refresh token lifetime | Zitadel | not decided |

**Summary:** Proposed 2026-09-29 alongside its plan. Blocked on the break-glass overlay, which it shares a route
with.

**Action Required:** Settle the refresh token lifetime and the service user before the API server is patched.
Nothing here is safe to do piecemeal: an API server that trusts Zitadel while no one can reach it except through
Omni's proxy is worse than either end state.
