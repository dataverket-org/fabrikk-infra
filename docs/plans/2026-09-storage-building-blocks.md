# Plan: storage building blocks

Written 2026-09-19 from live inventory (swamp models `dataverket-prod-pvcs`, `openstack-*`, `omni` and
`dataverket-prod-talos`) and the Nexthop price list of the same day. Third revision: the databases move to the workers'
own disks, replicated by CNPG, now that the root disks are measured. Reviewed adversarially. Nothing is applied.
Decision 007 is the mechanism under the databases.

## Building blocks

1. **One redundancy layer per kind of data.** Blob-shaped and single-writer data (registry, repositories, runner
   caches) sits on Cinder, which keeps three copies. Databases replicate themselves: CNPG runs three instances, one
   per worker, on partitions carved from each
   worker's root disk, with one synchronous replica so a failover loses no acknowledged commit. Those disks are
   paid for with the flavor and need no Cinder attach to fail over. Nothing replicates on top of Cinder.
2. **EPHEMERAL is a fixed 16 GiB on the workers**, 32 GiB at most anywhere else. Talos sizes a volume only when
   it first provisions it, and by default EPHEMERAL takes the whole disk; a cap turns the kubelet's percentage
   thresholds into a budget. `maxSize` accepts a percentage, but a share of the disk is the wrong unit across
   30 GiB and 1 TB disks.
3. **Object storage inside the cluster is versitygw on Cinder**: one S3 endpoint, POSIX backend, Standard tier;
   registry blobs first, later Forgejo LFS and packages.
4. **Backups leave Cinder** for Nexthop Object Storage; versitygw shares Cinder's blast radius.
5. **Tier by shape.** SSD for working trees and caches, Standard for blobs.

## Measured

