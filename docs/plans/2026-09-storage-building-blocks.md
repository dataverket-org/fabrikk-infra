# Plan: storage building blocks

Written 2026-09-19 from live inventory (swamp models `dataverket-prod-pvcs`, `openstack-*`, `omni` and
`dataverket-prod-talos`) and the Nexthop price list of the same day. Fourth revision, 2026-09-20: the workers are placed in a Nova
anti-affinity server group and replaced through Omni one at a time, never reset in place; the new disk layout
arrives with the new machines. Reviewed adversarially. Nothing is applied. Decision 007 is the mechanism under the
databases.

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
6. **Placement is declared, not observed.** The workers are members of a Nova anti-affinity server group, so no
   two share a hypervisor, and a worker that cannot be placed fails to boot instead of landing beside a sibling.
   Nova sets membership only at boot, so a machine gets into the group by being created in it; a worker's disk
   layout, which Talos likewise fixes at first provisioning, arrives the same way. A worker is never changed in
   place, it is replaced.

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

**The worker disk after the change**, 30 GiB: 2,102 MiB of Talos partitions, EPHEMERAL 16,384 MiB, and the
remaining 12,234 MiB split evenly: `u-pg-zitadel` 6,144 MiB, `u-pg-forgejo` at least 6,144 MiB grown into the
rest, about 6,090 MiB. Both databases hold about 620 MB today and neither's growth is measured; Zitadel's is an
append-only event store and Forgejo's grows with issues, pull requests and CI runs, so nothing says one deserves
more than the other. Per partition, WAL is budgeted at 1.5 GiB (`max_wal_size` 1 GB plus 512 MB retained by
replication slots), leaving about 4.5 GiB for data, seven times today's. Forgejo's comes last because only the
last partition can grow.

## Placement, and the open question of where the root disks are

