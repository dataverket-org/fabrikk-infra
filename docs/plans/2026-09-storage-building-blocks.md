# Plan: storage building blocks

Written 2026-09-19 from live inventory (swamp models `dataverket-prod-pvcs`, `openstack-*`, `omni` and
`dataverket-prod-talos`) and the Nexthop price list of the same day. Fourth revision, 2026-09-20: the workers are placed in a Nova
anti-affinity server group and replaced through Omni one at a time, never reset in place; the new disk layout
arrives with the new machines. Fifth revision, 2026-09-20: backups go to the hov1 site, `213.128.185.82:443`, a
versitygw with the posix backend in Docker (`backup/versitygw`, instantiated as `backup/hov1`), instead of Nexthop
Object Storage; the
in-cluster versitygw of building block 3 keeps its role. Reviewed adversarially again the same day; what it found
(the admin API signs with the region, the sops rule path, SIGHUP reloads versitygw's certificate, versioning without
lifecycle, the WAL rate) is folded in. Sixth revision, 2026-09-21: the backups of step 1 are live and tested, so
that step is a record under "Done"; the mechanism under the databases changes from the static provisioner
(decision 007) to a CSI driver with thin snapshots on an LVM volume group Talos creates, so that CNPG can take
volume snapshots from a standby and kopia can ship them, which is what makes the same design carry a multi-terabyte
tenant later; a lab proof of that stack is the new step 1, and decision 008 will supersede 007's mechanism while
keeping its principle. Nothing after "Done" is applied.

## Building blocks

1. **One redundancy layer per kind of data.** Blob-shaped and single-writer data (registry, repositories, runner
   caches) sits on Cinder, which keeps three copies. Databases replicate themselves: CNPG runs three instances, one
   per worker, on thin logical volumes carved from a volume group on each worker's root disk, with one synchronous
   replica so a failover loses no acknowledged commit. Those disks are
   paid for with the flavor and need no Cinder attach to fail over. Nothing replicates on top of Cinder.
2. **EPHEMERAL is a fixed 16 GiB on the workers**, 32 GiB at most anywhere else. Talos sizes a volume only when
   it first provisions it, and by default EPHEMERAL takes the whole disk; a cap turns the kubelet's percentage
   thresholds into a budget. `maxSize` accepts a percentage, but a share of the disk is the wrong unit across
   30 GiB and 1 TB disks.
3. **Object storage inside the cluster is versitygw on Cinder**: one S3 endpoint, POSIX backend, Standard tier;
   registry blobs first, later Forgejo LFS and packages.
4. **Backups leave the provider.** The target is `213.128.185.82:443`, a versitygw with the posix backend in Docker
   at the hov1 site (`backup/hov1`), reached by address so that no zone, name or DirectAdmin sits in the backup
   path: a different building, a different network, a different operator's mistakes. The
   in-cluster versitygw shares Cinder's blast radius and Nexthop Object Storage shares the account's, so neither is
   the copy that matters. The price is availability: the site's uplink is down more often than a provider's, so every
   writer must tolerate hours of that, and the WAL alert below is what makes an outage cheap instead of fatal.
5. **Tier by shape.** SSD for working trees and caches, Standard for blobs.
6. **Placement is declared, not observed.** The workers are members of a Nova anti-affinity server group, so no
   two share a hypervisor, and a worker that cannot be placed fails to boot instead of landing beside a sibling.
   Nova sets membership only at boot, so a machine gets into the group by being created in it; a worker's disk
   layout, which Talos likewise fixes at first provisioning, arrives the same way. A worker is never changed in
   place, it is replaced.
