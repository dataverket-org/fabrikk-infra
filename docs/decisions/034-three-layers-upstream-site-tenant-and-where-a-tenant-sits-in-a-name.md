---
title: "Three layers: upstream, site, tenant; and where a tenant sits in a name"
description: "dataverket.org names the upstream, the organization that builds and runs the platform; <site>.dvkt.no names one site; a tenant's own zone names the tenant, and Dataverket is also the first tenant. A tenant sits first after the service, in the dimension the service distinguishes tenants by: the hostname for an endpoint service such as S3, the path for a path service such as a registry."
type: adr
category: architecture
tags:
  - naming
  - dns
  - tenants
  - sites
  - zitadel
  - registry
status: accepted
created: 2026-11-07
updated: 2026-11-07
author: dataverket
project: plattform
related:
  - 009-services-are-named-not-addressed.md
  - 013-cluster-fetches-registry-through-service.md
  - 029-s3-in-the-cluster-is-one-versitygw-per-org-on-one-volume.md
  - 031-the-organization-s-services-are-named-under-dataverket-org-a-site-s-under-its-own-zone.md
  - 032-zitadel-s-domains-are-managed-with-a-system-api-user-the-operators-hold.md
---
# 034: Three layers: upstream, site, tenant; and where a tenant sits in a name

## Status

Accepted 2026-11-07. The first consequences are the site-local registry name and the tenant-first repository paths,
`docs/plans/2026-11-site-names.md`.

## Context

031 sorted names into two zones: the organization's services under `dataverket.org`, a site's under
`<site>.dvkt.no`. When Zitadel had been moved under it, a review of every service against the two names kept finding
the same "crossover": the repository at `git.dataverket.org`, the registry at `registry.dataverket.org`, the operator
tooling at `id.dataverket.org`, all platform concerns on what 031 called the organization's names. They are not
mistakes. They are the services of the organization that *builds and runs* the platform, which every site consumes;
031 had no word for that layer. A second site, `osl2.dvkt.no`, made it plain: it would mirror `registry.dataverket.org`
and apply the same repository, as a downstream of the same upstream, and Dataverket would meanwhile be a tenant on
both sites exactly as any other organization would.

## Decision

Three layers, three kinds of zone:

| Layer | Zone | Holds |
|---|---|---|
| **Upstream**: Dataverket as the organization that builds and runs the platform | `dataverket.org` | The services of record every site consumes: `git.dataverket.org` (the repositories, `fabrikk-infra` and the overlay repository beside it), `registry.dataverket.org` (the registry of record: pushes, CI, signing, the registry's own UI), `id.dataverket.org` (the organization's people, its operators among them, and its services' logins) |
| **Site**: one deployment of the platform | `<site>.dvkt.no` | What dies with the site: `id.<site>.dvkt.no` for the site's machines and for the tenants its services see as organizations in it; `registry.<site>.dvkt.no`, the registry as the site's workloads reach it; `<tenant>.s3.<site>.dvkt.no`. Sites are peers at runtime: upstream means source and mirror, never a dependency a site needs at run time to keep serving |
| **Tenant**: an organization using a site | the tenant's own zone | Its people and its services, under names that outlive any site. Dataverket is the first tenant and shares the upstream's zone; that is acceptable while the upstream's people and the tenant's are the same people, and it is why `id.dataverket.org` serves both |

Where a tenant sits in a name follows the dimension the service distinguishes tenants by:

| The service tells tenants apart by | The tenant is | Example |
|---|---|---|
| the endpoint (S3 per 029, a chat realm) | the leftmost label under the service | `dataverket.s3.osl1.dvkt.no` |
| the path (a registry, a git host) | the first path segment | `registry.osl1.dvkt.no/dataverket/www-site`, `git.dataverket.org/dataverket/fabrikk-infra` |

The rule is one rule, "the tenant is the first thing after the service", read in the dimension the service uses. A
service that tells tenants apart by neither is deployed once per tenant, under the tenant's own name.

At one site, a shared service with tenant-first names is naming, not enforcement: zot authorizes by repository
path, versitygw by endpoint and IAM. The names say who owns what and what the mirror of each would be at another
site; enforcement, where wanted, is a second instance of the service behind the same names.

## Consequences

- The site's workloads reference the site's registry name. At the upstream's own site that name is the same zot by
  a second name, no mirror; at another site it is a pull-through mirror of the registry of record, serving from its
  own storage when the upstream is away. Site manifests therefore carry the site as a variable, substituted by Flux
  from one per-cluster ConfigMap, which is the thing an overlay repository takes over later.
- Repositories in the registry become tenant-first: Dataverket's images under `dataverket/`, the platform's mirrors
  under `mirror/`. Pushes, CI and signing keep targeting the registry of record.
- Site services trust the site's issuer. versitygw at osl1 trusts `id.osl1.dvkt.no`, where Dataverket is an
  organization; a tenant's own people reach a site service by federation from their own instance, if ever.
- `id.dataverket.org` and `id.osl1.dvkt.no` are one Zitadel instance today, so the site has no identity of its own
  yet; the site instance is the one open item of this record (`docs/plans/2026-11-site-names.md`). When it exists,
  each instance's primary domain is its own one name, and 032's rule that the primary is the site alias is read as
  applying to the site's instance.
- Two facts stay as they are and are named here so nobody later "fixes" them: the platform's DNS-01 credential
  manages the upstream's zone, and the platform's repository lives on the upstream's forge with GitHub as the
  rebuild source (021). Upstream and platform are the same organization.
- Forgejo's runners are the platform's, running a tenant's jobs; Forgejo itself is the tenant's. A hosted service's
  deployment is the platform's and its identity the tenant's; that is the normal shape, not a crossover.

## Decision Outcome

Three layers name three things: the organization that makes the platform, a place where the platform runs, and an
organization that uses it. One organization can be in two of them at once, and the names are what keep its two
hats apart: acting as the site it is at `osl1.dvkt.no`, acting as Dataverket it is at `dataverket.org`. A tenant's
place in a name is decided by how the service itself tells tenants apart, so that collapsing tenants into one
shared instance, or splitting one out, is an operator's change behind unchanged names.

## Related Decisions

Extends 031 with the upstream layer and the tenant rule; 029 is the endpoint case of the rule; 013 is unchanged, the
cluster still fetches its own configuration through the registry's service name; 032's primary-domain rule is scoped
to the site's instance once it exists.

## Audit

### 2026-11-07

Written after goal G of the Zitadel move closed: every client and definition had been reviewed against the two
names of 031, and the review's "crossovers" were the upstream layer waiting for a name.
