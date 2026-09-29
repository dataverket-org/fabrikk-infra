---
title: "Published extensions stay general; our policy stays here"
description: "A published extension states the trade-off and ranks neither option; our rules stay in this repository."
type: adr
category: architecture
tags:
  - swamp
  - extensions
  - boundaries
status: accepted
created: 2026-09-29
updated: 2026-09-29
author: dataverket
project: plattform
---
# 007: Published extensions stay general; our policy stays here

## Status

Accepted

## Context

The `@dataverket` swamp extensions are published and reused by other people and projects. When this repository's
rules are strict, the temptation is to write them into the extension, where they read as the type's own opinion.
A schema that says one credential form is "preferred" is stating our policy to somebody whose constraints we do
not know.

## Decision

An extension offers each option on its own merits and states the criterion for choosing, and ranks neither. This
repository's rules live in its own decisions, definitions and documents.

## Consequences

- `serviceAccountKeyFile` and `serviceAccountKey` are documented as "for a key an operator's session writes" and
  "for a key a process owns". Neither is called preferred, though 001 makes the file form the only one allowed
  here.
- A rule that would constrain an outside user belongs in a definition in this repository, never in a type.
- The same applies in reverse: an extension may not assume our layout, our names or our lifetimes.

## Decision Outcome

An extension can be adopted by someone whose constraints differ from ours without them having to read past
our policy to find the mechanism.

## Audit

### 2026-09-29

**Status:** Implemented

**Findings:**

| Finding | Where | Assessment |
|---------|-------|------------|
| Both credential forms documented with the criterion | `@dataverket/omnictl`, `@dataverket/talosctl` | done |
| No ranking language in either schema | published 2026.09.29.1 and 2026.09.29.2 | done |

**Summary:** Applied 2026-09-29, after a first version that called the file form "preferred" in a published type.

**Action Required:** None.