7. **Snapshots are the base backup once a database is large; the object store is the WAL and the small case.**
   A thin snapshot taken from a standby restores in minutes at any size (the CNPG community's measurement: 4.4 TB
   back in about two minutes from a snapshot, against object-store restores counted in hours, and object-store
   base backups called adequate below roughly half a terabyte). barman-cloud archives WAL to the object store
   everywhere, for point-in-time recovery; base backups go to the object store while a database is small and become
   daily snapshots plus a kopia copy of the snapshot, encrypted and deduplicated, to a provider-near S3 once it is
   not. The driver is the lightest one that does this on Talos: OpenEBS LVM LocalPV, thin, on a volume group Talos
   makes; no extension, no host process namespace, two components, and it creates the thin pool itself. What it
   does not give, block-level shipping (`zfs send`, LINSTOR) and per-class overcommit accounting (TopoLVM), is
   bought back with kopia and with claims sized below the pool.

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
remaining 12,234 MiB as one raw volume, `pg`, which is the physical volume of the LVM volume group `pg`. The
driver owns the group: a thin pool over all of it, and a thin logical volume per claim. Both databases hold about
620 MB today and neither's growth is measured; Zitadel's is an append-only event store and Forgejo's grows with
issues, pull requests and CI runs, so nothing says one deserves more than the other, and thin volumes make the
split a non-question: each claims 5Gi, each uses what it writes. Per database, WAL is budgeted at 1.5 GiB
(`max_wal_size` 1 GB plus 512 MB retained by replication slots); the pool holds two databases' data and WAL plus
the delta of the one snapshot kept, so about 8 GiB is the working budget against 1.2 GB used today. The 70
percent alert moves from the partition to the thin pool.

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

Backups cost nothing per month, the hov1 site is paid for; measure the archive's size and the WAL rate after a week
anyway, they size the site's disk and say how long an outage the budget survives. zot's retained SSD volume adds
about 100 for the month it is kept. versitygw costs 65 NOK/month more than row 2b because 100 GB is provisioned
for growth: a building block, not a saving. Step 2 runs one extra m5.large for the hours each swap takes, three
times, a few NOK in total.

## Done

- **Backups, off the provider** (was step 1; 2026-09-20 and 21). The hov1 site runs `backup/versitygw` as
  `backup/hov1` at `213.128.185.82:443`: versitygw alone, posix backend, a private CA and a certificate made offline
  with `step` and valid three years, accounts `cnpg-forgejo` and `cnpg-zitadel` each owning one bucket, credentials
  delivered as sops-encrypted Secrets and the site's root, endpoint and region as a plain one. The Barman Cloud
  plugin v0.15.0 is installed beside CNPG 1.30; both clusters archive WAL continuously and take a base backup
  daily (03:00 and 03:30 UTC), 14 days retained; the first restore test passed on 2026-09-21, both clusters
  healthy 1 min 49 s after apply and equal to production. The record is `backup/README.md`, the console is
  `backup/cnpg-backups.md`, the restore test is `backup/restore-test/`. Left from that step and moved to step 4:
  the file backups of the repositories, now with kopia instead of restic.

## Steps

Each step has a check and a "stopped here" state. Step 1 runs on a lab cluster and changes nothing in
production; a stand-in can do every step once it is merged.

1. **Lab proof of the local storage stack.** A Talos lab cluster from the production image, three workers with
   a spare disk or a spare partition each. Four things must be shown, and their numbers land in this plan:
   1. *The stack survives Talos.* `RawVolumeConfig` `pg` on the system disk, `LVMVolumeGroupConfig` `pg` on it,
      OpenEBS LVM LocalPV (chart pinned; node DaemonSet on workers only) with `thinProvision: "yes"`, the
      snapshot CRDs and snapshot-controller, a `VolumeSnapshotClass` on the driver. A thin pool the driver
      creates inside a volume group Talos reconciles is documented by neither side, so: volumes in use, one worker
      rebooted, one Talos upgrade rolled, the pool and every volume intact afterwards.
   2. *CNPG snapshots.* A three-instance cluster on the `pg-thin` class; `backup.volumeSnapshot` with
      `online: false` and `target: prefer-standby`, so the copy is a cold one from a fenced standby and needs no
      `backup_label`; a clone-restore with `bootstrap.recovery.volumeSnapshots` on the same node; the primary
      never notices.
   3. *The kopia round trip.* A Job on the standby's node clones the newest snapshot, runs kopia with the
      `FIXED-1M` splitter (Postgres pages do not shift, so content-defined chunking buys nothing), `zstd`, kopia's
      own encryption, into an S3 bucket; retention is a kopia policy. The restore is a Job template, not a
      procedure: kopia restore into a claim of the original size, a `VolumeSnapshot` of it, a `Cluster` recovering
      from that snapshot with the hov1 WAL archive as `externalClusters` source for point in time. It must run
      end to end and end with `psql` showing the tables.
   4. *The numbers.* pgbench at the largest size the lab disks allow: nightly bytes read from the clone (kopia
      re-reads every 1 GB segment touched since the night before), bytes uploaded, snapshot delta in the pool,
      wall time on the standby's node, and the controllers' resident memory after a week. From these the 4 TB
      case is extrapolated and written next to building block 7.
   Check: all four pass. Stopped here: production untouched, and the choice made. Fallbacks in order: TopoLVM if
   the driver and Talos disagree over the volume group (same shape, plus the `lvm2` extension and a host process
   namespace); LINSTOR with LVM thin pools when a tenant needs per-class replication or block-level snapshot
   shipping; ZFS LocalPV only if IncusOS alignment becomes a requirement rather than a preference.
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
   not to the machine set: `VolumeConfig` EPHEMERAL with `maxSize: 16GiB`; `RawVolumeConfig` `pg`
   (`diskSelector.match: system_disk`, `minSize: 12GiB`, `grow: true`) and `LVMVolumeGroupConfig` `pg` selecting
   it, exactly as step 1 proved them; kubelet `extraConfig` with `imageGCHighThresholdPercent: 80`,
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
      the raw volume and the volume group behind it, the kubelet thresholds. The node joins.
   3. Check: `fleet-volumes` shows the new node with EPHEMERAL 16,384 MiB and the raw volume `pg`, the driver's
      `LVMNode` (once step 3 is in) or a `vgs` from its node pod shows volume group `pg`, and every Cinder disk on
      it untouched; `omni discover` shows it running in the workers machine set with
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
   across them, which is the placement the group promised, observed; the patch on the machine set. Stopped here:
   an empty volume group on three placed workers, nothing uses it.
