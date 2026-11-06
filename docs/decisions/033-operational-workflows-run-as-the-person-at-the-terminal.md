---
title: "Operational workflows run as the person at the terminal"
description: "A swamp workflow that does what an operator would do by hand runs with that operator's own expiring token, written by their login as a tier 2 file and named by a definition; machine keys are for what runs with nobody present or needs less than a person has; an agent runs the workflow and never reads the token."
type: adr
category: security
tags:
  - swamp
  - credentials
  - workflows
  - zitadel
status: accepted
created: 2026-11-02
updated: 2026-11-02
author: dataverket
project: plattform
related:
  - 001-credential-tiers.md
  - 008-operator-tooling-is-a-taskfile.md
  - 009-services-are-named-not-addressed.md
  - 032-zitadel-s-domains-are-managed-with-a-system-api-user-the-operators-hold.md
---
# 033: Operational workflows run as the person at the terminal

## Status

Accepted 2026-11-02. First case: the passkey registration link workflow of the Zitadel plan.

## Context

Every operational procedure here is either a `bin/` script run by a person, or a swamp workflow run under a machine
key. The Zitadel rename needed a third thing: a procedure a person runs when another person is ready, mailing them
a link, which wants to be a documented, repeatable swamp workflow and at the same time an act of the person running
it, in Zitadel's audit log and in swamp's run record alike.

The repository's own rule stood in the way, not swamp's. `share/admin/zitadel.sh` keeps the operator's device-flow
token in the process and revokes it at exit, so no definition could name it, and the only way to give a workflow
rights was to mint a machine user with those rights. The first draft did that: a third Zitadel key with
`IAM_USER_MANAGER`, kept 48 hours because people answer mail over days. A credential that exists only because the
person's own could not be named.

What swamp needs is a file a definition names, read at call time, whose value the agent running the command never
sees. The reader key and the operator key are such files already. The operator's access token from the device-flow
login is another: issued by the person's passkey, scoped to Zitadel's API, valid twelve hours by the instance's
token policy, and nothing asks for a refresh token, so it dies with the day. Decision 001 calls that tier 2.

## Decision

| Part | Decided |
|---|---|
| The rule | A workflow that does what an operator would do by hand runs as that operator. A machine key is for what runs with nobody present, or for a definition that should hold less than a person does |
| The token | `task admin:zitadel-login` logs the operator in by the device flow and writes the access token to `~/.config/zitadel/fabrikk-infra-me.token`, mode 0600, tier 2: it expires in twelve hours and is renewed by logging in again. `admin:stop` removes it |
| The definition | `zitadel-me`, a `@dataverket/zitadel/user` definition whose `accessTokenFile` names that file. Every operator has the same definition and their own file, as with the key files (009) |
| The extension | `@dataverket/zitadel` takes `accessTokenFile` beside `keyJson` and `keyJsonFile`: the token is sent as the bearer and no exchange happens. The same argument serves every type in the package |
| The agent | Runs `swamp workflow run`, reads the outcome, and never the file (001, invariant 4). Whether a run is started by a person or by an agent on their behalf, Zitadel records the person |
| What stays a machine key | The reader, in every session; the operator key, for definitions that write projects; `iam-admin` for the bootstrap. The 48-hour users key is not made |

## Consequences

- `share/admin/zitadel.sh` stops saying the token lives in the process only; the login writes it when asked to, and
  the scripts that mint keys keep revoking theirs.
- Every operator-paced procedure can be prototyped as a swamp workflow first, with the person's rights and the
  person's name on it, and rewritten in another language later if it outgrows that. The discovery happens where
  the data model is.
- A workflow that is run as a person cannot be scheduled. The day one needs to be, it gets a machine key of its
  own with the least role that serves it, by 001.
- Twelve hours is Zitadel's instance-wide access token lifetime and so applies to every client; it is not shortened
  for this. `task admin` shows the token's expiry with the other tier 2 items.
- Linus runs the same workflows as himself, with his own login and file.

## Decision Outcome

Operational procedures are swamp workflows that act as the people running them, documented and repeatable, and
no credential is minted for a job a person is present for.

## Related Decisions

Applies 001: the token is tier 2 by the tiers' own definition. Keeps 009: the file is named, never a value.
Extends 008: a task writes the token the way other tasks write the kube and talos contexts. 032 is the shape for
the one case a person's own rights are not enough.

## Audit

### 2026-11-02

**Status:** Accepted, not yet applied

**Findings:**

| Finding | Where | Assessment |
|---------|-------|------------|
| The device-flow token is scoped to Zitadel's API and lives twelve hours | `share/admin/zitadel.sh` scope; `zitadel-settings` `oidc-tokens-instance`, read 2026-11-01 | verified |
| The Zitadel type authenticates by key file only today | `@dataverket/zitadel` 2026.10.27.1, `GlobalArgsSchema` | `accessTokenFile` to add |
| The users key branch | `zitadel-passkey-link` in this repository | its key parts are dropped; the workflow and the method stay |

**Summary:** Written when the first operator-paced workflow showed that the missing piece was a named token file,
not another key.

**Action Required:** `accessTokenFile` in the extension, `admin:zitadel-login` and `zitadel-me` here, the branch
reworked.
