# Plan: backup of the osl1 S3 gateway

Written 2026-10-04 as the backup step of the osl1 S3 plan, which is otherwise done: the gateway, its name, accounts
and model are decision 029 and `artifacts/versitygw/README.md`. Skipped on 2026-10-15, to be taken up before the
gateway holds data that exists nowhere else and matters more than Zulip's uploads do. **Due since 2026-10-28**: the
swamp datastore of this repository is on the gateway (decision 030), with a local cache on each operator host as
its only other copy. Until this runs the volume has Cinder's three copies and nothing else (decision 018), as
`docs/storage.md` and `backup/README.md` say.

## What it backs up

The gateway's one claim, `data-versitygw-0`, `csi-cinder-standard-retain`, 20 GiB: `/data` (buckets as directories,
objects as files), `/versioning` (non-current versions) and `/iam` (`users.json`, every account's secret in clear).
On 2026-10-15 it holds the account `zulip` and the buckets `zulip-uploads` and `zulip-avatars`; since 2026-10-28
also the account `swamp-fabrikk-infra` and its bucket, the swamp datastore (decision 030).

## Shape

| Piece | Choice |
|---|---|
| Tool | kopia, as `backup/README.md` already plans for Forgejo's repositories: content-addressed, encrypted before it leaves, deduplicated, with retention in the repository |
| Where it runs | A CronJob in `versitygw`, pod-affine to `versitygw-0`, mounting the same claim read-only; `ReadWriteOnce` lets two pods on one node share it |
| Target | A kopia repository in bucket `kopia-osl1` on the hov1 site, its account made by a person at the site with `backup/versitygw/bin/user`, the Secret through `sops --encrypt` into `artifacts/versitygw/s3-kopia-osl1.enc.yaml` with `hov1-s3` beside it |
| Schedule | Nightly; 30 daily and 6 monthly snapshots, kopia's own policy |
| Key | The kopia repository password, a cluster file, and a person's copy in `vaults/operator/osl1/` for a restore without the cluster (decision 016) |
| Delivery | In the versitygw artifact, as everything of the gateway's is |
| Watched | The alert row `backup/README.md` already has: kopia snapshot older than 48 hours |

## The question that decides the restore

versitygw keeps object metadata, bucket ownership, policies, ACLs and lock state in extended attributes, on the
bucket directories and the objects (`artifacts/versitygw/README.md`, "What the gateway does").

- If kopia carries xattrs, a restore is the tree, written back with the gateway stopped, and nothing else.
- If it does not, a restore is the tree, then `artifacts/versitygw/user.sh` with `--rotate` for every account to
  re-establish owners, each bucket's policy put again from git (Zulip's in `artifacts/zulip/s3proof`), and the
  gateway's default-ETag setting for objects whose ETag is gone. `/iam/users.json` is in the tree either way.

Settled on a scratch claim before anything is relied on: a throwaway gateway with an object carrying a
`Content-Type`, a bucket with a policy, a snapshot, a restore into a fresh claim, and the object's headers and the
policy read back over S3.

## Steps

1. The scratch test above; its result written here, and into `backup/versitygw/README.md`, since it holds for any
   versitygw.
2. `kopia-osl1` and its account on hov1, by a person at the site; `hov1-s3 check` afterwards.
3. The CronJob, the Secrets and the repository's first snapshot, in the artifact; a restore of one bucket into a
   scratch namespace, read back over S3 with `artifacts/zulip/s3proof`.
4. `docs/storage.md` and `backup/README.md` move from "none yet" to the schedule, with the restore runbook; this plan
   is removed.

## Not in this plan

- **Object lock.** Available on the gateway and used by no bucket (decision 029). Proving it, a test bucket with a
  one-hour `GOVERNANCE` retention refused a plain delete and released by root, across one forced reschedule of the
  pod, waits for a writer that wants lock, with `docs/plans/2026-10-versitygw-lifecycle.md` before it.
- Zitadel as the gateway's identity provider: `docs/plans/2026-10-s3-zitadel.md`.
- Moving the backup target off hov1, or a second copy at the provider's object storage (decision 020 says how).
