---
title: "Upstream extensions are forked, credited and learned from, never depended on"
description: "Every extension this repository pulls is published by the dataverket collective or by the swamp team itself; a community extension that fits is forked under its own license with its author credited, merged with what we already had, and maintained by us."
type: adr
category: architecture
tags:
  - swamp
  - extensions
  - licenses
  - boundaries
status: accepted
created: 2026-10-05
updated: 2026-10-05
author: dataverket
project: plattform
related:
  - 007-published-extensions-stay-general.md
---
# 026: Upstream extensions are forked, credited and learned from, never depended on

## Status

Accepted. Applied the same day to the three community extensions this repository pulled.

## Context

Until now this repository pulled three community extensions from the swamp registry, `@thomas/forgejo`,
`@goodcraft/github` and `@ginger_pappa/flux`, and published three `@dataverket` packages that only added methods to
their types. Every model definition for a forge, for GitHub or for Flux named a type another person owns, and the
published mirror workflow named two of them. A method we relied on could change shape, go away or stop being
maintained on somebody else's schedule; a known upstream bug, a check that aborts when a default is missing, had to
be worked around in every definition and in the workflow because the fix was not ours to ship.

The code itself is good, and it was how we learned the domain. The problem is the dependency, not the work.

## Decision

Every extension this repository pulls is published by the `@dataverket` collective or by the swamp team itself.

- **Fork, do not wrap.** When a community extension covers the domain, it is forked into `dataverket/swamp-extensions`
  and merged with whatever `@dataverket` package already extended it, so one package owns the type. The add-on
  pattern, a package whose methods land on another collective's type, is not used for anything we run.
- **Check the license first, keep it, credit the author.** Only a license that permits redistribution and
  modification is forked. The upstream copyright line stays in `LICENSE.md` next to ours, with the package name and
  repository it came from; the manifest and the README say what was forked and what changed.
- **Learn, then improve.** Upstream behaviour is kept unless it is wrong. A bug is fixed in the fork and named under
  "Changes from upstream", so a reader of the fork can tell what is inherited and what is ours.
- **The swamp team's own extensions are the exception.** An `@swamp/*` package comes from the project that makes
  swamp itself, which everything here already depends on; forking it would add nothing but a copy to keep in step.
  Those are pulled as they are, and a gap in one is extended locally and reported upstream, as the repository rules
  already say.
- **A copyleft license is a decision of its own.** A permissive license (MIT, BSD, Apache-2.0) is forked without
  further ado. A copyleft one (GPL, AGPL) binds the fork to the same license, which a person decides, per package,
  before any fork is made.

## Consequences

- `@dataverket/forgejo` 2026.10.05.3, `@dataverket/github` 2026.10.05.1 and `@dataverket/flux` 2026.10.05.1 own
  their types; `@thomas/forgejo`, `@goodcraft/github` and `@ginger_pappa/flux` are no longer pulled here, and their
  model definitions moved to the `@dataverket` types with their data intact. `@dataverket/forgejo-github-mirror`
  2026.10.05.1 names only `@dataverket` types.
- The timeout workaround in the forge definitions and the mirror workflow is gone; the fork reads the default itself.
- `@swamp/kubernetes` stays pulled under the exception. It is the only package here from outside the `@dataverket`
  collective.
- A new need is still searched for in the registry first (the repository rules say so), but what the search finds is
  forked, not pulled, before anything here depends on it.

## Decision Outcome

Nothing this repository runs depends on code another person can change or withdraw; what we learned from them is
kept, credited and maintained by us.

## Related Decisions

Published extensions stay general (007): a fork is published for outside reusers too, so the strict rules of this
repository stay here and never enter the fork.
