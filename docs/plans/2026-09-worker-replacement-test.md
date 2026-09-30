# Plan: worker replacement test

Written 2026-09-30, split out of `docs/plans/2026-09-storage-building-blocks.md` in its eighth revision. That
plan puts Zitadel's database on the worker disks as a rehearsal for bare-metal nodes with NVMe, where a disk that
dies takes its replica with it and nothing like Cinder sits behind it. Its step 4 swaps every worker before any
data is on the local disks, so the one procedure that matters most on bare metal, replacing a node that holds a
replica, never runs there. This plan runs it once, on purpose, on a quiet day. Nothing is applied, and it starts
only after that plan's step 6.

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
