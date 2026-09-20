# Backups

What is copied, from where, by what, to where, and how far back it reaches. The plan behind it is
`docs/plans/2026-09-storage-building-blocks.md`, step 1; nothing here is applied yet. One rule shapes the table: the
copy that matters lives outside the provider, on the hov1 site, and each writer owns one bucket there and nothing else.

## Sources and targets

| Source | In the cluster | Tool | Target bucket, account | Schedule, retention | Credentials |
|---|---|---|---|---|---|
| Forgejo's Postgres (`Cluster forgejo-postgres`) | `forgejo` | CNPG Barman Cloud plugin | `cnpg-forgejo` on hov1, account `cnpg-forgejo` | daily base backup, continuous WAL, 14 days, point-in-time recovery | `forgejo/s3-cnpg-forgejo`, `forgejo/hov1-s3` |
| Zitadel's Postgres (`Cluster zitadel-db`) | `zitadel` | CNPG Barman Cloud plugin | `cnpg-zitadel` on hov1, account `cnpg-zitadel` | daily base backup, continuous WAL, 14 days, point-in-time recovery | `zitadel/s3-cnpg-zitadel`, `zitadel/hov1-s3` |
| Forgejo's repositories (PVC `gitea-shared-storage`) | `forgejo` | restic CronJob, pod-affine to the forgejo pod | `restic-forgejo` on hov1, account `restic-forgejo` | nightly, 30 daily and 6 monthly | `forgejo/s3-restic-forgejo`, `forgejo/hov1-s3`, the restic password |
| Forgejo's LFS, attachments and packages, once on the in-cluster versitygw | `forgejo` | the same restic CronJob, as a directory tree | `restic-forgejo` on hov1 | with the repositories | as above |
| etcd of the three control planes | `kube-system` | Omni | Omni's own backup store | Omni's schedule (decision 001) | Omni's |

Not copied anywhere, on purpose: the in-cluster versitygw volume (zot blobs: mirrors re-copy, artifacts come from
git, product images rebuild), the runner caches, and the hov1 gateway itself (it is the backup; the runbook in
`versitygw/README.md` rebuilds it and the next base backup refills it). Restores need the application secrets too,
which is why the Zitadel masterkey, Forgejo's `SECRET_KEY` and `LFS_JWT_SECRET`, and the restic password are in
`*.enc.yaml` before the first backup runs.

## Targets

| Target | Where | Reached as | Trust | Second copy |
|---|---|---|---|---|
| hov1 | the hov1 site, `hov1/`, the stack of `versitygw/` | `https://213.128.185.82:443`, path-style, region `us-east-1` | step-ca's root, in the `hov1-s3` Secret of each writing namespace | none yet; Nexthop Object Storage by the same mechanism, a second `ObjectStore`, if the site proves unreachable too often |
| Omni | Sidero's hosted Omni | by Omni | Omni | Omni's |

Bucket versioning on hov1 is off (versitygw 1.8 has no lifecycle rules, and a bucket's owner could suspend it anyway),
so retention is each writer's job: Barman's `retentionPolicy`, restic's `forget`. What protects an archive from a bad
writer key is the second copy, or object lock the day it is wanted.

## Alarms that watch this

WAL archiving failing for over two hours (the site unreachable; about twenty hours of headroom follow), the last
successful base backup older than 36 hours, the certificate at the site expiring within seven days, a restic snapshot
older than 48 hours. The restore drill, quarterly and timed, is the only proof any of it works.

## Layout

| Path | What |
|---|---|
| `versitygw/` | The stack: versitygw with the posix backend, step-ca, a renewer, and the scripts; names no site |
| `<site>/` | One instance: `compose.yaml` including the stack, `.env` (never committed), `certs/ca.crt` (committed) |
| `hov1/` | The first site, the target above |
