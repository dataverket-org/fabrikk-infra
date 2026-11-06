---
title: "Zitadel's domains are managed with a System API user the operators hold"
description: "One SYSTEM_OWNER key, private half in vaults/operator/, public half in the chart's config, used from a terminal for one run at a time to add, remove and set the primary instance domain; the primary names the site that runs the instance."
type: adr
category: security
tags:
  - zitadel
  - credentials
  - domains
  - rescue
status: accepted
created: 2026-11-02
updated: 2026-11-02
author: dataverket
project: plattform
related:
  - 001-credential-tiers.md
  - 004-human-only-material-stays-outside-swamp.md
  - 006-cluster-repo-owns-credentials.md
  - 016-operator-values-live-in-vaults-operator.md
  - 031-the-organization-s-services-are-named-under-dataverket-org-a-site-s-under-its-own-zone.md
  - 033-operational-workflows-run-as-the-person-at-the-terminal.md
---
# 032: Zitadel's domains are managed with a System API user the operators hold

## Status

Accepted 2026-11-02. The key is not minted; the Zitadel plan's pivot goal mints it.

## Context

Zitadel resolves every request by its Host against the instance's domain list, and three facts about that list
were read in the source of the running version (v4.15.3) during the rename:

- Setup adds the configured `ExternalDomain` and a generated `<random>.<ExternalDomain>` to the list and removes
  nothing, so every name an instance ever had stays. After one rename the instance carries four domains, two of
  them never to be used again.
- The one domain flagged primary is set at the first setup and never moved by a later one. It matters in one place:
  a mail Zitadel sends with no request behind it links to the primary domain.
- Adding or removing a custom domain and setting the primary need the permission `system.domain.write`, which only
  the system role `SYSTEM_OWNER` carries; the roles a user or a key in an organization can hold reach the trusted
  domains list at most. The System API user is a key named in Zitadel's configuration, not a user in its database.

Decision 031 wants the primary domain to be the alias of the site that runs the instance, since it is the one place
a hostname is chosen without a request to copy it from, and a rescue moves the instance between sites. That is a
change of the primary, which nothing but a System API user can make. The alternative considered, editing the row
in `projections.instance_domains`, is a projection of the event store: setup rebuilds it on every upgrade and the
edit would silently revert.

`SYSTEM_OWNER` is wide: instance create and delete, features, limits and quotas. The credential's reach exceeds
the instance's own, which 001 says is the shape that must be held by a person and expire or be guarded by a key.

## Decision

| Part | Decided |
|---|---|
| The key | One RSA key pair made by an operator at a terminal. The private half is `vaults/operator/osl1/zitadel-system.enc.json`, tier 3 with a human owner, readable by the two YubiKeys and nothing else (016). It never reaches a host's disk, a swamp vault or a cluster |
| What Zitadel knows | The public certificate, as `SystemAPIUsers.operators` in the HelmRelease's config beside the login client the chart adds, memberships `System` with `SYSTEM_OWNER`. Public, so it is plain in git; a rescue cluster carries the same config and so trusts the same key |
| How it is used | From a terminal, for one run: `sops exec-file` decrypts the key into a path that exists for the command's lifetime, a swamp type `@dataverket/zitadel/system` reads it there and signs the system JWT. The operator touches the YubiKey; the agent that runs the command sees a path (001, invariant 4) |
| For what | Three operations and no other: add a custom domain, remove one, set the primary. Anything else `SYSTEM_OWNER` could do is out of scope, and the type offers no method for it |
| The primary | The alias of the site that runs the instance, `id.<site>.dvkt.no`. Set when the instance moves; part of the rescue playbook |

## Consequences

- The Zitadel rename gets a clean end: `auth.osl1.dvkt.no` and its generated twin are removed rather than left,
  and `zitadel.dataverket.org` is removed when it retires. `ExternalDomain` goes straight to the organization's
  name; the site alias is added by the task, not by a detour through `ExternalDomain`.
- A rescue flips the instance in three calls: add the new site's alias, set it primary, remove the old one.
- Mails Zitadel sends on its own schedule link to the site alias, as 031 intends. A passkey registered from such a
  link binds to the site name; the playbook re-mails links through the workflow on the organization's name.
- A new type in `@dataverket/zitadel` with `systemKeyFile` and the three methods, and a task `admin:zitadel-domains`
  here that wraps `sops exec-file` around the run.
- The key is the second value in the operator store that reaches the whole of a service, after the hov1 root key;
  `task admin` lists neither, since neither is on a host, and the store's README says what each is for.

## Decision Outcome

Zitadel's domain list says what the instance is called and where it runs, kept by the operators with a key no
process holds, and a rename or a rescue leaves nothing behind in it.

## Related Decisions

Follows 001 and 016 for where the key lives and who reads it; 004 for why it is outside swamp's reach; 006 for the
public half being authored here and copied into the chart. Serves 031. 033 gives the same shape to the operators'
own logins.

## Audit

### 2026-11-02

**Status:** Accepted, not yet applied

**Findings:**

| Finding | Where | Assessment |
|---------|-------|------------|
| Permission and role verified in the source | `proto/zitadel/instance/v2/instance_service.proto`, `cmd/defaults.yaml` of v4.15.3 | `system.domain.write`, `SYSTEM_OWNER` only |
| The chart merges a user-supplied `SystemAPIUsers` map with its login client | `zitadel-charts` 10.0.4, `_helpers.tpl` | verified |
| The key, the type, the task | not made | the pivot goal |

**Summary:** Written before the pivot so the pivot can remove what the rename left.

**Action Required:** Mint the key, add the public half to the HelmRelease, build the type and the task.

### 2026-11-06

**Status:** The type exists; the key is not minted

**Findings:**

| Finding | Where | Assessment |
|---------|-------|------------|
| `@dataverket/zitadel/system` with `domainList`, `domainAdd`, `domainRemove`, `domainSetPrimary` | `@dataverket/zitadel` 2026.11.02.1, published 2026-11-06 | done, proven live against v4.15.3 in podman with a `SystemAPIUsers` key |
| A generated domain can be removed by nobody | `internal/command/instance_domain.go`, `GeneratedNotRemovable`; the type refuses it first | the Consequences above overstate: `auth.osl1.dvkt.no` goes, its generated twin stays; so does every generated twin, unrouted and harmless. The list is as clean as Zitadel allows, not cleaner |
| The key, the HelmRelease entry, the task | not made | the pivot goal |

**Summary:** The tool is there; what it cannot do is written down.

**Action Required:** As above, less the generated twins.
