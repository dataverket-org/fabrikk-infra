# Plan: talosctl over Omni

Written 2026-10-01, after swap 1 of the storage plan. Omni will not be used long term, so it stays as little used as
possible, and every workflow moves to open source `talosctl`, Kubernetes and OpenStack models. Nothing here happens
during the storage migration; until then, only the rule below applies.

## The rule from now on

A workflow step uses `talosctl`, a Kubernetes model or an OpenStack model wherever one can do the job. Omni is called
only for what nothing else can do while the cluster is Omni-managed: putting a machine into the cluster
(`applyPatch`, `addMachine`), taking it out (`removeMachine`, `deleteMachine`), extensions (`setExtensions`), the
talosconfig and the machine list. New code goes into `@dataverket/talosctl` first, and nothing new is built on
Omni-only features such as machine classes or cluster templates.

## What Omni does today, and what replaces it

| Omni does | Replaced by |
|---|---|
| A machine joins through the join token in the image | The machine config at boot, as server `userData`, or `talosctl apply-config --insecure` in maintenance mode |
| Generates the machine config from the cluster's secrets | `talosctl gen config` from a secrets bundle and the patches in `talos/` |
| Holds the cluster's secrets | A secrets bundle, sops-encrypted, readable by the operators' YubiKeys only (decision 001) |
| `ConfigPatch` per machine or machine set | Patch files in git, merged by `gen config`; a running machine's change by `talosctl patch` |
| Extensions per machine or machine set | An Image Factory schematic in git; the installer image and the OpenStack image built from it |
| `removeMachine`: drain and wipe | Kubernetes drain, then `talosctl reset --graceful` |
| `deleteMachine`: the Link | Deleting the Kubernetes node; there is no Link |
| talosctl through Omni's proxy | A direct talosconfig signed by the cluster's CA, and a network path to the nodes |
| Talos and Kubernetes upgrades | `talosctl upgrade` and `talosctl upgrade-k8s`, one machine at a time in a workflow |
| etcd backups (decision 003) | `talosctl etcd snapshot`, written to the hov1 site like the CNPG archives |

## Code to add

1. `@dataverket/talosctl/node`: `etcdSnapshot`, `upgradeK8s`, and `genConfig`, which renders a role's machine config
   from a secrets bundle and patch files, both named as files, never carried.
2. A `drain` method for `@swamp/kubernetes/node`, as an extension of that type; `delete` for a node. The drain
   waits until the node's Cinder volumes are detached before anything wipes it: in the worker replacement test a
   wipe right after Omni's drain left Forgejo's database volume attached for about six minutes.
3. An Image Factory schematic file in `talos/`, and a method or workflow that builds the OpenStack image from it with
   `openstack-image create`, so kata is in the image and not in Omni.
4. A CNPG model (`status`, `promote`, `destroy`, `backup`), needed with or without Omni. It comes first: with it
   `worker-retire` gets a last job that destroys the instance the retired worker held, deletes the released PV and
   checks three ready instances, which were `kubectl` by hand on 2026-10-01.
5. Workflows: `worker-join` and `worker-retire` in a talosctl form beside the Omni form, chosen by the cluster, and
   `talos-upgrade` and `etcd-snapshot`.

## Steps

1. **No new Omni dependency.** Holds now; a review of each new workflow checks it.
2. **The code above**, with unit and negative tests, published. `genConfig` diffed against the machine config Omni
   generated proves the secrets and patches are complete.
3. **A lab cluster without Omni**, bootstrapped with `talosctl`, runs `worker-join`, `worker-retire`, an upgrade and
   an etcd restore. Stopped here: every operation proven away from prod.
4. **Detach prod.** Export the secrets from a control plane's machine config (`talosctl gen secrets
   --from-controlplane-config`), encrypt them for the operators, give every machine a config without SideroLink, and
   take the cluster out of Omni. Then the talosctl workflows replace the Omni ones, and a decision records it.

## Open questions

- The network path to the nodes once Omni's proxy is gone: a bastion, a WireGuard endpoint, or Talos API access
  limited to the operators' addresses. This decides step 4's order.
- `userData` puts the bootstrap token in Nova's metadata, readable by every project member; `apply-config
  --insecure` avoids that but needs the network path.
- The workers' server group is full at three, on the three hypervisors the zone gives the project. Every swap is
  retire first on two workers, or a stand-in outside the group and two swaps
  (`docs/plans/2026-09-worker-replacement-test.md`, "Result"). Ask Nexthop for a fourth hypervisor, or choose one
  order and write it into decision 017, which says new machine first.
- Whether a running cluster can leave Omni without replacing its machines; if not, step 4 is three swaps, and the
  control planes need a plan of their own.