3. **Driver and classes (decision 008).** Under `infrastructure/`: the snapshot CRDs and snapshot-controller
   (shared by every CSI driver, so Cinder snapshots become possible too), OpenEBS LVM LocalPV pinned to the version
   step 1 proved, its node DaemonSet kept off the control planes by node affinity (Talos labels control planes,
   not workers), StorageClass `pg-thin` (`volgroup: pg`, `thinProvision: "yes"`, `fsType: xfs`,
   `WaitForFirstConsumer`, expansion allowed) and VolumeSnapshotClass `pg-thin`. The Cinder classes stay. Check:
   a `CSIStorageCapacity` per worker for the class, a test claim that binds on the worker the scheduler picks, a
   snapshot of it, and a clone from the snapshot that binds on the same node; then all three deleted.
   Then the gate for step 4: `pgbench` on a thin volume against the same run on a Cinder SSD claim, since after the
   move two Postgres instances share the root disk's 500 IOPS with image pulls and logs. Stopped here: driver
   published, nothing bound.
4. **CNPG to the worker disks, one migration per cluster.** `flux suspend kustomization apps`; scale the app to
   zero (identity is down for the restore time the restore test measured); final backup; patch the cluster's Cinder PVs to
   `Retain`; delete the `Cluster`; wait until `kubectl get pvc -l cnpg.io/cluster=<name>` is empty; commit and
   apply the same-name `Cluster` (so the `-rw` Service and `-app` Secret keep their names) with `storage.storageClass:
   pg-thin` and `storage.size: 5Gi` for both,
   `instances: 3`, `podAntiAffinityType: required`, `postgresql.synchronous` with `method: any` and `number: 1`,
   `max_slot_wal_keep_size: 512MB` and `max_wal_size: 1GB`, `imageName` pinned to the archive's Postgres major, Zitadel's
   `enableSuperuserAccess: true` kept, `bootstrap.recovery` from the store with `recovery.database` and
   `recovery.owner` set (recovery does not inherit `initdb`'s names), a new `serverName`, and
   `backup.volumeSnapshot` (`className: pg-thin`, `online: false`) with `backup.target: prefer-standby` and a
   second `ScheduledBackup` of `method: volumeSnapshot`, daily, one kept: the fast rollback point, and the path
   kept warm; the object-store base backups continue unchanged, since at 620 MB they are the right base backup
   (building block 7). The regenerated Secret has a new password; the scale-up restarts the app with it. Resume
   Flux. kubelet applies `fsGroup 26` on mount (`fsGroupChangePolicy: OnRootMismatch`, so a large tree is not
   walked every start), no init container.
   Check: three instances on three workers, ownership right on the mounts, app logs in, the next base backup and
   the first snapshot completed, a clone from the snapshot binding; then delete the six retained PV objects and
   their Cinder volumes by hand.
   In the same step the file backups, left over from the backups step: a kopia CronJob for `gitea-shared-storage`,
   pod-affine to the forgejo pod, nightly, kopia policy 30 daily and 6 monthly, kopia's own encryption so hov1 holds
   only ciphertext, to the bucket `files-forgejo` with its own account on hov1 (`bin/user files-forgejo forgejo`),
   the repository password through the same sops pipeline; the restore test grows a kopia restore beside the
   Postgres one. Stopped here: layout 1.
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
6. **Records and models.** Decision 008 supersedes 007's mechanism (a CSI driver with thin snapshots on an LVM
   volume group Talos makes, in place of the static provisioner) and keeps its principle (Talos leaves room on the
   system disk; the room becomes PVs). New decisions for: workers placed by a Nova server group and replaced
   through Omni, never changed in place; databases replicated on worker disks; the 16 GiB EPHEMERAL standard;
   versitygw as in-cluster S3; backups on the hov1 site over the public internet; snapshots plus kopia as the base
   backup above half a terabyte, barman-cloud WAL everywhere; kopia for file-level backups. README layout table;
   `bootstrap.sh` for the credentials and versitygw ordering. The models this plan runs on are published and
   pulled from the registry since 2026-09-20: `@dataverket/omnictl` (`inventory` and `cluster`),
   `@dataverket/openstack` with `hostId`, and `@dataverket/sops` under the vault. Not needed for this plan,
   since the site's endpoint is an address: a `@dataverket/directadmin` `dns-record` model for names that are not
   cluster services, and the `dvkt.no` credential in `nordhost-config`. Both arrive the day the endpoint gets a name
   (`s3.hov1.dvkt.no`), which is what an address change would ask for.

