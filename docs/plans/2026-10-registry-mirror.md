# Plan: the registry mirror, pinned in git and promoted by people

Written 2026-10-30. Nothing here is applied. Upstream images reach Dataverket's clusters only through
`registry.dataverket.org/mirror/`, each one pinned by digest in git, quarantined for seven days, approved by an
operator and signed by the cluster. Smaller sites run a zot of their own that holds only what has been signed. The
tools are ones in common use: Renovate, regclient, zot, cosign, Kyverno and Trivy, all running in the cluster under
Flux. Swamp has no part in it.

## Where we are, 2026-10-30

| Fact | Consequence for this plan |
|---|---|
| zot 2.1.21 has `compat: ["docker2s2"]` since `fc7120c` and keeps Docker's manifest types byte for byte. Without it, `registry.k8s.io/pause` was refused | Digests stay the upstream's, which pinning, signatures and transparent mirrors all depend on |
| `@dataverket/crane` 2026.10.29.2 copies to `mirror/<registry>/<path>`, the path a registry mirror asks for. `mirror/docker.io/library/nats` is the only repository in the new layout | The layout stays; the copying moves into the cluster (step 3) |
| `mirror/nats` and `mirror/static` are left in the old, flat layout | Removed once operators can delete (step 1) |
| `fabrikk-ci` can write to every repository, `mirror/` included | `mirror/` gets one machine writer of its own (step 1) |
| zot collects untagged manifests after `gcDelay: 1h` | A pin that loses its tag would be gone within an hour. Retention must keep every digest in the lockfile (step 2) |
| Tested locally with zot 2.1.21: a sync from one zot to another keeps digests with `preserveDigest: true`, and `stripPrefix` maps `mirror/docker.io/**` to `docker.io/**` | An edge zot can serve the mirror under its upstream names |
| zot's sync option `onlySigned` checks only that some signature exists (`pkg/extensions/sync/service.go:694`), not whose | An edge cannot rely on it to accept only our signatures (decision D) |

## Two modes

| Mode | Runs where | Holds | Reads from |
|---|---|---|---|
| **intake** | `dataverket-prod`, `registry.dataverket.org` | `candidates/<registry>/<path>`: every upstream release newer than the current pin, visible to operators and the promotion job only. `mirror/<registry>/<path>`: pins only, signed, read anonymously | Upstream registries |
| **edge** | A site's own zot: the laptop's ToR, a smaller cluster | `mirror/<registry>/<path>`: signed pins only; current pins kept for good, earlier pins for 90 days | The intake's `mirror/`, never `candidates/` |

The modes are named for their job, not by rank, since an edge deliberately holds less than the intake does.

## The lockfile

`mirror/images.yaml` lists every image the mirror holds, one fully qualified reference per line, tag and digest
both: `docker.io/library/nats:2.15.0-alpine@sha256:004796…`. `mirror/talos.yaml` is generated from
`talosctl image talos-bundle` and `talosctl image k8s-bundle` for one Talos version, so Talos's images move as one
set. Each entry can carry a waiver of the quarantine, with a reason (see "The seven-day rule"). The regclient
config, the candidate filters and the edge's retention are all generated from these files, never written by hand.

## Promotion

1. **Candidates.** On the intake, regsync syncs every release newer than the pin into `candidates/`, with
   `referrers` and `digestTags` so that upstream signatures, SBOMs and provenance arrive with each image. zot
   records when each digest was pushed: that is when we first saw it.
2. **Proposal.** Renovate, in the cluster on the Forgejo platform, opens a PR that moves the pin's tag and digest
   in the lockfile. For Talos it moves the version, and a `postUpgradeTask` regenerates `mirror/talos.yaml`.
3. **Decision.** Branch protection on `main` requires an operator's approval. The merge commit is signed with an
   operator's key, by SSH signing on the YubiKey.
4. **Signature.** The promotion job verifies the commit against the operators' `allowed_signers`, checks the
   seven-day rule, copies the digest from `candidates/` into `mirror/` with `regctl image copy --referrers`, and
   signs it with the cluster's mirror key. Alongside the signature goes an in-toto attestation: the digest, the
   upstream reference, when we first saw it, the PR, the merge commit and its signer, and any waiver.

The cluster signs, but only what an operator decided, and the attestation shows which operator and when.

## The seven-day rule

The clock starts when the intake first saw the digest, never at the image's `created`, which the publisher writes
and can backdate.

1. **The promotion job refuses** a digest first seen less than seven days ago. That is where the rule is enforced.
2. **A waiver** in the lockfile, with a reason, lets the job sign earlier. The job takes a waiver only from an
   operator-signed commit and writes it into the attestation, so every exception is on record with its author.
3. **Kyverno checks it again** at admission: an image whose attestation shows less than seven days between
   `firstSeen` and promotion, with no waiver, is refused.

Renovate's `minimumReleaseAge: "7 days"` comes on top, so that it opens no PR the job would refuse.

## Referencing an image

Both forms work, and both pull the same digest.

| Form | Example | Used for |
|---|---|---|
| Explicit | `registry.dataverket.org/mirror/docker.io/library/nats:2.15.0-alpine@sha256:004796…` | Manifests we write |
| Transparent | `docker.io/library/nats@sha256:004796…`, which Talos sends to `https://registry.dataverket.org/v2/mirror/docker.io` with `overridePath: true` | Talos's own images, and charts with fixed references |