`swamp workflow run fleet-volumes` (omni mints a talosconfig with the node list, `dataverket-prod-talos volumes`
reads the machines through Omni's proxy); the same talosctl model gives a lab cluster the same view. Today:

| Node | System disk | Partitions | EPHEMERAL | Used | Unallocated |
|---|---|---|---|---|---|
| ctrl-1..3 | 25 GiB | STATE 100, BIOS 1, BOOT 2000, META 1 MiB | 21,495 MiB | 1.1 GiB, 5% | 2,003 MiB |
| wrkr-1, wrkr-2 | 30 GiB | same | 26,615 MiB | 5.5 GiB, 21% | 2,003 MiB |
| wrkr-3 | 30 GiB | same | 26,615 MiB | 8.4 GiB, 33% | 2,003 MiB |

Usage is almost entirely container images; logs are under 105 MiB. At 16 GiB the busiest worker sits at 52
percent, with image collection from 80. Every disk already has 2 GiB unallocated that EPHEMERAL never took.

**The worker disk after the change**, 30 GiB: 2,102 MiB of Talos partitions, EPHEMERAL 16,384 MiB,
`u-pg-zitadel` 3,072 MiB, `u-pg-forgejo` at least 8,192 MiB grown into the rest, about 9,160 MiB. Both databases
hold about 620 MB today. The bigger volume comes last because only the last partition can grow.

## Open question: are the root disks local?

Nexthop documents three copies for volumes and nothing for flavor disks. Ask whether flavor root disks are
hypervisor-local or replicated, and whether instances live-migrate. The plan no longer depends on the answer: the
disk is paid for either way, and CNPG replicates for failover, not durability. Independently of the answer,
the three workers must sit on three hypervisors: put them in a Nova anti-affinity server group
(`openstack-server-group`) and confirm `serverGroups` on each server before step 4.

## Cost

Prices, NOK per GB-month ex VAT: SSD 1.99, Standard 0.89, Object 0.49 at no commitment; 1.49, 0.69, 0.33 at the
5000 NOK/month tier; the invoice says which applies.

| Layout | Cinder | NOK/month (no commit / top tier) | Saved |
|---|---|---|---|
| Today | 388 SSD | 772 / 578 | |
| 1. After step 4: CNPG on worker disks | 100 SSD | 199 / 149 | 573 / 429 |
| 2. After step 5: versitygw 100 GB Standard, zot on S3 with a 10 GB cache | 60 SSD + 100 Std | 208 / 158 | 564 / 420 |
| 2b. Instead of versitygw: zot moved to a Standard volume | 50 SSD + 50 Std | 144 / 109 | 628 / 469 |

Backups add about 10 NOK/month with WAL compression (measure after a week), and zot's retained SSD volume adds
about 100 for the month it is kept. versitygw costs 65 NOK/month more than row 2b because 100 GB is provisioned
for growth: a building block, not a saving.

## Steps

Each step has a check and a "stopped here" state. Step 1 needs the author (a YubiKey recipient in `.sops.yaml`);
a stand-in can do the rest once it is merged.

1. **Backups first.** Bucket and EC2 credential on Nexthop Object Storage; the openstack extension has no
   object-storage model, so
   add one. Credential as an encrypted Secret in `apps/`, copied to the `infra` vault (decision 005). CNPG Barman
   Cloud
   plugin (the in-tree `barmanObjectStore` is deprecated): per cluster an `ObjectStore` with gzip compression and a
   distinct `serverName`, daily
   `ScheduledBackup`, continuous WAL, 14 days; retention needs to delete, so protect the archive with bucket
   versioning and a lifecycle rule if the object
   store offers them, and record it as an accepted risk if not. Nightly restic of `gitea-shared-storage`, pod-affine
   to the forgejo pod. A restore needs the application
   secrets, so the Zitadel masterkey, Forgejo's generated
   `SECRET_KEY` and `LFS_JWT_SECRET`, and the restic password go into `*.enc.yaml` and the vault first.
   Then a restore drill of both clusters into a scratch namespace (`bootstrap.recovery` via
   `externalClusters[].plugin`, a new `serverName` for the restored cluster's own archive), restic restored beside
   it, timings recorded. Check: `psql` on each restored cluster shows the application tables. Stopped here: proven
   backups.
2. **Worker disk layout, rehearsed first.** The unverified assumption is that a reset wiping only EPHEMERAL
   re-creates it at the new `maxSize` and provisions the user partitions behind it, and that Omni tolerates a
   machine resetting itself. Prove it on the lab cluster with `@dataverket/talosctl` (`patchConfig`, then `reset`
   with `systemLabelsToWipe: [EPHEMERAL]`, then `volumes`) before touching production. Then one Omni config patch
   on the worker machine set, applied through the Omni UI or cluster template: `VolumeConfig` EPHEMERAL with
   `maxSize: 16GiB`; `UserVolumeConfig` `pg-zitadel` (`diskSelector.match: system_disk`, `minSize` and `maxSize`
   3 GiB, xfs) and then `pg-forgejo` (`minSize: 8GiB`, `grow: true`, xfs); kubelet `extraConfig` with
   `imageGCHighThresholdPercent: 80`, `imageGCLowThresholdPercent: 70`,
   `imageMaximumGCAge: 168h`, `containerLogMaxSize: 20Mi`, `evictionHard` `imagefs.available: 2Gi` and
   `nodefs.available: 1Gi`. The patch only takes effect when EPHEMERAL is re-provisioned, so per worker, one at a
   time: promote CNPG
   primaries away (`kubectl cnpg promote`; the primary's PodDisruptionBudget blocks a drain), drain, then
   `talosctl reset --graceful --reboot --system-labels-to-wipe EPHEMERAL` (the `talosctl` model's `reset` with
   `systemLabelsToWipe`; this needs an Operator talosconfig from `omnictl talosconfig`, which the read-only
   service account does not get). STATE and the config survive, the node reboots into the cluster, EPHEMERAL comes
   back at 16 GiB with the two
   user partitions behind it; images re-pull. The fallback is Omni's remove, wipe and re-add. Check: `fleet-volumes` shows EPHEMERAL 16,384 MiB and both user volumes on the worker, node Ready, the drained
   pods running elsewhere. Stopped here: empty user volumes, nothing uses them.
3. **Provisioner (decision 007).** Chart 2.8.0 into `kube-system`, DaemonSet kept off the control planes by node
   affinity (Talos labels control planes, not workers), classes `pg-zitadel-storage` and `pg-forgejo-storage` on
   the two mount patterns, `WaitForFirstConsumer`. Check: three `local` PVs per class, one per worker, capacity
   just under the partition size.
   Then the gate for step 4: `pgbench` on a user volume against the same run on a Cinder SSD claim, since after the
   move two Postgres instances share the root disk's 500 IOPS with image pulls and logs. Stopped here: PVs
   published, nothing bound.
4. **CNPG to the worker disks, one migration per cluster.** `flux suspend kustomization apps`; scale the app to
   zero (identity is down for the restore time from step 1); final backup; patch the cluster's Cinder PVs to
   `Retain`; delete the `Cluster`; wait until `kubectl get pvc -l cnpg.io/cluster=<name>` is empty; commit and
   apply the same-name `Cluster` (so the `-rw` Service and `-app` Secret keep their names) with `storage.storageClass`
   set to the local class and `storage.size` below the partition
   (`8Gi` and `2Gi`; the PV reports filesystem capacity, and a claim of the partition size never binds),
   `instances: 3`, `podAntiAffinityType: required`, `postgresql.synchronous` with `method: any` and `number: 1`,
   `max_slot_wal_keep_size: 1GB`, `imageName` pinned to the archive's Postgres major, Zitadel's
   `enableSuperuserAccess: true` kept, `bootstrap.recovery` from the store with `recovery.database` and
   `recovery.owner` set (recovery does not inherit `initdb`'s names), and a new `serverName`. The regenerated Secret
   has a new password; the scale-up restarts the app with it. Resume Flux.
   Check: three instances on three workers, `fsGroup 26` ownership on the mounts with no init container, app logs
   in, first backup completed; then delete the six retained PV objects and their Cinder volumes by hand. Stopped
   here: layout 1.
5. **versitygw and zot.** Plain manifests in `infrastructure/versitygw/` (decision 002 style): a 100 GB PVC on a new
   `csi-cinder-standard-retain` class (`parameters.type: Standard`, `csi.storage.k8s.io/fstype: xfs`; xattrs hold
   the metadata), one replica, `Recreate`, root credentials from an encrypted Secret, `--iam-dir` and a versioning
   directory on the volume outside the gateway root, ClusterIP only, plain HTTP as decision 004 allows. An init
   container creates the `zot` bucket (a top-level directory); `bootstrap.sh` checks
   for it. `infrastructure/` only orders "applied", so add a `healthChecks` entry for the versitygw Deployment to
   `clusters/production/infrastructure.yaml`. Then zot: `storageDriver` `name: s3` with `regionendpoint` on the
   Service, `forcepathstyle: true`, `secure: false`, `rootDirectory` on a 10 GB SSD claim, `dedupe: false` (on S3
   dedupe depends on a local cache database whose loss strands blobs). Migrate, do not start empty: suspend the zot
   Kustomization, apply the new StatefulSet from git under a new name
   beside the old one, `skopeo sync --all` through the Service, switch the HTTPRoutes and `apps/zot/source.yaml`,
   push the artifact, resume (`bootstrap.sh` skips its git path while the suspended Kustomization reports Ready,
   so apply from git explicitly). Delete the old `Retain` volume after a month. Check: a pull succeeds and the blob is
   a file in the bucket
   directory. Stopped here: layout 2.
6. **Records and models.** Decision 007 is the mechanism. New decisions for: databases
   replicated on worker disks; the 16 GiB EPHEMERAL standard; versitygw as in-cluster S3; backups on Nexthop
   Object Storage. README layout table; `bootstrap.sh` for the credentials and versitygw ordering. Publish
   `@dataverket/omni` and `@dataverket/talosctl`, pull `@dataverket/omni` here, move the `omni` model to it, and
   delete the bridge extension `extensions/models/omni_volumes.ts`.

## Operations after the change

**Failure model.** A worker dying loses one replica of each database; CNPG promotes the synchronous one, with no
Cinder detach and no taint in the path. Cinder-backed pods on that worker still need the `out-of-service` taint
before they move. Losing all three workers at once loses the databases; the object store is the recovery.

**Rebuilding a worker** does not self-heal for the databases. After a wipe and re-add under the same hostname the
old local PV is still bound to the CNPG claim and points at an empty partition; CNPG will not re-clone into it.
Sequence: `kubectl cnpg destroy <cluster> <n>` for that instance; the provisioner republishes the PV; CNPG joins
a fresh replica. Check: three ready instances, lag zero.

**Changing EPHEMERAL later** is step 2 again. The user partitions behind it survive, but a smaller EPHEMERAL
leaves a gap only a new partition can use; plan the cap once.

**Alerts, five:** CNPG last successful backup older than 36 hours; any volume, user volumes included, above 70
percent (`fleet-volumes` on a schedule feeds it for the worker disks); WAL retained by a replication slot above
512 MB; versitygw Service without endpoints for a minute; any pod Terminating over five minutes.

**Upgrades.** Omni rolls one machine at a time with a drain, and the primary's PodDisruptionBudget blocks that
drain: promote primaries off the machine before each roll, as in step 2. Then one replica is down per roll, never
the service; its pod stays Pending until its node returns, because its volume is pinned there.

## Future disk expansions

**Databases.** The partition budget is fixed by the flavor: about 12 GiB per worker for both. The escape hatch
is recreating a cluster on a Cinder class from the object store, the outage of step 4, so both Cinder classes stay
installed. Every flavor with this CPU and RAM has the same 30 GB, so a flavor change never buys disk.

**Cinder.** Every class allows expansion: edit the PVC and wait for the online resize. The versitygw volume
grows first, as Forgejo LFS and packages move onto it; the 70 percent alert is the trigger.

**Bare metal and lab clusters** follow the same standard: EPHEMERAL 32 GiB, a separate CRI volume where images
are large, everything else as user volumes.

## Backups

- **Databases:** Barman Cloud plugin to Nexthop Object Storage, daily base, continuous compressed WAL, 14 days,
  point-in-time recovery. Quarterly drill, timed. The only copy outside the workers.
- **Repositories:** nightly restic of `gitea-shared-storage`, 30 daily and 6 monthly. Its snapshot time is the
  PITR target for the database when both must match.
- **versitygw volume:** none while it holds only registry blobs (mirrors re-copy, artifacts come from git, product
  images rebuild). When Forgejo LFS or attachments land on it, add it to the restic CronJob as a directory tree.
- **Runner caches:** none.

## Not in this plan

Compute is 4,596/month against 772 for volumes; public IPs and load balancers are on top. The three control
planes stay three: etcd replicates for quorum and API availability. That is a separate conversation.

## Placement today

| Service | Component | Storage | Class, tier | Size | Used | Redundancy | Node |
|---|---|---|---|---|---|---|---|
| Forgejo | postgres, CNPG ×3 | Cinder ×3 | `csi-cinder-sc-delete`, SSD | 3 × 64 GB | 620 MB | app ×3 on Cinder ×3 | wrkr-3, wrkr-2, wrkr-3 |
| Forgejo | repositories, LFS, attachments | Cinder | `csi-cinder-sc-delete`, SSD | 10 GB | 11 MB | Cinder ×3 | wrkr-2 |
| Zitadel | postgres, CNPG ×3 | Cinder ×3 | `csi-cinder-sc-delete`, SSD | 3 × 32 GB | 617 MB | app ×3 on Cinder ×3 | wrkr-1, wrkr-3, wrkr-2 |
| zot | blobs and config | Cinder | `csi-cinder-sc-retain`, SSD | 50 GB | not measured | Cinder ×3 | wrkr-1 |
| Runner, org | docker-lib cache (Kata) | Cinder | `csi-cinder-sc-delete`, SSD | 20 GB | not measured | Cinder ×3, disposable | wrkr-1 |
| Runner, release | state | Cinder | `csi-cinder-sc-delete`, SSD | 20 GB | not measured | Cinder ×3 | wrkr-3 |
| Control planes ×3 | Talos system, etcd | flavor root disk, EPHEMERAL 21 GiB | c5.large | 3 × 25 GiB | 1.1 GiB | etcd ×3, disk unknown | ctrl-1..3 |
| Workers ×3 | Talos system, images, logs | flavor root disk, EPHEMERAL 26 GiB | m5.large | 3 × 30 GiB | 5.5, 5.5, 8.4 GiB | disk unknown | wrkr-1..3 |
| Backups | | none | | | | | |

## Placement planned

| Service | Component | Storage | Class, tier | Size | Redundancy | Backup |
|---|---|---|---|---|---|---|
| Forgejo | postgres, CNPG ×3 | worker root disk, `u-pg-forgejo` | `pg-forgejo-storage`, local | 3 × ~9 GiB, claim 8Gi | app ×3, one per worker | Barman to Nexthop Object Storage, PITR |
| Forgejo | repositories | Cinder | `csi-cinder-sc-delete`, SSD | 10 GB | Cinder ×3 | restic to Nexthop Object Storage |
| Forgejo | LFS, attachments, packages (later) | versitygw | S3 on Cinder Standard | in the 100 GB | Cinder ×3 | restic of the directory tree, when populated |
| Zitadel | postgres, CNPG ×3 | worker root disk, `u-pg-zitadel` | `pg-zitadel-storage`, local | 3 × 3 GiB, claim 2Gi | app ×3, one per worker | Barman to Nexthop Object Storage, PITR |
| versitygw | gateway root, IAM dir, versioning dir | Cinder | `csi-cinder-standard-retain`, Standard, xfs | 100 GB | Cinder ×3 | see rows above |
| zot | blobs | versitygw | S3 on Cinder Standard | in the 100 GB | Cinder ×3 | none, rebuildable |
| zot | working dir | Cinder | `csi-cinder-sc-delete`, SSD | 10 GB | Cinder ×3 | none |
| Runner, org | docker-lib cache | Cinder, or root disk if local | SSD, or decision 007 | 20 GB | disposable | none |
| Runner, release | state | Cinder | `csi-cinder-sc-delete`, SSD | 20 GB | Cinder ×3 | none |
| Control planes ×3 | Talos, etcd | flavor root disk, EPHEMERAL default | c5.large | 3 × 25 GiB | etcd ×3 | Omni etcd backups (decision 001) |
| Workers ×3 | Talos, images | flavor root disk, EPHEMERAL 16 GiB | m5.large | 3 × 30 GiB | none needed | none |
| Backups | CNPG archives, restic repos | Nexthop Object Storage | 0.49/GB | ~15 GB | provider | is the backup |
