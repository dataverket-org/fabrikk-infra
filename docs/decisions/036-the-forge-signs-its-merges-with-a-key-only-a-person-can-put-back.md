---
title: "The forge signs its merges, with a key only a person can put back"
description: "A commit on a branch is unsigned; the signature is on the merge, made by a person or by the forge with an instance key of its own. The key's private half is in the cluster as one hand-made Secret and in vaults/operator/, never in a cluster file, so Flux cannot restore it and a rebuilt forge does not sign until a person has."
type: adr
category: security
tags:
  - forgejo
  - signing
  - supply-chain
status: accepted
created: 2026-11-18
updated: 2026-11-18
author: dataverket
project: plattform
related:
  - 002-two-sops-stores-one-reader-each.md
  - 016-operator-values-live-in-vaults-operator.md
  - 021-git-describes-the-cluster.md
  - 028-upstream-charts-are-rendered-in-the-factory.md
---
# 036: The forge signs its merges, with a key only a person can put back

## Status

Accepted.

## Context

Everything that reaches `main` is to be signed. An agent's commits are not: a signature on a commit says its signer
stands behind it, and a commit on a branch has not been reviewed by anyone. The signature therefore belongs on the
merge, where it attests the whole branch. A person can make that merge at a terminal with a YubiKey. A merge made
with the forge's own button was unsigned until now, so a protected branch that takes no direct pushes received
unsigned merge commits (`apps/forgejo/README.md` said so).

Forgejo can sign the commits it makes itself with an instance key. Three facts about it shape the decision, all
tested on Forgejo 15.0.11 on 2026-11-18:

- An instance key cannot be rotated: Forgejo's documentation says so, and a new key leaves every earlier merge
  unverified.
- With the private half missing, a merge fails and no unsigned merge is made. With the public half missing, the
  forge does not start.
- A branch rule that requires signed commits refuses a merge of a branch with unsigned commits, so that rule cannot
  be the control here.

Every other Secret the cluster uses is a cluster file that Flux decrypts and applies (README, Secrets), which is
what lets a rebuild restore the cluster from git alone (021).

## Decision

The forge signs merge commits, and only those: `MERGES = always`, and `never` for initial commits, web and API
edits and wiki changes, which nobody has reviewed. The key is an ed25519 SSH key made inside the forge pod, with the
identity `git.dataverket.org <noreply@dataverket.org>`.

The private half exists in two places. In the cluster it is the Secret `forgejo/forgejo-ssh-signing-key`, made by a
person and named by the chart's values; the chart's init container installs it onto the data volume on every start.
At rest it is `vaults/operator/osl1/forgejo-signing.enc.json`, readable by the two operators alone (016). It is
never a cluster file, so no process key is a recipient and Flux cannot put it back.

The control on `main` is the pair: a branch rule that takes no direct pushes, and a forge that signs every merge.
`requireSignedCommits` stays off.

## Consequences

- A merge commit made by the forge shows as verified, signed by the instance key. What it attests is that the merge
  went through the forge's rules for that branch, not that a person read it.
- A rebuilt cluster has no signing key. The forge's pod waits for the Secret and the forge is down until a person
  has restored it from `vaults/operator/` with a YubiKey (`docs/runbooks/forge-signing-key.md`). This is the one
  place where a rebuild needs more than git and the database archives, and it is on purpose: the key that attests
  what reaches `main` is not something a process can give itself.
- The key is the forge's for good. Losing both copies means a new key and every earlier forge merge shown as
  unverified.
- Anyone with exec in the forge pod or read on its Secrets holds the key. Both need the admin context, which is
  minted for a working day (001).
- The Secret is the only one a person makes by hand. The others that are not cluster files are made by a process:
  the cluster's age key and the actions mirror's token by Jobs (003, 022), the release runner's by the
  `fabrikk-runner` workflow. The README's Secrets section and `backup/README.md` name it as the exception.

## Decision Outcome

Signed merges from the forge, with the instance key held by the operators and restored by hand.

## Related Decisions

The operators' store is 016, and copying between stores is a person's step (002). A rebuild from git is 021; this
decision is its one exception. Artifact signing with a per-site cosign key is 028.

## Audit

### 2026-11-20

| Finding | Evidence | Status |
|---|---|---|
| The key | Made in the forge pod on 2026-11-18 through `forgejo-pods exec`; SHA256:4vCkwj+dF1F3zbrsmt3xoY/Zuew2ojWdis3/FC/40KA | done |
| The operators' copy and the Secret | `vaults/operator/osl1/forgejo-signing.enc.json`, commit `4893a9b`; the Secret made from that copy by a person on 2026-11-19 | done |
| The settings applied | `platform/forgejo-config` `current@sha256:c19eb918…` from the signed merge `337e33c`, applied 09:00 UTC; the forge serves the key at `/api/v1/signing-key.ssh` | done |
| A signed merge | `1ca7fa9`, pull request 30 on this repository, verified as `git.dataverket.org <noreply@dataverket.org>` | done |
| The key watched | Endpoint model `forge-signing-key` in the `health` workflow; it fails on a 404 and on another key, tested with a wrong key | done |
| The put-back on an empty volume | A kind cluster with the chart's own init containers and a throwaway key: the pod waits without the Secret, starts by itself when step 2 has run, and signs a merge (`docs/runbooks/forge-signing-key.md`, "Tested on an empty volume") | done |
| The put-back in a real rebuild | No rebuild has been run (021's audit) | open |

**Summary:** The forge signs its merges. The consequence that named this Secret "the one hand-made Secret in the
cluster" was wrong about the release runner's Secrets, which a workflow makes, and reads correctly now.

**Action Required:** Run the put-back as part of the first rebuild test, on a Cinder volume and with Postgres.
