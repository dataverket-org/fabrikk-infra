# Backups

Status: **hov1 up since 2026-09-20; the Postgres writers are declared in `apps/` and arrive with their PR.** Design and
sequencing: `docs/plans/2026-09-storage-building-blocks.md`, step 1. The gateway's lifecycle is `docker compose` from
the site directory; accounts and certificates are the scripts in `versitygw/bin`. A swamp model for the lifecycle is
pending: the registry's `@smith/docker-compose` fails on current swamp and declares neither a repository to report to nor a license to fork under, so a `@dataverket` one is the
follow-up.

Every backup of dataverket-prod lands outside the provider, on the hov1 site, in one bucket per writer. This page is
the map: what is copied, by what, to where, how far back, and what fires when it stops. How the target runs is in
`versitygw/README.md`; what makes hov1 hov1 is in `hov1/README.md`.

## Directory map

| Path | Contents | Go here when |
|---|---|---|
| `README.md` | Sources, targets, retention, alerts | You need to know what is backed up or where a restore starts |
| `versitygw/` | The S3 gateway stack (versitygw behind a private CA made with `step`) and its scripts; names no site | You operate the gateway: bring-up, accounts, certificates, recovery |
| `hov1/` | The first site: `.env` (never committed), `certs/ca.crt` (committed), site facts | You touch the hov1 host or its address |

## Sources and targets

| Source | Namespace | Tool | Bucket and account on hov1 | Schedule and retention | Secrets read by the writer |
|---|---|---|---|---|---|
| Forgejo's Postgres, `Cluster forgejo-postgres` | `forgejo` | CNPG Barman Cloud plugin | `cnpg-forgejo` | Daily base backup, continuous WAL, 14 days, point-in-time recovery | `s3-cnpg-forgejo`, `hov1-s3` |
| Zitadel's Postgres, `Cluster zitadel-db` | `zitadel` | CNPG Barman Cloud plugin | `cnpg-zitadel` | Daily base backup, continuous WAL, 14 days, point-in-time recovery | `s3-cnpg-zitadel`, `hov1-s3` |
| Forgejo's repositories, PVC `gitea-shared-storage` | `forgejo` | restic CronJob, pod-affine to the forgejo pod | `restic-forgejo` | Nightly; 30 daily, 6 monthly | `s3-restic-forgejo`, `hov1-s3`, the restic password |
| Forgejo's LFS, attachments, packages, once on the in-cluster versitygw | `forgejo` | The same restic CronJob, as a directory tree | `restic-forgejo` | With the repositories | As above |
| etcd of the three control planes | `kube-system` | Omni | Omni's backup store | Omni's schedule, decision 001 | Omni's |

Account names equal bucket names. Each account owns its bucket and sees nothing else.

### Not backed up, on purpose

| What | Why |
|---|---|
| The in-cluster versitygw volume (zot blobs) | Mirrors re-copy, artifacts come from git, product images rebuild |
| Runner caches | Disposable |
| The hov1 gateway itself | It is the backup; `versitygw/README.md` rebuilds it, the next base backup refills it |

### Needed for any restore

The Zitadel masterkey, Forgejo's `SECRET_KEY` and `LFS_JWT_SECRET`, and the restic password. They live in
`*.enc.yaml` before the first backup runs; a backup without them restores nothing usable.

## Targets

| Target | Location | Endpoint | Trust | Second copy |
|---|---|---|---|---|
| hov1 | The hov1 site, stack `versitygw/`, instance `hov1/` | `https://213.128.185.82:443`, path-style, region `us-east-1` | The site's private CA root (three years), in Secret `hov1-s3` of each writing namespace | None yet. Nexthop Object Storage as a second `ObjectStore` if the site proves unreachable too often |
| Omni | Sidero's hosted Omni | Omni's | Omni | Omni's |

### Retention and protection

- Retention is each writer's job: Barman's `retentionPolicy`, restic's `forget`.
- Bucket versioning is **off**. versitygw 1.8 has no lifecycle rules, so versioning would keep every deleted object
  forever, and a bucket's owner can suspend it anyway.
- Protection against a leaked writer key is the second copy, or object lock the day it is wanted. Neither exists yet.

## Alerts

| Alert | Threshold | Meaning | First action |
|---|---|---|---|
| CNPG WAL archiving failing | Over 2 hours | hov1 unreachable. Postgres keeps every unarchived segment; at the default 5-minute `archive_timeout` that is about 190 MiB an hour, so the 4.5 GiB of headroom lasts about a day, some 20 hours after this fires | Reach the site: `versitygw/README.md`, failure modes |
| CNPG last successful base backup | Older than 36 hours | The `ScheduledBackup` did not complete | `kubectl cnpg status`, then the plugin's Backup objects |
| Certificate at `213.128.185.82:443` | Expires within 30 days | The three-year certificate or root is running out; nothing at the site renews it | `versitygw/README.md`, runbook "Reissue the certificate" |
| restic snapshot | Older than 48 hours | The CronJob failed or cannot reach hov1 | The CronJob's last Job logs |

## Restore

The quarterly, timed restore drill is the only proof any of this works. Procedure and targets: the plan, step 1
(`bootstrap.recovery` into a scratch namespace for each cluster, restic beside it, `psql` shows the application
tables). Record the timings; the base backup's transfer time over the site's uplink is the number to know before an
outage.
