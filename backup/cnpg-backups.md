# CNPG backups: the operator's guide

How to see, judge and change the PostgreSQL backups of dataverket-prod with `kubectl` alone. Two clusters,
`forgejo/forgejo-postgres` and `zitadel/zitadel-db`, back up to the hov1 site through the CloudNativePG Barman Cloud
plugin: WAL continuously, a base backup daily, 14 days of both. What is backed up and where is `README.md`; this page
is the console.

All commands assume the context: `kubectl config use-context dataverket-prod-admin`, or `--context` on each.

## Contents

- [The objects](#the-objects)
- [Is it healthy? The five-minute check](#is-it-healthy-the-five-minute-check)
- [Reading the details](#reading-the-details)
- [Logs](#logs)
- [Values that matter and where they live](#values-that-matter-and-where-they-live)
- [Changing things](#changing-things)
- [Restore](#restore)
- [Failure signatures](#failure-signatures)

## The objects

| Kind (short name) | Where | What it is |
|---|---|---|
| `Cluster` (`cluster`) | `apps/<ns>/postgres.yaml` | The Postgres cluster. Its `spec.plugins` entry turns archiving on and names the ObjectStore and the `serverName`, the folder inside the bucket |
| `ObjectStore` (`objectstore`, group `barmancloud.cnpg.io`) | `apps/<ns>/backup.yaml` | Where backups go: bucket, endpoint, CA, credentials, compression, retention. Its **status** carries the recovery window |
| `ScheduledBackup` (`scheduledbackup`) | `apps/<ns>/backup.yaml` | The cron. Creates a `Backup` per tick |
| `Backup` (`backup`) | Created by the schedule, or by hand | One base backup: phase, WAL range, error |
| Secret `hov1-s3` | `apps/<ns>/hov1-s3.yaml` | CA root, endpoint, region of the site; plain |
| Secret `s3-cnpg-<bucket>` | `apps/<ns>/s3-cnpg-<bucket>.enc.yaml` | The writer's key pair; sops-encrypted in git, Flux decrypts |
| Deployment `barman-cloud` | `cnpg-system`, `infrastructure/cnpg-barman-plugin/` | The plugin. Talks to the operator, injects a sidecar (`plugin-barman-cloud`, a native init container) into every instance pod |

Everything is Flux-managed from git. A change made with `kubectl edit` is reverted within ten minutes; change git.

## Is it healthy? The five-minute check

```sh
# 1. Archiving: must be ContinuousArchivingSuccess on both
kubectl get cluster -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,READY:.status.readyInstances,ARCHIVING:.status.conditions[?(@.type=="ContinuousArchiving")].reason'

# 2. Recovery window: first point and last base backup, per cluster (plugin backups report here, not on the Cluster)
kubectl get objectstore -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}: {.status.serverRecoveryWindow}{"\n"}{end}'

# 3. Last base backups: the newest per cluster should be today, phase completed
kubectl get backup -A --sort-by=.status.startedAt -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,PHASE:.status.phase,STARTED:.status.startedAt,STOPPED:.status.stoppedAt,ERR:.status.error' | tail -6

# 4. Next scheduled run
kubectl get scheduledbackup -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,SCHEDULE:.spec.schedule,LAST:.status.lastScheduleTime,NEXT:.status.nextScheduleTime'
```

Healthy reads: archiving `ContinuousArchivingSuccess` on both; `lastSuccessfulBackupTime` within 24 hours; newest
`Backup` completed; `NEXT` tomorrow at 03:00 (forgejo) and 03:30 (zitadel) UTC. On the Cluster itself,
`status.firstRecoverabilityPoint` and `status.lastSuccessfulBackup` stay empty with the plugin; read the ObjectStore.

## Reading the details

```sh
# Which instance is primary, which node, and that every pod carries the sidecar
kubectl get pods -n forgejo -l cnpg.io/cluster=forgejo-postgres \
  -o custom-columns='NAME:.metadata.name,ROLE:.metadata.labels.cnpg\.io/instanceRole,INIT:.spec.initContainers[*].name,NODE:.spec.nodeName'

# The archiver from inside Postgres: archived_count grows, failed_count does not, last_archived_time is recent
kubectl exec -n forgejo forgejo-postgres-1 -c postgres -- psql -U postgres -tAc \
  'select archived_count, last_archived_wal, last_archived_time, failed_count, last_failed_time from pg_stat_archiver'

# One Backup in full (WAL range, timings, error)
kubectl get backup -n forgejo forgejo-postgres-first -o yaml | sed -n '/^status:/,$p'

# Events, newest last: rollouts, switchovers, backup start/complete/fail
kubectl get events -n forgejo --sort-by=.lastTimestamp | grep -i -E 'backup|archiv|switchover|failover' | tail -20
```

The primary carries the archiver; on a replica `pg_stat_archiver` is meaningless. Find it with the pod listing
above or `kubectl get cluster -n forgejo forgejo-postgres -o jsonpath='{.status.currentPrimary}'`.

## Logs

```sh
# The plugin sidecar in an instance pod: uploads, retention, errors talking to hov1
kubectl logs -n forgejo forgejo-postgres-1 -c plugin-barman-cloud --since=1h

# Postgres itself, archive_command results
kubectl logs -n forgejo forgejo-postgres-1 -c postgres --since=1h | grep -i -E 'archiv|wal'

# The plugin controller
kubectl logs -n cnpg-system deploy/barman-cloud --since=1h

# The operator, for reconciliation and rollout decisions
kubectl logs -n cnpg-system deploy/cnpg-controller-manager --since=1h | grep -i -E 'forgejo-postgres|zitadel-db'
```

Logs are JSON lines; pipe through `jq -r '.msg'` or `jq -c 'select(.level=="error")'` when reading more than a page.

## Values that matter and where they live

| Value | Now | Where | Effect of a change |
|---|---|---|---|
| Base backup schedule | `0 0 3 * * *` (forgejo), `0 30 3 * * *` (zitadel); six fields, seconds first, UTC | `ScheduledBackup.spec.schedule` | Next tick moves; running backups unaffected |
| Retention | `14d` | `ObjectStore.spec.retentionPolicy` (`^[1-9][0-9]*[dwm]$`) | Applied after each base backup: older base backups and the WAL before them are deleted from hov1 |
| Compression | gzip for WAL and data | `ObjectStore.spec.configuration.wal.compression`, `.data.compression` | New uploads only |
| Endpoint, CA, region | `https://213.128.185.82:443`, Secret `hov1-s3` | `ObjectStore.spec.configuration.endpointURL`, `endpointCA`, `s3Credentials.region` | Every upload; a wrong value stops archiving within minutes |
| Credentials | Secret `s3-cnpg-<bucket>` | `ObjectStore.spec.configuration.s3Credentials` | Rotation: new sops file in git; the sidecar picks it up on the next call |
| Archive folder | `serverName` = cluster name | `Cluster.spec.plugins[].parameters.serverName` | **Never change on a live cluster**: the archive would restart empty under a new name. A restored cluster that archives must use a new one |
| Archiving on | `isWALArchiver: true` | `Cluster.spec.plugins[]` | Removing it stops WAL archiving; base backups then have no WAL to be consistent with |
| First run on apply | `immediate: true` | `ScheduledBackup.spec.immediate` | Only at creation; failed when applied mid-rollout on 2026-09-20, hence the one-off `Backup` objects |
| Postgres `archive_timeout` | CNPG default 5 min | `Cluster.spec.postgresql.parameters` | A 16 MiB segment at least every 5 min on a barely busy primary: about 190 MiB/h that must reach hov1 |

## Changing things

Through git, then let Flux apply (`flux reconcile kustomization apps --with-source`, or wait ten minutes).

**Take a base backup now** (the only thing done with `kubectl` directly; a completed Backup is inert):

```sh
kubectl apply -f - <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: forgejo-postgres-manual-$(date -u +%Y%m%d%H%M)
  namespace: forgejo
spec:
  cluster:
    name: forgejo-postgres
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
EOF
kubectl get backup -n forgejo -w
```

**Change the schedule or retention**: edit `apps/<ns>/backup.yaml`, commit, reconcile. Check with the five-minute
check. **Pause scheduled backups** (a migration, a maintenance window): set `spec.suspend: true` on the
ScheduledBackup in git; WAL archiving continues. **Stop archiving entirely**: remove the `plugins` entry from the
Cluster; expect a rolling restart, and know the archive stops being restorable past that point.

**Rotate the writer key**: on the site, `../versitygw/bin/user cnpg-forgejo forgejo --rotate` piped into the same
sops file (`versitygw/README.md`, "Rotate a writer key"), commit at once, reconcile. Between mint and apply,
archiving fails and retries; `pg_stat_archiver.failed_count` grows and stops.

**Rolling restarts**: any change to the plugin stanza or the sidecar image restarts every instance one by one and
switches the primary once. Do it in a quiet minute and watch `kubectl get pods -n <ns> -w`.

## Restore

The archive is only proven by restoring from it. Two forms:

**Restore test** (quarterly, timed): a scratch cluster beside production, recovered to the end of WAL, checked, deleted.
The manifests are `backup/restore-test/*.yaml`: one instance, same Postgres image, `bootstrap.recovery.source` pointing
at an `externalClusters` entry with `plugin.parameters.barmanObjectName: hov1` and `serverName` of the production
cluster, and **no `plugins` stanza**, so it archives nothing.

```sh
date -u; kubectl apply -f backup/restore-test/
kubectl get cluster -n forgejo forgejo-postgres-restore-test -w          # until readyInstances 1, "Cluster in healthy state"
kubectl exec -n forgejo forgejo-postgres-restore-test-1 -c postgres -- psql -U postgres -d forgejo -tAc \
  "select count(*) from pg_tables where schemaname='public'"      # application tables present
kubectl delete -f backup/restore-test/                                    # PVCs go with the cluster
```

Record start, ready and delete times in `README.md`. The restore test recovers to the latest archived WAL; for a point in
time add `recoveryTarget.targetTime` under `bootstrap.recovery`.

**Real recovery** (the production cluster is lost): same recovery stanza on a Cluster with the production **name**
(so the `-rw` Service and `-app` Secret keep their names), three instances, the production storage, and a
`plugins` stanza with a **new `serverName`** so its archive does not overwrite the one it came from.
`enableSuperuserAccess` and other spec fields as in `apps/<ns>/postgres.yaml`. The application's own secrets
(Zitadel masterkey, Forgejo keys) are separate; without them the restored data is unusable.

## Failure signatures

| You see | It means | Do |
|---|---|---|
| `ContinuousArchiving` False, `failed_count` climbing, sidecar log `connection refused` / `i/o timeout` to 213.128.185.82 | hov1 unreachable | Site: `docker compose ps`, uplink, port forward. Headroom about a day of WAL, then the partition fills |
| Sidecar log `x509: certificate signed by unknown authority` | `hov1-s3` CA does not match the site's certificate | Site: `bin/cert` history; regenerate `hov1-s3` with `bin/site-secret` and commit |
| `SignatureDoesNotMatch` / `InvalidAccessKeyId` | Writer key wrong or rotated without the commit | Check the sops file matches the account on the site |
| `IncorrectRegion` | Client region differs from the gateway's | `REGION` in `hov1-s3` must equal the site's `.env` |
| Backup `failed`, error `requested plugin is not available` | Backup fired before the plugin/sidecar existed | Take a manual backup; the next scheduled one is fine |
| Backup stuck `running` | Sidecar upload hanging, or the primary switched mid-backup | Sidecar log; a new Backup supersedes it |
| `NoSuchBucket` | Bucket gone on the site (host rebuilt) | Site: `bin/user <bucket> <ns>` recreates and re-owns it; if the key changed, commit the new Secret |
| Recovery pod loops with `WAL segment not found` | `serverName` wrong, or archive incomplete | Check `serverName` against `base/` on the site; check the WAL range of the newest Backup |
