# Backups

Status: **live since 2026-09-20 21:10 UTC: both Postgres clusters archive WAL to hov1 continuously; daily base backups at 03:00 and 03:30 UTC; first restore test passed 2026-09-21.** The
decision is 020; what the backups protect is `docs/storage.md`. The gateway's lifecycle is `docker compose` from
the site directory; accounts and certificates are the scripts in `versitygw/bin`. A swamp model for the lifecycle is
pending: the registry's `@smith/docker-compose` fails on current swamp and declares neither a repository to report to nor a license to fork under, so a `@dataverket` one is the
follow-up.

What the gateway holds is read through swamp: the model `hov1-s3` (`@dataverket/versitygw/gateway`, read-only) has
`health`, `accounts`, `buckets`, `bucketSettings`, `inventory` and `check`; `check` finds a bucket not owned by the
account of its own name, an account owning nothing, an `admin` role on a writer, versioning without object lock, lock
without versioning, a `COMPLIANCE` default retention, or a policy granting anyone. Every admin call signs with the
root key pair, supplied for one run from `vaults/operator/hov1/root.enc.json` (`vaults/operator/README.md`); without
it `swamp model validate hov1-s3 --label policy` still validates the definition. No account secret and no root key is
ever recorded.

Every backup of dataverket-prod lands outside the provider, on the hov1 site, in one bucket per writer. This page is
the map: what is copied, by what, to where, how far back, and what fires when it stops. How the target runs is in
`versitygw/README.md`; what makes hov1 hov1 is in `hov1/README.md`.

## Directory map

| Path | Contents | Go here when |
|---|---|---|
| `README.md` | Sources, targets, retention, alerts, restore-test log | You need to know what is backed up or where a restore starts |
| `cnpg-backups.md` | The kubectl-only operator's guide to the Postgres backups: health check, logs, values, changes, restore, failure signatures | You are on call for the databases |
| `restore-test/` | The restore-test Cluster manifests, one per production cluster | You run the quarterly restore test |
| `versitygw/` | The S3 gateway stack (versitygw behind a private CA made with `step`) and its scripts; names no site | You operate the gateway: bring-up, accounts, certificates, recovery |
| `hov1/` | The first site: `.env` (never committed), `certs/ca.crt` (committed), site facts | You touch the hov1 host or its address |

## Sources and targets

| Source | Namespace | Tool | Bucket and account on hov1 | Schedule and retention | Secrets read by the writer |
|---|---|---|---|---|---|
| Forgejo's Postgres, `Cluster forgejo-postgres` | `forgejo` | CNPG Barman Cloud plugin | `cnpg-forgejo` | Daily base backup, continuous WAL, 14 days, point-in-time recovery | `s3-cnpg-forgejo`, `hov1-s3` |
| Zitadel's Postgres, `Cluster zitadel-db` | `zitadel` | CNPG Barman Cloud plugin | `cnpg-zitadel` | Daily base backup, continuous WAL, 14 days, point-in-time recovery | `s3-cnpg-zitadel`, `hov1-s3` |
| Forgejo's repositories, PVC `gitea-shared-storage` | `forgejo` | The push mirror to GitHub for now; later a kopia CronJob, pod-affine to the forgejo pod | GitHub; later `kopia-forgejo` | On push; later nightly, 30 daily, 6 monthly | The mirror's token; later `s3-kopia-forgejo`, `hov1-s3`, the kopia password |
| Forgejo's LFS, attachments, packages, once on the in-cluster versitygw | `forgejo` | The kopia CronJob, as a directory tree | `kopia-forgejo` | With the repositories | As above |
| etcd of the three control planes | `kube-system` | Nothing. Omni's etcd backup store is not configured (checked 2026-10-04: `EtcdBackupStoreStatus` reads "not initialized", no backup exists) | None | None | None |

Account names equal bucket names. Each account owns its bucket and sees nothing else.

### Not backed up, on purpose

