---
title: "The forge mirrors the Actions its workflows use"
description: "An actions org on the forge holds pull mirrors of the Forgejo project's actions org, made and kept by the forge's own install; workflows pin a mirrored action by commit."
type: adr
category: architecture
tags:
  - forgejo
  - actions
  - flux
status: accepted
created: 2026-10-04
updated: 2026-10-04
author: dataverket
project: plattform
related:
  - 003-cluster-sops-key-never-leaves-the-cluster.md
  - 009-services-are-named-not-addressed.md
  - 021-git-describes-the-cluster.md
---
# 022: The forge mirrors the Actions its workflows use

## Status

Accepted.

## Context

A workflow step `uses: actions/checkout@v4` is resolved against the instance setting `DEFAULT_ACTIONS_URL`, which
on a fresh Forgejo points at `data.forgejo.org`, the Forgejo project's own mirror of the actions it vets. Every job
on this forge therefore cloned from a host outside it, on every run, and a tag there moves when its origin moves it.
The Forgejo project keeps the vetted set in the `actions` org on `code.forgejo.org`: mirrors of the GitHub actions,
and a few of its own.

## Decision

The forge has an `actions` org of its own, and it is part of Forgejo's install, not something a person makes. A Job
in `apps/forgejo/actions-mirror.yaml`, applied by Flux with the release, ensures a bot user `actions-mirror`, a token
for the bot written straight into Secret `forgejo/actions-mirror-token` and nowhere else, the way 003 makes the
cluster's age key, and the org with the bot as its owner. The user and the token are made by the forgejo CLI inside
the forgejo pod, since the forge refuses basic authentication and no password is wanted anywhere; the org is made
by the bot itself over the API, since Forgejo has no CLI for orgs, so the token carries `write:organization` along
with `write:repository` and `read:organization`. A CronJob then
keeps the org equal to or larger than `code.forgejo.org/actions`: every repository there that is missing here is
created as a pull mirror of it, labelled `upstream-mirror` and `actions`. Nothing is ever deleted.

A workflow names a mirrored action by commit, never by tag. Until `DEFAULT_ACTIONS_URL` is `self`, it names the
full address `https://git.dataverket.org/actions/<name>@<commit>`, which resolves whatever the setting says. The
switch to `self` is its own change, since it changes resolution for every org on the forge at once.

## Consequences

- A job depends on nothing outside the forge once the switch is made, and the clone of an action is a clone within
  the cluster.
- The set of available actions is the Forgejo project's, taken as it is. What a workflow trusts is the commit it
  pins, so a new repository appearing in the org grants nothing by itself.
- A composite action names other actions by owner and name; the mirrored set is the project's whole org, so what
  the project's actions need is there too. An action from elsewhere is a new source in the CronJob, not a mirror
  made by hand.
- On a rebuild (021) the Job runs again on the fresh cluster and the CronJob refills the org from the source. The
  mirrors themselves are not data worth keeping.
- No admin credential is involved. The Job's own right is to run a command in the forgejo pod and to write one
  Secret. The CronJob holds only the bot's token, which can create repositories and orgs and read orgs; it owns
  the `actions` org and nothing else on the forge.

## Decision Outcome

The forge's own install makes the org and keeps it filled from the Forgejo project's vetted set; workflows pin by
commit.

## Related Decisions

The in-cluster credential pattern is 003. Addressing the forge by its service name is 009. Rebuild behaviour is 021.
