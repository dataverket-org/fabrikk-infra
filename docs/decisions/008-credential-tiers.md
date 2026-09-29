# 008: Credential tiers

Accepted 2026-09-29.

**Context.** Three kinds of consumer read secrets here: a human operator, swamp and the agents that drive it on the
factory host, and Flux in the cluster. Without a rule for what may live where, credentials landed wherever was
convenient: a year-long Omni key in the vault that could mint cluster admin, a hand-made kubeconfig that never
expired, model definitions reaching into the vault on every run.

**Decision.** Credentials are held in three tiers, and a credential's tier follows from whether it is minted and
expiring, not from how much it can do.

- Tier 1 is what processes hold: the swamp vaults, the Flux files, the cluster's live Secrets. Permanent.
- Tier 2 is what the CLIs read by name: kube and talos contexts, a `clouds.yaml` entry, service account key files.
  On disk, and always minted with a lifetime.
- Tier 3 is how a human turns their own login into tier 2. It has no credentials of its own, only mechanisms.

Five invariants follow. A tier 3 secret is never on disk: a value may live in this repository only if reading it
requires one of the mechanisms, while a reference to where a value lives may always. Tier 2 always expires, so
anything permanent is tier 1 with a named human owner instead. Tier 2 never enters the swamp vault, which would
put the key to tier 1 inside tier 1. Agents reach tier 2 by using it and never by reading the value. Tier 1 is
read by machines; a human reaches it through a tier 2 credential or a YubiKey.

**Consequences.** Both Omni service account keys leave the vault and are minted per sitting instead; model
definitions name a context or a file and never a value; unattended work is bounded by a human's sitting until a
machine identity exists under `swamp serve`; the cluster's `system:masters` kubeconfig is tier 2, while the Talos
PKI and the break-glass configs behind it are tier 1 with a human owner. Steps are in
`docs/plans/2026-09-credential-tiers.md`, and the request model that generalises tier 3 in
`docs/plans/2026-09-access-requests.md`. Refines 001 and 005, supersedes neither.
