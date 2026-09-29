---
title: "Operator tooling is a Taskfile over bin/ and share/"
description: "Tasks name and order the work, bin/ and share/ do it, and neither names this cluster or cloud."
type: adr
category: infrastructure
tags:
  - task
  - bash
  - tooling
status: accepted
created: 2026-09-29
updated: 2026-09-29
author: dataverket
project: plattform
related:
  - 009-services-are-named-not-addressed.md
---
# 008: Operator tooling is a Taskfile over bin/ and share/

## Status

Accepted

## Context

Tier 1 is the code an operator runs by hand to get the day's credentials. It could be a pile of scripts with
flags, a swamp workflow, or a driver with the logic inside it. Whatever it is, another repository will want to
reuse it, and an agent will read it before it runs it.

## Decision

`Taskfile.yml` includes one file per namespace under `taskfiles/`, and `task --list` is the list of what an
operator does here. Behind each task is one executable in `bin/`, named after it, over libraries in `share/`.

- The Taskfile holds names, order, descriptions and what this repository administers. No logic. Anything needing
  a conditional, a loop or a computed value is a script, which is why dueness is `bin/due` and not a template
  expression.
- `taskfiles/admin.yml` sets `SWAMP_REPO`, `CLUSTER`, `OMNI_CONTEXT` and `OS_CLOUD`. Nothing under `bin/` or
  `share/` names this cluster, this Omni or this cloud, so another repository reuses them unchanged.
- The scripts require all four and default none. A missing value stops a run rather than pointing it at somebody
  else's cluster. A shell that exports one wins over the Taskfile.
- Settings are environment variables, not flags, because the entry point is a task name and not a command line.

## Consequences

- A script in `bin/` runs alone as well as under `task`, which is how it is debugged.
- The shape follows the `kode/skills` repository, so the two read the same way.
- `bin/` and `share/` follow the `bash-style` skill; `shellcheck -s bash -e SC2034,SC2154,SC1090,SC1091,SC2242
  bin/* share/*.sh share/admin/*.sh` is the check.

## Decision Outcome

A second repository can reuse the tooling by writing its own `taskfiles/`, and an agent reading
`task --list` sees the whole operator surface without reading any code.

## Audit

### 2026-09-29

**Status:** Implemented

**Findings:**

| Finding | Where | Assessment |
|---------|-------|------------|
| Ten scripts in `bin/`, six libraries in `share/` | `bin/`, `share/` | done |
| No cluster or cloud name in the code | `grep -rn "dataverket-prod\|siderolabs\|nexthop" bin/ share/` | verified: empty |
| Style and lint | `shellcheck -s bash -e SC2034,SC2154,SC1090,SC1091,SC2242` | passes |

**Summary:** Applied 2026-09-29.

**Action Required:** None.
