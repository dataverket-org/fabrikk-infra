---
title: "Services are named, never addressed"
description: "Every service is reached by a name its own CLI resolves; no script here passes a URL."
type: adr
category: infrastructure
tags:
  - tooling
  - omni
  - openstack
  - kubernetes
status: accepted
created: 2026-09-29
updated: 2026-09-29
author: dataverket
project: plattform
related:
  - 001-credential-tiers.md
  - 008-operator-tooling-is-a-taskfile.md
---
# 009: Services are named, never addressed

## Status

Accepted

## Context

The tooling has to know where this repository's services are. An early version held the Omni URL in the code and
found the OpenStack entry by matching a Keystone address against `clouds.yaml`, using `OS_AUTH_URL` as a
discriminator. That is not what `OS_AUTH_URL` means to anyone who knows OpenStack, and it gave two different
shapes for reaching two services.

## Decision

Every service is reached by a name that its own CLI resolves, the way `kubectl` names a context.

| Service | Named by | Resolved from |
|---|---|---|
| Omni | `OMNI_CONTEXT` | `~/.talos/omni/config` |
| OpenStack | `OS_CLOUD` | `~/.config/openstack/clouds.yaml` |
| Kubernetes | the context name | `~/.kube/config` |
| Talos | the context name | `~/.talos/config` |

No script here passes a URL. Each CLI reads the address, and the identity behind it, out of the operator's own
config file. The two addresses a person needs to set that up once are in the README.

## Consequences

- An entry that is not a person's login is refused rather than used: not the entry this repository writes, and
  not an application credential, which is a machine's credential.
- A credential can never be minted in the wrong place and written under our name.
- A new operator sets up two config entries and exports nothing.
- When Omni is replaced (010), only the name and the config behind it change.

## Decision Outcome

Reaching a service is the same shape everywhere, and replacing one is a change to a name and a config file
rather than to any script.

## Related Decisions

Follows 001.

## Audit

### 2026-09-29

**Status:** Implemented

**Findings:**

| Finding | Where | Assessment |
|---------|-------|------------|
| `OMNI_CONTEXT` and `OS_CLOUD` set in the Taskfile | `taskfiles/admin.yml` | done |
| No URL in any script | `grep -rn "https://" bin/ share/` | verified: empty |
| Wrong or machine entries refused | `share/admin/openstack.sh` | verified |

**Summary:** Applied 2026-09-29, replacing a version that used `OS_AUTH_URL` as a discriminator to find a
`clouds.yaml` entry.

**Action Required:** None.

### 2026-10-01

**Status:** Implemented

**Findings:**

| Finding | Where | Assessment |
|---------|-------|------------|
| Zitadel is named by `ZITADEL_CONTEXT`, resolved from `~/.config/zitadel/config.yaml` | `taskfiles/admin.yml`, `share/admin/zitadel.sh` | done |
| Zitadel has no CLI, so the tasks read that file themselves; it holds an address and a client id and no secret | `share/admin/zitadel.sh` | accepted |
| No URL in any script | `grep -rn "https://" bin/ share/` | verified: empty |

**Summary:** A fifth service, in the same shape. The one difference is who resolves the name: the tasks, since
there is no CLI to do it.

**Action Required:** None.