## Operations after the change

**Failure model.** A worker dying loses one replica of each database; CNPG promotes the synchronous one, with no
Cinder detach and no taint in the path. Cinder-backed pods on that worker still need the `out-of-service` taint
before they move. Losing all three workers at once loses the databases; the hov1 site is the recovery.

**Replacing a worker** is step 2's swap, and it is the only way a worker changes: a new machine in the group,
the old one retired. It does not self-heal for the databases: the instance whose volume was on the old node keeps
a claim bound to a thin volume on a node that no longer exists, and CNPG will not re-clone into it. Sequence:
`kubectl cnpg destroy <cluster> <n>` for that instance, delete the orphaned PV and any snapshot that lived on
that node (their kopia copies remain), and CNPG joins a fresh replica on the new worker, where the required
anti-affinity and the class's `WaitForFirstConsumer` put it. Check: three ready instances, lag zero, the new
server in the group.

**Changing EPHEMERAL later** is three swaps with a new patch; a machine never changes its layout in place, so
the gap a shrunk EPHEMERAL would leave never arises. Plan the cap once anyway: a swap moves every replica.

**Alerts, nine:** CNPG WAL archiving failing for over two hours, which is the hov1 site unreachable: `max_wal_size`
and the slot budget cap nothing here, Postgres keeps every unarchived segment until the archive takes it, and with
CNPG's default `archive_timeout` of five minutes a barely busy primary makes a 16 MiB segment every five minutes,
about 190 MiB an hour, so the 4.5 GiB of headroom is gone in about a day and the alert leaves some twenty hours to
act; the certificate at `213.128.185.82:443` expiring within 30 days, probed from the cluster, since nothing at the
site renews a three-year certificate and the reissue is a calendar event; CNPG last successful backup older than 36
hours; the newest volume snapshot of a cluster older than 36 hours; any volume above 70 percent, and the thin
pool's data and metadata above 70 percent, since a full thin pool fails every volume on it at once (`fleet-volumes`
on a schedule feeds the first, the driver's `LVMNode` records the second); WAL retained by a replication slot above
384 MB, below the 512 MB at which the slot is invalidated; versitygw Service without endpoints for a minute; any
pod Terminating over five minutes.

**Upgrades.** Omni rolls one machine at a time with a drain, and the primary's PodDisruptionBudget blocks that
drain: promote primaries off the machine before each roll, as in step 2. Then one replica is down per roll, never
the service; its pod stays Pending until its node returns, because its volume is pinned there.

## Future disk expansions

**Databases.** The pool is fixed by the flavor: about 12 GiB per worker for both databases and their snapshots.
Thin provisioning lets claims add up to more than that, and it does not make bytes; the pool alert is the truth.
The escape hatch is recreating a cluster on a Cinder class from the object store, the outage of step 4, so both
Cinder classes stay installed. Every flavor with this CPU and RAM has the same 30 GB, so a flavor change never buys
disk; a second disk does, on bare metal, and it joins the same volume group.

