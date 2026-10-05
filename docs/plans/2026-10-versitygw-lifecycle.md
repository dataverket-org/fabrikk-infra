# Plan: a sweeper for versioned buckets on versitygw

Written 2026-10-05. Nothing is built. A small Go program, not a swamp model: it deletes what lifecycle rules would,
on a gateway that has none, so that object lock can be turned on for the backup buckets without the disk growing
without end.

## What was found

- versitygw has no lifecycle rules by design: `PutBucketLifecycleConfiguration` is "recognized but not implemented"
  and answers `NotImplemented` (issue #1443, 2025). Nothing in its issues, discussions or the web is a sweeper;
  nobody has published one. Versioning itself was added on request in 2024 (discussion #602) as a shadow
  namespace beside the gateway root.
- On the posix backend a non-current version is a file in `VERSIONS_DIR/<bucket>/<sha256 prefix dirs>/<version id>`,
  and a delete marker is an xattr on the primary file. The gateway's own `ListObjectVersions` and `DeleteObject`
  with a version id are the only safe way to remove them: a direct `rm` bypasses the lock checks and the metadata,
  and issue #2200, open, shows the version list is already sensitive to concurrent writes.
- Object lock refuses a delete of a version whose retention has not expired, whoever asks, with `AccessDenied`;
  root may bypass `GOVERNANCE` only with an explicit header. A sweeper that never sends that header can only remove
  what the lock has released.
- radosgw does not need this; its lifecycle rules do it natively.

## The program

`vgw-sweep`, one Go binary on `aws-sdk-go-v2`, its own repository on the forge, image built by the forge's CI like
`nordhost-integrator`.

| | |
|---|---|
| Input | endpoint, region, a key pair from the environment, `--bucket` repeated or every bucket the key lists, `--keep 14d`, `--apply` |
| Does | For each versioned bucket: `ListObjectVersions`, every page; deletes by version id every non-current version whose `LastModified` is older than `--keep`, and every delete marker that is the latest and only version left; counts a `403` as `locked`, never bypasses |
| Default | Dry run: prints what it would delete, per bucket, and exits 0. `--apply` deletes |
| Output | One JSON summary line per bucket: listed, deleted, locked, kept, errors; exit 1 on any error |
| Runs | A systemd timer on the site host, daily, as the root key pair from the site's `.env`; a CronJob in a cluster |
| Never | Deletes a current version, sends a bypass header, or touches a bucket without versioning |

`--keep` is longer than the writer's retention: Barman keeps 14 days and deletes its own objects past that, which on
a versioned bucket leaves non-current versions and delete markers; the sweeper takes those a day later. The lock's
default retention is at most `--keep`, so by the time the sweeper looks, the lock has released what Barman deleted.

## Steps

1. **Repository and skeleton**: `dataverket/vgw-sweep` on the forge, `main.go`, the summary type, the dry run
   printing what a listing holds, CI building the image.
2. **The sweep**, with unit tests against a fake S3 client: non-current older than `--keep` deleted, newer kept,
   a sole delete marker deleted, a current version never, a `403` counted as locked, pagination followed, a
   bucket without versioning skipped, dry run deletes nothing.
3. **Live test** against the extension's throwaway gateways (`swamp-extensions/versitygw/smoke/gateway.sh`): a
   locked bucket with a short retention, versions older and newer than `--keep`, a delete marker; the summary
   matches, and `osl1-s3`-style `inventory` shows the versions gone.
4. **hov1, dry run**: the timer on the site host for a week, summaries read.
5. **hov1, lock**: on `cnpg-forgejo` and `cnpg-zitadel` as root, versioning on, then object lock with
   `GOVERNANCE` and a 14-day default retention; `VERSIONS_DIR` sized for 15 days of WAL and base backups, the
   volume alert in `docs/storage.md` covering it; `--apply` on the timer; `hov1-s3 check` clean under the default
   rules; a restore test. Decision 020's audit records lock as done.
6. **osl1** the same way when it has a bucket that wants lock; kopia, when it comes, manages lock itself.

## Not in this plan

- A swamp model for the sweeper. It is a program with one job on one host; what swamp reads is the gateway, through
  `inventory` and `check`, and a `versions` count per bucket in `bucketSettings` is the follow-up that makes a
  stopped sweeper visible.
- `COMPLIANCE` retention: the hatch stays open, behind root's key in `vaults/operator/`.