| What | Why |
|---|---|
| The in-cluster versitygw volume (zot blobs) | Mirrors re-copy, artifacts come from git, product images rebuild |
| Runner caches | Disposable |
| The hov1 gateway itself | It is the backup; `versitygw/README.md` rebuilds it, the next base backup refills it |

### Needed for any restore

The Zitadel masterkey, in `apps/zitadel/zitadel-masterkey.enc.yaml`, and Forgejo's `SECRET_KEY`,
`INTERNAL_TOKEN`, `JWT_SECRET` and `LFS_JWT_SECRET`, in `apps/forgejo/forgejo-security.enc.yaml` and pinned into
the release: Forgejo generated them into `app.ini` on `gitea-shared-storage`, which the mirror does not copy. A
backup without them restores nothing usable. Both Secrets carry `kustomize.toolkit.fluxcd.io/prune: disabled`, so
dropping a file from a kustomization never deletes the key.

## Targets

| Target | Location | Endpoint | Trust | Second copy |
|---|---|---|---|---|
| hov1 | The hov1 site, stack `versitygw/`, instance `hov1/` | `https://213.128.185.82:443`, path-style, region `us-east-1` | The site's private CA root (three years), in Secret `hov1-s3` of each writing namespace | None yet. Nexthop Object Storage as a second `ObjectStore` if the site proves unreachable too often |
| Omni | Sidero's hosted Omni; not configured, so etcd has no backup. `talosctl etcd snapshot` to the hov1 site is in `docs/plans/2026-10-talosctl-over-omni.md` | none | none | none |

### Retention and protection

- Retention is each writer's job: Barman's `retentionPolicy`, and kopia's policy when it comes.
- Bucket versioning is **off**. versitygw 1.8 has no lifecycle rules, so versioning would keep every deleted object
  forever, and a bucket's owner can suspend it anyway.
- Protection against a leaked writer key is the second copy, or object lock the day it is wanted. Neither exists yet.

## Alerts

| Alert | Threshold | Meaning | First action |
|---|---|---|---|
| CNPG WAL archiving failing | Over 2 hours | hov1 unreachable. Postgres keeps every unarchived segment; at the default 5-minute `archive_timeout` that is about 190 MiB an hour, so the smallest headroom, about 9 GiB on Forgejo's volume and 9.5 GiB on Zitadel's partition, lasts about two days | Reach the site: `versitygw/README.md`, failure modes |
| CNPG last successful base backup | Older than 36 hours | The `ScheduledBackup` did not complete | `kubectl cnpg status`, then the plugin's Backup objects |
| Certificate at `213.128.185.82:443` | Expires within 30 days | The three-year certificate or root is running out; nothing at the site renews it | `versitygw/README.md`, runbook "Reissue the certificate" |
| kopia snapshot, once it exists | Older than 48 hours | The CronJob failed or cannot reach hov1 | The CronJob's last Job logs |

## Restore

The quarterly, timed restore test is the only proof any of it works. Procedure: `cnpg-backups.md`, "Restore";
manifests: `restore-test/`. A scratch one-instance cluster beside each production cluster, recovered from hov1 to the end
of WAL, checked with `psql` against production, deleted. kopia joins the restore test when the repositories get a copy of their own.

### Restore-test log

| Date | Archive state | Apply to ready | Check | Result |
|---|---|---|---|---|
| 2026-09-21 06:29 UTC | 2 base backups and 113 WAL segments per cluster on hov1, newest base 03:00 and 03:30 UTC | 1 min 49 s, both clusters in parallel | forgejo: 128 public tables, 7 repositories, 4 users, newest action 2026-09-20 21:16 UTC; zitadel: 143 tables in 9 schemas, 1687 events, newest 2026-09-20 15:00 UTC. All equal to production at the same moment | Passed. Torn down 06:33 UTC, PVCs gone in 9 s; production untouched; the restore test wrote nothing to hov1 |