**Cinder.** Every class allows expansion: edit the PVC and wait for the online resize. The versitygw volume
grows first, as Forgejo LFS and packages move onto it; the 70 percent alert is the trigger.

**Bare metal and lab clusters** follow the same standard: EPHEMERAL 32 GiB, a separate CRI volume where images
are large, everything else in the volume group; a database that will grow large gets its own disk in it.

## Backups

- **Databases:** Barman Cloud plugin to `213.128.185.82:443`, continuous compressed WAL and a daily base backup, 14
  days, point-in-time recovery; live since 2026-09-20. Plus, after step 4, a daily cold snapshot from a standby,
  one kept, on the worker: the rollback point. Once a database passes about half a terabyte, the snapshot is the
  base backup and kopia copies it nightly, encrypted, to a provider-near S3; the object store keeps the WAL.
  Quarterly restore test through the templates, timed; the first passed on 2026-09-21.
- **Repositories:** nightly kopia of `gitea-shared-storage` to `files-forgejo` on hov1, 30 daily and 6 monthly,
  encrypted before it leaves the cluster. Its snapshot time is the PITR target for the database when both must
  match.
- **versitygw volume:** none while it holds only registry blobs (mirrors re-copy, artifacts come from git, product
  images rebuild). When Forgejo LFS or attachments land on it, add the directory tree to the kopia CronJob.
- **Runner caches:** none.

## Not in this plan

Compute is 4,596/month against 772 for volumes; public IPs and load balancers are on top. The three control
planes stay three: etcd replicates for quorum and API availability. That is a separate conversation, and so is
their placement: they are in no server group either, and placing one is an etcd member replacement. The
multi-tenant CNPG offering is its own plan; this one makes production's storage path, thin snapshots from a
standby, kopia off the node, WAL to an object store, the same path that offering will run, so nothing is
discovered twice.

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
| Backups | CNPG archives | versitygw at the hov1 site | posix | ~10 MB | one disk | is the backup | hov1 |

## Placement planned

| Service | Component | Storage | Class, tier | Size | Redundancy | Backup |
|---|---|---|---|---|---|---|
| Forgejo | postgres, CNPG ×3 | worker root disk, thin volume in volume group `pg` | `pg-thin`, local, OpenEBS LVM LocalPV | claim 5Gi thin, pool ~12 GiB shared | app ×3, one per worker | Barman to `213.128.185.82`, PITR; daily cold snapshot from a standby |
| Forgejo | repositories | Cinder | `csi-cinder-sc-delete`, SSD | 10 GB | Cinder ×3 | kopia to `213.128.185.82` |
| Forgejo | LFS, attachments, packages (later) | versitygw | S3 on Cinder Standard | in the 100 GB | Cinder ×3 | kopia of the directory tree, when populated |
| Zitadel | postgres, CNPG ×3 | worker root disk, thin volume in volume group `pg` | `pg-thin`, local, OpenEBS LVM LocalPV | claim 5Gi thin, pool ~12 GiB shared | app ×3, one per worker | Barman to `213.128.185.82`, PITR; daily cold snapshot from a standby |
| versitygw | gateway root, IAM dir, versioning dir | Cinder | `csi-cinder-standard-retain`, Standard, xfs | 100 GB | Cinder ×3 | see rows above |
| zot | blobs | versitygw | S3 on Cinder Standard | in the 100 GB | Cinder ×3 | none, rebuildable |
| zot | working dir | Cinder | `csi-cinder-sc-delete`, SSD | 10 GB | Cinder ×3 | none |
| Runner, org | docker-lib cache | Cinder, or root disk if local | SSD, or `pg-thin` (decision 008) | 20 GB | disposable | none |
| Runner, release | state | Cinder | `csi-cinder-sc-delete`, SSD | 20 GB | Cinder ×3 | none |
| Control planes ×3 | Talos, etcd | flavor root disk, EPHEMERAL default | c5.large | 3 × 25 GiB | etcd ×3 | Omni etcd backups (decision 001) |
| Workers ×3, anti-affinity group | Talos, images | flavor root disk, EPHEMERAL 16 GiB | m5.large, one per hypervisor | 3 × 30 GiB | none needed | none |
| Backups | CNPG archives, kopia repositories | versitygw at the hov1 site, `213.128.185.82:443` | posix, `backup/hov1` | ~15 GB | one disk | is the backup |
