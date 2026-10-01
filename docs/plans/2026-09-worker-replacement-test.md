# Plan: worker replacement test

Written 2026-09-30, split out of `docs/plans/2026-09-storage-building-blocks.md` in its eighth revision. That
plan puts Zitadel's database on the worker disks as a rehearsal for bare-metal nodes with NVMe, where a disk that
dies takes its replica with it and nothing like Cinder sits behind it. Its step 4 swaps every worker before any
data is on the local disks, so the one procedure that matters most on bare metal, replacing a node that holds a
replica, never runs there. This plan runs it once, on purpose, on a quiet day. It starts only after that plan's
step 6. Applied 2026-10-01, twice in a row; see "Result" at the end.

## What it proves

That a worker holding a `zitadel-db` instance can be retired and replaced with no login lost, and that the
sequence in "Replacing a worker" of the storage plan is complete: the instance whose `local` PV was on the old node
is destroyed, its PV is deleted, and CNPG joins a fresh replica on the new worker, cloned from the primary. The
timings are the other result: how long the clone takes at this size is what a bare-metal disk failure will cost
before the cluster is back to three.

## Steps

Each step has a check and a "stopped here" state. The machine work is the storage plan's step 4 swap; only the
database part is new.

1. **Choose the worker.** One holding a replica, not the primary (`kubectl cnpg status zitadel-db`). Record the instance number, its PV and the replication lag. Stopped here: nothing changed.
2. **A new worker in the group.** Steps 4.1 to 4.3 of the storage plan, unchanged: `openstack-server create` in
   `dataverket-prod-workers`, then `omni-cluster addMachine` alone, since the machine set carries the patch from
   the third swap on, and the same checks. A create that fails with no
   valid host means the zone has no fourth hypervisor free; the test then needs Nexthop first.
   Stopped here: four workers, the new one empty.
3. **Retire the old worker.** Cordon and drain. The primary's PodDisruptionBudget does not block, since the
   primary is elsewhere; the instance's pod is evicted and stays Pending, because its claim is bound to a PV on
   this node. `omni-cluster removeMachine`, `openstack-server get` with `volumesAttached` empty,
   `openstack-server delete` by ID (rule 5), `omni-cluster forgetMachine`, `swamp workflow run fleet-volumes`.
   Check: two ready instances, logins work, and commits still wait for the one replica left (`method: any`,
   `number: 1`); losing that replica too blocks writes until one is back. Stopped here: a
   degraded cluster that serves, which is the state a dead bare-metal disk leaves.
4. **Replace the instance.** First check that the provisioner has published a `local` PV on the new worker;
   without it the new instance stays Pending. Then `kubectl cnpg destroy zitadel-db <n>`; delete the orphaned `local` PV; CNPG creates
   a new instance, which the required anti-affinity and `WaitForFirstConsumer` put on the new worker. Time from
   destroy to ready. Check: three ready instances, one per worker, lag zero, the next backup completed, and a login during the clone worked. Stopped here: done.
5. **Write it down.** The timings, anything the storage plan's sequence missed, and whether the sequence should
   become a swamp workflow beside `talos-reboot-node`: its inputs would be the node and the cluster, and its
   checks the ones above.

## Not in this test

A primary on the retired worker: promoting it away first is the storage plan's upgrade procedure and already runs
with every Omni roll. A reused hostname, where a repaired node returns with an empty partition under the same
name and the old claim looks bound to it: on bare metal that is the likely case, but OpenStack names here are
never reused, so it is left for the first bare-metal cluster to test. Losing a worker without a drain: the
failure model says CNPG promotes and the `out-of-service` taint frees the Cinder volumes; it is worth a test of
its own, not a variant of this one.

## Cost

One m5.large for the hours between step 2 and step 3, a few NOK.

## Result, 2026-10-01

