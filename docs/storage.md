# Storage

Where dataverket-prod keeps its data, and how the workers that hold some of it are replaced. The decisions behind it
are 014 and 017 to 021. What is backed up, to where and how a restore runs is `backup/README.md`.

## Where data lives

| Service | Data | Storage | Class, tier | Size | Redundancy | Backup |
|---|---|---|---|---|---|---|
| Forgejo | postgres, CNPG ×1 | Cinder | `csi-cinder-sc-delete`, SSD | 10 GB | Cinder ×3 | Barman to the hov1 site, 14 days, PITR |
| Forgejo | repositories, LFS, attachments | Cinder | `csi-cinder-sc-delete`, SSD | 10 GB | Cinder ×3 | push mirror to GitHub; kopia to the hov1 site later |
| Zitadel | postgres, CNPG ×3, one synchronous replica | each worker's `u-pg-zitadel` partition | `pg-zitadel-storage`, local | 3 × 11 GiB, claim 10Gi | the database itself, one instance per worker | Barman to the hov1 site, 14 days, PITR |
| zot | blobs and config | Cinder | `csi-cinder-standard-retain`, Standard | 10 GB | Cinder ×3 | none; mirrors re-copy, artifacts come from git |
| Runner, org | docker-store, a raw disk dind formats itself, overlay2 (Kata) | Cinder | `csi-cinder-sc-delete`, SSD | 20 GB | disposable | none |
| Runner, release | state | Cinder | `csi-cinder-sc-delete`, SSD | 20 GB | Cinder ×3 | none |
| Control planes ×3 | Talos, etcd | flavor root disk, `c5.large` | EPHEMERAL default | 3 × 25 GiB | etcd ×3 | none: Omni's etcd backup store is not configured (decision 003's audit) |
| Workers ×3 | Talos, images, logs | flavor root disk, `m5.large` | EPHEMERAL 14 GiB | 3 × 30 GiB | none needed | none |

Cinder holds 60 GB of SSD and 10 GB of Standard. Every Cinder class allows expansion. Each database is one redundancy
layer (decision 018): Zitadel's replicates itself, every other one is a single instance on a volume Cinder keeps three
copies of. Zulip's database, when it comes, is one more single instance on its own SSD volume, sized at install. An
in-cluster S3 endpoint, one versitygw on one Cinder volume, is `docs/plans/2026-10-s3-osl1.md`; Forgejo's LFS and
packages are its first writer, Zulip's uploads the second.

## The workers

Three `m5.large` workers, wrkr-5, wrkr-6 and wrkr-8, in the Nova anti-affinity server group `dataverket-prod-workers`,
one per hypervisor; the zone gives the project three hypervisors, so the group is full. Their disk layout is
`talos/dataverket-prod/workers-storage.yaml`, on the workers machine set in Omni as `500-workers-storage` and on each
machine as `500-<hostname>-storage`:

| Volume | Size | Holds |
|---|---|---|
| EPHEMERAL | 14 GiB, `minSize` equal to `maxSize` | Container images and logs; the kubelet collects images from 80 percent |
| `u-pg-zitadel` | 11 GiB, xfs, `minSize` equal to `maxSize` | One instance of Zitadel's database, mounted at `/var/mnt/pg-zitadel` |

About 1 GiB of each disk stays unused. `infrastructure/local-static-provisioner/` publishes every worker's mount as a
`local` PV of class `pg-zitadel-storage` (`Retain`, `WaitForFirstConsumer`), reported as 10Gi; the kubelet sets the
pod's `fsGroup` on the mount, so the database needs no init container. The flavor caps the root disk at 500 IOPS and
100 MiB/s each way, which the database shares with image pulls and CI; Zitadel writes a few events per login and has
room in that.

The control planes have the default layout: EPHEMERAL on the whole disk, 21 GiB. Bare-metal and lab nodes follow the
same standard: EPHEMERAL 32 GiB at most, a separate CRI volume where images are large, user volumes on the data disk
where the node has one and free to grow there, sizes stated when they share the system disk.

## Failure model

- A worker dies: Zitadel loses one replica and no acknowledged commit; CNPG promotes the synchronous one, with no
  volume to reattach. Every Cinder-backed pod on that worker, Forgejo's database among them when it is there, is down
  until the `out-of-service` taint frees its volume and it reattaches elsewhere, minutes.
- All three workers die at once: Zitadel's database is gone, and the hov1 site is its recovery.
- The hov1 site is unreachable: Postgres keeps every unarchived WAL segment, about 190 MiB an hour on a quiet primary,
  so the smallest headroom, about 9 GiB on Forgejo's volume and 9.5 GiB on Zitadel's partition, lasts about two days.

## Replacing a worker

A worker is never changed in place (decision 017). The swap is two workflows, `worker-join` and `worker-retire`,
each with checks that fail rather than wait; a failed check is resumed `--from` the step it reads:

```sh
swamp workflow run worker-join --input name=dataverket-wrkr-N
swamp workflow resume worker-join --run <id> --from discover   # Omni registers the machine within a minute
swamp workflow resume worker-join --run <id> --from node-get   # the install takes minutes
kubectl cnpg promote zitadel-db <instance> -n zitadel --context dataverket-prod-admin   # if the old worker holds the primary
swamp workflow run worker-retire --input name=dataverket-wrkr-M
swamp workflow resume worker-retire --run <id> --from server-after   # a Cinder volume can take six minutes to detach
kubectl cnpg destroy zitadel-db <instance> -n zitadel --context dataverket-prod-admin   # the instance the old worker held
```

- **The group is full at three**, so a fourth worker in it fails to create with "No valid host was found". Either
  retire first and run on two workers until the new one joins, or join a stand-in outside the group (`worker-join`
  with an empty `serverGroup`) and replace it with a second swap once the group has room. A worker joined outside
  the group is one the group does not protect.
- **Zitadel's replica does not move.** The instance whose PV was on the old worker keeps a claim bound to a PV on a
  node that is gone. `kubectl cnpg destroy` that instance: CNPG joins a fresh replica on the new worker at once, under
  the same serial, cloned from the primary; measured at 68 seconds to three ready instances. Then delete the released
  `local` PV, which is cleanup. The `kubectl cnpg` plugin (Brewfile) needs the admin context.
- **Destroying an instance on a worker that stays** is different: the class keeps a released PV's data, so reset the
  partition first (`dataverket-prod-talos reset` with `u-pg-zitadel` named) before the PV is republished.
- **A Cinder volume can stay attached** to the retired server for about six minutes after Omni's wipe; the database
  on it is down for that long. A drain that waits for the volumes to detach is in `docs/plans/2026-10-talosctl-over-omni.md`.
- **Check:** three workers in the group with three distinct `hostId`s, every node Ready, three ready Zitadel instances
  with zero lag, WAL archiving working.

The promote and destroy are `kubectl` by hand until a CNPG model exists (`docs/plans/2026-10-talosctl-over-omni.md`).

## Upgrades

Omni rolls one machine at a time with a drain, and the primary's PodDisruptionBudget blocks that drain: promote
Zitadel's primary off the machine first. One replica is down per roll, never the service; its pod stays Pending until
its node returns. A single-instance database on the rolled machine is down while its volume moves.

## Changing the layout, the flavor or the sizes

Three swaps with a new patch; a laid-out disk keeps its layout. Zitadel's partition is fixed at 11 GiB, as much as the
flavor's disk leaves; outgrowing it means recreating the cluster on a Cinder class from the archive, the same
migration a rebuild runs. At Nexthop every flavor with this CPU and RAM has the same 30 GB disk, so only a larger
flavor buys disk (`r5.large` has 40 GB). A Cinder volume grows online: edit the claim and wait.

## Rebuild from git

The old cluster is gone, and with it Forgejo, Flux's source (decision 021). The source for the rebuild is the GitHub
mirror, `github.com/dataverket-org/fabrikk-infra`, which carries every repository as of its last converged push.

1. One commit pushed to the mirror, never while the old cluster runs: each plugin `serverName` to its next number
   (`bin/check-recovery-names` prints the commands), and `clusters/production/flux-system/gotk-sync.yaml` on the
   mirror's URL.
2. `./bootstrap.sh --source github` on workers that carry the storage patch: Flux from the repository's own
   manifests, read-only; infrastructure with both Cinder classes and the provisioner.
3. Both databases restored from the hov1 site by the `bootstrap.recovery` in git, each from the archive its old
   cluster last wrote; the application secrets are already in `*.enc.yaml`. `bootstrap.sh` ends with a base backup of
   each cluster, since the ScheduledBackup's `immediate` run races the recovery.
4. zot comes back empty on a new Standard volume, filled by mirrors, artifacts and rebuilds; the runner volumes empty.
5. Forgejo's repositories restored by hand from the GitHub mirrors, this repository with the rebuild commit among
   them, before Forgejo's push mirror runs again, since it force-pushes. Then a last commit points `gotk-sync.yaml`
   back at `git.dataverket.org`.

A rebuild on the same machines resets the `u-pg-zitadel` partitions first, because the provisioner publishes whatever
is on them. The server group, servers and machine set are made by swamp's models from the files in git; they are below
Flux. No rebuild has been run yet (decision 021's audit).

## Alerts

Written down, not deployed:

| Alert | Threshold | Meaning |
|---|---|---|
| CNPG WAL archiving failing | over 2 hours | the hov1 site unreachable; about two days of headroom from the alert |
| Certificate at `213.128.185.82:443` | expires within 30 days | nothing at the site renews it; reissue is a runbook in `backup/versitygw/README.md` |
| CNPG last successful base backup | older than 36 hours | the ScheduledBackup did not complete |
| Any volume, user volumes included | above 70 percent | `fleet-volumes` on a schedule feeds it for the worker disks; zot's volume grows first |
| WAL retained by a replication slot | above 384 MB | below the 512 MB at which the slot is invalidated |
| Any pod Terminating | over five minutes | a volume or a node that does not let go |
