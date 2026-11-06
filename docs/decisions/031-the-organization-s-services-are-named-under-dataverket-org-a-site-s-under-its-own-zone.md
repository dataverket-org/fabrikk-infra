---
title: "The organization's services are named under dataverket.org; a site's under its own zone"
description: "A service people and clients bind to carries a dataverket.org name that outlives any site; the same service at a site also answers on <service>.<site>.dvkt.no, the alias that says where it runs; a service that is a site's by nature, S3, has only the site name."
type: adr
category: architecture
tags:
  - naming
  - dns
  - zitadel
  - sites
status: accepted
created: 2026-11-02
updated: 2026-11-02
author: dataverket
project: plattform
related:
  - 009-services-are-named-not-addressed.md
  - 029-s3-in-the-cluster-is-one-versitygw-per-org-on-one-volume.md
  - 032-zitadel-s-domains-are-managed-with-a-system-api-user-the-operators-hold.md
---
# 031: The organization's services are named under dataverket.org; a site's under its own zone

## Status

Accepted 2026-11-02. Nothing renamed yet; the first case is Zitadel, `docs/plans/2026-11-zitadel-auth-osl1.md`.

## Context

The Zitadel rename of 2026-11-01 moved the login from `zitadel.dataverket.org` to `auth.osl1.dvkt.no`, a name in the
osl1 site's zone, and in doing so showed what a hostname costs an identity provider: the OIDC issuer every client
is configured with is the host, and a passkey is bound by the browser to the host it was made on. A site's name
changes when the site does. Binding people and clients to it means every future site move is a second migration of
the same shape, with the same lockout risk for passkey-only accounts.

`git.`, `registry.`, `forum.` and `www.dataverket.org` already follow the other pattern: a name that says what the
service is and belongs to the organization, not to where it happens to run. `dataverket.s3.osl1.dvkt.no` (029) is
the exception that proves the rule: an S3 endpoint is a site's by nature, since its data is on that site's disks.

## Decision

| Kind of name | Form | Who binds to it |
|---|---|---|
| The organization's service | `<service>.dataverket.org` | People, clients, issuers, passkeys. It outlives any site and can be served from another one |
| The same service at a site | `<service>.<site>.dvkt.no` | Anything site-specific and internal: the site's cluster API server trusting its Zitadel (015), the site's own health checks, a rescue, reaching one site's instance when two exist. What is internal to a site stays on the site's name and never leaks to the organization's. A person who logs in there for the site's sake holds a passkey on the alias too, one per site |
| A service that is a site's by nature | `<name>.<site>.dvkt.no` only | As 029: S3, and whatever else is bound to a site's hardware |

The organization's name and the site alias are the same service and the same name in both zones: Zitadel is
`id.dataverket.org` and `id.osl1.dvkt.no`, not `auth.` in one and `id.` in the other.

## Consequences

- Zitadel's rename is redirected before anyone binds to `auth.osl1.dvkt.no`: `id.dataverket.org` becomes the name
  the login, the clients and the passkeys use, `id.osl1.dvkt.no` the alias, and `auth.osl1.dvkt.no` is retired.
- A service with two names needs a server that answers on both. Zitadel does, as instance domains; Envoy does, as
  hostnames on a route. A future service that cannot is given the organization's name only.
- Moving `dataverket.org` to deSEC (`docs/plans/2026-10-dns-desec.md`) gains a reason: a rescue flips a record in
  that zone, and the site that takes over must be able to write it, which deSEC's per-name tokens allow.
- The site alias is also what a rescue playbook names: the primary instance domain of Zitadel is the alias of the
  site that runs it (032).
- A site-bound consumer binds to the alias on purpose. The osl1 cluster's API server, when 015 is built, takes
  `https://id.osl1.dvkt.no` as its issuer, so a credential for the cluster is as site-bound as the cluster, and an
  operator's passkey for it is registered on the alias, one per site.

## Decision Outcome

The two zones name two layers. `dataverket.org` names the organization's services, which are not the platform but
things that use it, and so are named for what they are and can be served from any site. `<site>.dvkt.no` names the
platform itself at one site: its cluster, its gateways, its disks, and the alias under which a service happens to
run there. A name a person or a client remembers never changes because a site did; the name that changes is one
only the platform's operators use.

## Related Decisions

Refines 009, which says a service is reached by a name and not an address: this says which name. 029 stays the
rule for S3. 032 puts the rule into Zitadel's own domain list.

## Audit

### 2026-11-02

**Status:** Accepted, not yet applied

**Findings:**

| Finding | Where | Assessment |
|---------|-------|------------|
| Zitadel answers on `zitadel.dataverket.org` and `auth.osl1.dvkt.no`; nothing has bound to the second | `docs/plans/2026-11-zitadel-auth-osl1.md`, audit of goal D | the pivot to `id.` is the plan's next goal |
| The other services | `git.`, `registry.`, `forum.`, `www.dataverket.org` | already in the form; no site alias yet, none needed until a second site runs one |
| S3 | `dataverket.s3.osl1.dvkt.no` | the stated exception, unchanged |

**Summary:** Written after the first rename showed the cost of a site name. The pivot applies it.

**Action Required:** The pivot goal in the Zitadel plan.