Transparent mirrors need `skipFallback: true` in Talos. Without it containerd fetches from the upstream whenever the
mirror cannot serve, which defeats the purpose. Kyverno and cosign look for a signature at the registry the
reference names, so a Kyverno mutation rule rewrites transparent references to explicit ones at admission: one
form to verify and to audit. The transparent endpoint points at `mirror/` only, so `candidates/` is never reachable
through it.

## Security, SBOM and compliance

- **Signature:** the cluster's key on every pin. Kyverno `verifyImages` requires it, a digest, and
  `registry.dataverket.org/mirror/` as the image's origin.
- **SBOM:** upstream SBOMs and attestations are copied as referrers. An image without one gets an SBOM generated
  by Trivy and attached with `cosign attest`, under the same key. Kyverno can require one or the other.
- **Scanning:** zot's built-in Trivy CVE scan (`search.cve`) on everything stored, and Trivy Operator's
  vulnerability, SBOM and compliance reports (CIS, NSA) on what runs.
- **Audit:** git holds every decision and waiver. Each signed attestation ties a digest to its decision, and zot's
  audit log (`log.audit`) records every write.

## Decisions

- **A. Mode names: intake and edge.** Other candidates were primary and replica (which suggests identical content),
  and curator and follower.
- **B. Copying: regsync for candidates, `regctl image copy` for promotion.** The regsync documentation shows tag
  filters, `semverRange`, `referrers` and `digestTags`, but no source pinned by digest, and it does not say whether
  media types are kept. A pin is therefore copied by `regctl`, digest by digest, from the same project. Step 3
  proves both.
- **C. The cluster's mirror key** is a cosign key in a Secret encrypted to the cluster's own key, separate from
  the site key on the YubiKey, which signs config artifacts and needs a touch. A KMS replaces it when there is one.
- **D. Verification on an edge** is a CronJob: `cosign verify --key <mirror key>` and `cosign verify-attestation`,
  then `regctl image copy --referrers` for what passes, since `onlySigned` does not verify. Ratify (CNCF) is the
  off-the-shelf alternative, should the job grow.
- **E. Writers.** `mirror-pipeline` is a zot user that can write `mirror/**` and `candidates/**` and nothing else.
  Its password is a Secret encrypted to the cluster key, until workload identity replaces it
  (`docs/plans/2026-09-kubernetes-identity.md`, and Salmon). Operators get `delete`, by e-mail until Zitadel gives a
  groups claim. `fabrikk-ci` loses its write access to `mirror/`.

## Steps

1. **Access.** In `artifacts/zot/configmap.yaml`: `mirror/**` and `candidates/**` entries for `mirror-pipeline`
   and the operators, and `candidates/**` closed to anonymous reads; `mirror-pipeline` made with `task zot:user`;
   `mirror/nats` and `mirror/static` deleted. Check: `fabrikk-ci` is refused a push to `mirror/`, an anonymous
   pull of `mirror/` succeeds, and one of `candidates/` is refused.
2. **Retention.** zot keeps every lockfile digest by tag, everything else in `mirror/` untouched, and the newest
   candidates per repository by `mostRecentlyPushedCount`; `deleteReferrers: false`. Check: a candidate past the
   count disappears, a pin does not.
3. **Spike, in kind, before anything reaches production:** zot 2.1.22 as intake and as edge, regsync, the
   promotion job, Kyverno. Check:
   - a pin is copied with its referrers and the same digest;
   - a digest first seen less than seven days ago is refused, and a waiver lets it through;
   - the edge takes a signed pin and refuses one signed by another key;
   - a transparent reference is rewritten and verified;
   - an unpinned image is refused at admission;
   - a moved upstream tag changes only `candidates/`.
4. **The lockfile and the intake:** `mirror/`, regsync as a CronJob, the promotion job, all under Flux. nats
   moves into the lockfile as its first entry. Check: a merged pin is in `mirror/` signed within one run, and
   `health` finds every lockfile entry at its digest.
5. **Renovate** as a CronJob, its own image mirrored by hand once and then pinned in the lockfile like any other.
   Check: a PR for a release older than seven days, none for a newer one.
6. **Admission:** Kyverno in `infrastructure/`, in `Audit` mode for a week, then `Enforce`. Check: a pod with an
   upstream reference is rewritten or refused, and one with a signed pin starts.
7. **Talos:** registry mirrors with `overridePath` and `skipFallback`, a patch under `talos/`. Check: a node pulls
   `registry.k8s.io/pause` through the mirror, and fails when the mirror is down instead of falling back.
8. **The first edge**, the ToR in akkurat-nok-nett, syncing from `mirror/`. Check: a pin removed from the lockfile
   is still served by the edge for 90 days, then not.
9. **Record it:** a decision that upstream images enter only through the mirror, pinned, quarantined and signed.

## What is assumed and must be checked

- That regsync filters by `semverRange` against a version generated from the lockfile, and that `regctl` keeps
  media types and digests (step 3).
- That zot's push time is a trustworthy first-seen time and readable through its API, or else the intake records
  first-seen itself.
- That Kyverno can read a custom in-toto predicate in an attestation and compare two dates in it.
- That `skipFallback` behaves on Talos as described here.
- That Docker Hub's pull limits allow the intake to sync candidates; if not, regsync's `ratelimit` and a Docker
  Hub account.

## Not in this plan

Workload identity for the writers (Salmon, zot's `bearer.oidc`, which needs zot 2.1.22). Signing our own builds,
which `@dataverket/signed-images` covers. A KMS for the mirror key. An edge for any site other than the ToR.
