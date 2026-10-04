---
title: "The actions mirror is a frozen copy, promoted after a quarantine"
description: "The actions org syncs from its source only when the source's newest change is seven days old; workflows use tags, and the mirror, not a pinned commit, is where what they get is controlled."
type: adr
category: security
tags:
  - forgejo
  - actions
  - supply-chain
status: accepted
created: 2026-10-04
updated: 2026-10-04
author: dataverket
project: plattform
related:
  - 021-git-describes-the-cluster.md
  - 022-the-forge-mirrors-the-actions-its-workflows-use.md
---
# 023: The actions mirror is a frozen copy, promoted after a quarantine

## Status

Accepted. Replaces the rule in 022 that a workflow pins a mirrored action by commit.

## Context

022 put every action a workflow uses behind the forge's own `actions` org, and asked workflows to name a commit
rather than a tag, since a tag on a mirror moves when its origin moves it. Pinning by commit is the usual advice and
it is unrealistic here: it asks every workflow author to maintain forty-character hashes, and in practice people
pin whatever is current, which is no control at all. The control belongs at the one place every `uses:` passes
through, the mirror. A live mirror serves a moved tag within hours, which is how a compromised action reaches its
users in the known incidents; most of those are noticed and reverted within days.

## Decision

The `actions` org is a frozen copy of its source. Every mirror in it has no sync interval of its own. The mirror
job runs daily and promotes a repository, by creating it here or by syncing it, only when the source's newest
change is seven days old, read from the source repository's `updated_at`, which moves on a push or a tag and not on
the source's own mirror syncs. A sync takes every ref of that repository at once. Nothing is ever deleted.

A workflow names an action by tag, `actions/checkout@v4`, and gets what the mirror has promoted. An action from
outside the org needs its full address, which is the exception a review looks for.

A person promotes early, for a fix that cannot wait, by running the job with `QUARANTINE_DAYS=0`. The job's log is
the record: what was promoted, carrying a change of which date, and what is waiting.

## Consequences

- A tag moved to a bad commit and reverted within the week never reaches this forge. One that stays bad longer does,
  as it would have reached a pinned workflow updated in that time.
- Fixes to actions arrive a week late unless promoted by hand. The week is a number in the CronJob.
- The granularity is a repository. One with an old tag and a new one waits for the new one.
- The org's contents are the allowlist, the source org is what the Forgejo project vets, and the job's log and the
  forge's mirror records are the audit. A check that no workflow names a full address, and a report that compares
  the mirror with its source, are the two pieces not built yet.
- The org and its mirrors are made by the forge's own install (022), so a rebuild (021) starts frozen too: a new
  repository is created at the source's state only once that state is seven days old.

## Decision Outcome

Control at the mirror, with a seven-day quarantine and a daily run; tags in workflows.

## Related Decisions

Changes one rule of 022 and keeps the rest. Rebuild behaviour is 021.