The procedure ran twice the same afternoon and passed both times. A login to `zitadel.dataverket.org` worked in
each degraded state, checked by the user, and the new replica was ready about 68 seconds after the destroy. The
workers are now wrkr-5 (`cfe2744a-…`), wrkr-6 (`589b001b-…`) and wrkr-8 (`90bf77b4-…`), all in
`dataverket-prod-workers` on three hypervisors; the primary `zitadel-db-1` is on wrkr-5, `zitadel-db-2` on wrkr-6
and `zitadel-db-3` on wrkr-8. All times below are UTC.

**Why twice.** Step 2 failed as it said it could: `openstack-server create` in the group gave "No valid host was
found", at 11:14 and again at 14:53. The project's servers sit on three hypervisors, and an anti-affinity group
of three leaves no host for a fourth member. A server without the group was created at once, so wrkr-7
(`9ba23354-…`) joined outside the group as a stand-in, on the hypervisor of wrkr-5. Nova cannot add a server to a
group afterwards, so once wrkr-4 was gone and its hypervisor free, wrkr-8 joined in the group and wrkr-7 was
retired by the same procedure. The two errored servers of the failed creates were deleted by ID.

| | First pass, wrkr-4 to wrkr-7 | Second pass, wrkr-7 to wrkr-8 |
|---|---|---|
| Join, `addMachine` to a Ready node with the layout | about 4 min | about 5.5 min from `create` |
| `removeMachine`, drain and wipe | 1 min 25 s | under 1 min 43 s, the whole retire |
| Wait for Cinder before the server could be deleted | about 6 min | none |
| Destroy to three ready instances | 68 s (15:34:53 to 15:36:01) | 69 s (15:46:06 to 15:47:15) |
| Size of the database | 603 MB | 603 MB |

**What the storage plan's sequence missed.**

- A fourth worker in the group is not possible while the zone gives the project three hypervisors. The order that
  fits the group is retire first and join after, on two workers in between, or a stand-in outside the group and a
  second swap, as here. Bare metal has the same shape: the replacement arrives after the loss.
- CNPG does not wait for the orphaned PV to be deleted. `kubectl cnpg destroy` removed the claim and the pod, and
  CNPG made a new claim at once, bound to the free `local` PV on the new worker, and started the join. The serial
  was reused: the new instance is `zitadel-db-3` again, not `zitadel-db-4`. Deleting the released PV is cleanup
  only, and the order of the two does not matter.
- The first retire stopped twice at `detached`. The volume of Forgejo's database stayed attached to wrkr-4 after
  the wipe, probably because the node was gone before the kubelet could unmount it, and it moved to wrkr-5 after
  about six minutes. Forgejo's database was down from about 15:05 to 15:12. `worker-retire` resumed from
  `server-after` and finished. A drain that waits for Cinder volumes to leave before the wipe would shorten this;
  it is the `drain` method of `docs/plans/2026-10-talosctl-over-omni.md`.
- `worker-join` takes an empty `serverGroup` input and then creates the server outside any group. That was useful
  here and is a way to make a worker the group does not protect; the workflow does not warn about it.

**Not checked.** "The next backup completed" waits for `zitadel-db-daily` at 03:30 on 2026-10-02; WAL archiving
was working, with nothing waiting, after both passes. "A login during the clone" was a login in the degraded state
just before each destroy, not during the 68 seconds.

**Should it be a workflow.** Yes, as one more job at the end of `worker-retire` and not a workflow of its own:
when the retired node held a CNPG instance on a `local` PV, destroy that instance, delete the released PV after
reading it back, and check three ready instances. It needs the CNPG model (`status`, `promote`, `destroy`) that
the talosctl plan lists, since both steps were `kubectl` by hand with the admin context here.

**Left as found.** A pod of `org-dataverket-runner` was at `Init:0/1` before the test and still is: a rollout
that cannot finish, since the pod of the old ReplicaSet runs on wrkr-5 and holds the `docker-lib` volume the new
pod waits for. The storage plan's twelfth revision carries the new workers and placement.