Nexthop documents three copies for volumes and nothing for flavor disks. Ask whether flavor root disks are
hypervisor-local or replicated, and whether instances live-migrate. The plan does not depend on the answer: the
disk is paid for either way, and CNPG replicates for failover, not durability. What it does depend on is three
workers on three hypervisors, and today nothing says they are: every server record shows `serverGroups: []`, and
until 2026-09-20 the server model did not record `hostId`, the per-project hash Nova shows a tenant. It does
now, and the seven servers show exactly three values, one control plane and one worker on each: the workers
already sit on three hypervisors, and three is what this project can see. The group turns that from what the
scheduler happened to do into what it must do. Nova honours a server group
only at boot and has no call that adds a running server to one, so the workers are placed by being recreated,
which is step 2. Building block 6.

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
for growth: a building block, not a saving. Step 2 runs one extra m5.large for the hours each swap takes, three
times, a few NOK in total.

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
2. **Worker placement and disk layout, by replacement.** Talos sizes EPHEMERAL and provisions user volumes only
   when it first provisions a machine, and Nova sets server-group membership only at boot, so both arrive the same
   way: a new worker, created in the group, provisioned by Omni with the patch already on it. Three swaps, one
   worker at a time, never fewer than three workers in the cluster. Nothing is reset in place and no rehearsal
   cluster is needed: this is the path the existing workers took on 2026-09-07, from the same image, plus a
   group and a patch. The Omni side is four methods of the `omni-cluster` model (`@dataverket/omnictl/cluster`,
   the Operator service account `fabrikk-infra-omni-cluster` on its own vault key,
   `omni/operator_service_account_key`; the Reader `fabrikk-infra-omni` stays on `omni`): `applyPatch` writes a
   machine-scoped `ConfigPatch` (label `omni.sidero.dev/machine: <uuid>`, id `500-<hostname>-storage`);
   `addMachine` writes the `MachineSetNode` (id the machine's UUID, labels `omni.sidero.dev/machine-set:
   dataverket-prod-workers` and `omni.sidero.dev/cluster: dataverket-prod`), which is what the UI's "add machine"
   creates; `removeMachine` is `omnictl cluster machine delete <uuid>`, which drains, wipes and waits;
   `forgetMachine` deletes the retired machine's `Link` and refuses while it is in a cluster. The first
   `applyPatch` and `addMachine` run with `dryRun=true`, so Omni validates both resources with the new key before
   anything is written.

   Once, before the first swap: `openstack-server-group create` with `name: dataverket-prod-workers` and
   `policy: anti-affinity` (an existing name is reused; no `maxServerPerHost`, so one member per host). And the
   patch, written once and applied as a machine-scoped Omni `ConfigPatch` to each new machine before it joins,
   not to the machine set: `VolumeConfig` EPHEMERAL with `maxSize: 16GiB`; `UserVolumeConfig` `pg-zitadel`
   (`diskSelector.match: system_disk`, `minSize` and `maxSize` 6 GiB, xfs) and then `pg-forgejo` (`minSize: 6GiB`,
   `grow: true`, xfs); kubelet `extraConfig` with `imageGCHighThresholdPercent: 80`,
   `imageGCLowThresholdPercent: 70`, `imageMaximumGCAge: 168h`, `containerLogMaxSize: 20Mi`, `evictionHard`
   `imagefs.available: 2Gi` and `nodefs.available: 1Gi`. `system_disk` is what keeps Talos off the Cinder disks
   attached to the same machine, so it is checked in the patch before anything else is. The old workers must
   never see the patch: a user volume a running machine cannot fit is a state this plan has not proved harmless,
   and a machine-scoped patch is the guarantee. After the third swap the same patch moves to the workers machine
   set, where every member already matches it, so a future worker inherits it.

   Per swap, new machine first, old machine last, so every step before the last leaves the old worker untouched:
   1. `openstack-server create`: `name` the next free `dataverket-wrkr-N` (4, 5, 6; nothing keys on the names),
      `flavor: m5.large`, `image: dataverket-omni-talos-amd64`, `networks: [infra1-net]`,
      `securityGroups: [default]`, `serverGroup: dataverket-prod-workers`, its siblings' description. The image
      carries the Omni join token of 2026-09-07, so the machine appears in Omni unallocated, provided that token
      is still active: `omni joinTokens` before the first create (2026-09-20: one token, active, default, six
      machines joined, no expiry), and a new image from the current default token if it is not. A create that fails with no valid
      host is the group doing its job: the zone has no free hypervisor, and that is a conversation with Nexthop
      before a `soft-anti-affinity` retreat.
   2. `omni-cluster applyPatch` for the machine, then `omni-cluster addMachine` into `dataverket-prod-workers`;
      the stored `configPatch` and `machineSetNode` are the record. Omni installs Talos: EPHEMERAL at 16 GiB,
      both user volumes behind it, the kubelet thresholds. The node joins.
   3. Check: `fleet-volumes` shows the new node with EPHEMERAL 16,384 MiB and `u-pg-zitadel`, `u-pg-forgejo`,
      and every Cinder disk on it untouched; `omni discover` shows it running in the workers machine set with
      `siderolabs/kata-containers` among its extensions; `openstack-server get` shows the group under
      `serverGroups`, a `hostId` unlike the other new workers', and the load balancers' `lb-sg-*` groups, which
      OCCM adds to members by itself; the node is Ready. Anything else: stop, the old worker is untouched and the new one is deleted.
   4. Retire the old worker, the one with the fewest database instances first (wrkr-3 carries two of Forgejo's
      today): promote CNPG primaries away (`kubectl cnpg promote`; the primary's PodDisruptionBudget blocks a
      drain), cordon and drain; every pod on it is Cinder-backed or stateless and reattaches elsewhere.
      `omni-cluster removeMachine`, which wipes it and returns it to the pool. `openstack-server get` must show
      `volumesAttached` empty; then `openstack-server delete` by ID (rule 5); only then `omni-cluster
      forgetMachine`, because a wiped machine that is still running re-registers the moment its entry goes.
      Then `swamp workflow run fleet-volumes`, so the talosconfig record carries the new node list.

   Check after the third swap: three workers, `serverGroups` non-empty on each, three distinct `hostId` values
   across them, which is the placement the group promised, observed; the patch on the machine set. Stopped here: empty user volumes on three placed workers, nothing
   uses them.
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
   (`5Gi` for both; the PV reports filesystem capacity, and a claim of the partition size never binds),
   `instances: 3`, `podAntiAffinityType: required`, `postgresql.synchronous` with `method: any` and `number: 1`,
   `max_slot_wal_keep_size: 512MB` and `max_wal_size: 1GB`, `imageName` pinned to the archive's Postgres major, Zitadel's
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
6. **Records and models.** Decision 007 is the mechanism. New decisions for: workers placed by a Nova server
   group and replaced through Omni, never changed in place; databases replicated on worker disks; the 16 GiB
   EPHEMERAL standard; versitygw as in-cluster S3; backups on Nexthop Object Storage. README layout table; `bootstrap.sh` for the credentials and versitygw ordering. Publish
   `@dataverket/omnictl` (2026-09-20: the `omni` extension renamed after its CLI, `inventory` and `cluster` model
   types) and `@dataverket/openstack` with `hostId`, pull both here in place of the source trees, and remove the
   pulled `@dataverket/omni`.

## Operations after the change

**Failure model.** A worker dying loses one replica of each database; CNPG promotes the synchronous one, with no
Cinder detach and no taint in the path. Cinder-backed pods on that worker still need the `out-of-service` taint
before they move. Losing all three workers at once loses the databases; the object store is the recovery.

**Replacing a worker** is step 2's swap, and it is the only way a worker changes: a new machine in the group,
the old one retired. It does not self-heal for the databases: the instance whose volume was on the old node keeps
a claim bound to a `local` PV on a node that no longer exists (or, under a reused hostname, to an empty
partition), and CNPG will not re-clone into it. Sequence: `kubectl cnpg destroy <cluster> <n>` for that instance,
delete the orphaned PV, and CNPG joins a fresh replica on the new worker, where the required anti-affinity and the
class's `WaitForFirstConsumer` put it. Check: three ready instances, lag zero, the new server in the group.

**Changing EPHEMERAL later** is three swaps with a new patch; a machine never changes its layout in place, so
the gap a shrunk EPHEMERAL would leave never arises. Plan the cap once anyway: a swap moves every replica.

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
planes stay three: etcd replicates for quorum and API availability. That is a separate conversation, and so is
their placement: they are in no server group either, and placing one is an etcd member replacement.

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
| Workers ×3 | Talos system, images, logs | flavor root disk, EPHEMERAL 26 GiB | m5.large | 3 × 30 GiB | 5.5, 5.5, 8.4 GiB | disk unknown, no server group | wrkr-1..3 |
| Backups | | none | | | | | |

## Placement planned

| Service | Component | Storage | Class, tier | Size | Redundancy | Backup |
|---|---|---|---|---|---|---|
| Forgejo | postgres, CNPG ×3 | worker root disk, `u-pg-forgejo` | `pg-forgejo-storage`, local | 3 × ~6 GiB, claim 5Gi | app ×3, one per worker | Barman to Nexthop Object Storage, PITR |
| Forgejo | repositories | Cinder | `csi-cinder-sc-delete`, SSD | 10 GB | Cinder ×3 | restic to Nexthop Object Storage |
| Forgejo | LFS, attachments, packages (later) | versitygw | S3 on Cinder Standard | in the 100 GB | Cinder ×3 | restic of the directory tree, when populated |
| Zitadel | postgres, CNPG ×3 | worker root disk, `u-pg-zitadel` | `pg-zitadel-storage`, local | 3 × 6 GiB, claim 5Gi | app ×3, one per worker | Barman to Nexthop Object Storage, PITR |
| versitygw | gateway root, IAM dir, versioning dir | Cinder | `csi-cinder-standard-retain`, Standard, xfs | 100 GB | Cinder ×3 | see rows above |
| zot | blobs | versitygw | S3 on Cinder Standard | in the 100 GB | Cinder ×3 | none, rebuildable |
| zot | working dir | Cinder | `csi-cinder-sc-delete`, SSD | 10 GB | Cinder ×3 | none |
| Runner, org | docker-lib cache | Cinder, or root disk if local | SSD, or decision 007 | 20 GB | disposable | none |
| Runner, release | state | Cinder | `csi-cinder-sc-delete`, SSD | 20 GB | Cinder ×3 | none |
| Control planes ×3 | Talos, etcd | flavor root disk, EPHEMERAL default | c5.large | 3 × 25 GiB | etcd ×3 | Omni etcd backups (decision 001) |
| Workers ×3, anti-affinity group | Talos, images | flavor root disk, EPHEMERAL 16 GiB | m5.large, one per hypervisor | 3 × 30 GiB | none needed | none |
| Backups | CNPG archives, restic repos | Nexthop Object Storage | 0.49/GB | ~15 GB | provider | is the backup |
