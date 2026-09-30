# Plan: break-glass without Omni

Written 2026-09-29, after decision 001 and the credential-tiers plan removed the long-lived Omni Operator key from
the vault. Nothing is applied.

## Why

Every administrative path into `dataverket-prod` runs through Omni today. The kubeconfig and the talosconfig are
Omni-proxied, the Operator key is minted by Omni, and the login behind all of it is an Omni browser login. The
nodes carry only private `10.0.0.x/24` addresses and a SideroLink address on Omni's own WireGuard overlay, so
there is no route to them that Omni is not part of. Omni is therefore a single point of failure for
administrative access, and the tiers sharpened that rather than softened it.

Sidero's own break-glass is off for this account and could be turned on by asking, but that is not the direction
Dataverket is going: Omni is not part of future designs, and an alternative will be built. So the point of this
plan is not a hedge for the Omni era. It is the first piece of what comes after, built while Omni is still here to
make it with, and exercised now so that the day Omni goes Dataverket already owns a route to its machines and an
administrative credential that does not depend on anyone.

## Goals

1. **Reach the Talos API and the Kubernetes API without Omni**, whether it is down for an afternoon or gone for
   good. The second case is the one that is actually coming.
2. **No standing inbound exposure.** No floating IP on a control plane, no Talos or Kubernetes API on the
   internet, no new security group that accepts connections from outside.
3. **Independent of Kubernetes as well as of Omni.** The route must come up with the node, before the control
   plane, so that it is there precisely when the cluster is broken.
4. **Built from powers this repository already has**, which today is an Omni Operator key minted per session and a
   config patch. Nothing here waits on a vendor.
5. **The credential stays tier 3 and human-only**, in `vaults/operator/break-glass/` behind the two YubiKeys, with its use
   deliberate, rare and traceable.
6. **Useful after Omni, not only during it.** The overlay and the `os:admin` credential are the parts of a
   replacement that have to exist whatever else changes, so building them now is work that carries forward rather
   than a hedge that gets thrown away.
7. **Honest about the trade.** While Omni is still in place this is a second way in, and a standing one. The plan
   states that cost rather than hiding it.

## The two halves

A door is a credential and a route, and the route is what is missing.

### The route: our own SideroLink

A WireGuard interface declared in the Talos machine config, not a CNI feature and not a workload. Talos brings
`machine.network.interfaces[].wireguard` up at the network layer, before Kubernetes, so it survives a broken
control plane, an unscheduled pod and a CNI change. Cilium's WireGuard is transparent pod-to-pod encryption
between nodes and does not give anyone a way in; the two share a name and nothing else.

The nodes dial **out**. They sit behind OpenStack with egress, so each node holds a peer entry for one hub with a
persistent keepalive, and nothing on the cluster side ever accepts an inbound connection from the internet. The
hub is `hov1`, which already has a public address and runs services. Operators peer with the same hub and reach
the nodes' Talos API on `:50000` and the Kubernetes API on `:6443` across the overlay.

That is, deliberately, the same shape as SideroLink. The difference is whose it is.

### The credential: an os:admin talosconfig from the cluster's own CA

The Talos CA, certificate and key, is in the control-plane machine config. With the Operator key a session mints,
that config is readable, and from the CA an `os:admin` client certificate can be signed and written into a
talosconfig whose endpoints are the overlay addresses rather than Omni's proxy.

Only the talosconfig is stored. A kubeconfig is not: once `talosctl` answers over the overlay,
`talosctl kubeconfig` produces one from the node, so storing a second permanent credential buys nothing.

## The cost, stated once

A certificate minted this way exists outside Omni's control. Omni can neither revoke it nor see it used, and the
cluster counts as tainted from the moment it is used. Coming back to a cluster Omni fully controls means rotating
the Talos CA:

```sh
omnictl cluster -n dataverket-prod secret rotate talos-ca
omnictl cluster -n dataverket-prod secret rotate status
```

which invalidates the stored talosconfig and obliges a re-mint. That loop is the maintenance this plan carries,
and it is bounded: it lasts only as long as Omni manages the cluster. Once it does not, a certificate outside
Omni's control is simply the credential, and the rotation is a step on the way out rather than a recurring debt.

The route carries its own: whoever holds the hub and a peer key reaches the Talos API of every node, permanently.
The hub is therefore as sensitive as the cluster, and the operator peer key is break-glass material like the
talosconfig, under the same rule and in the same place.

## Steps

1. **Settle the overlay.** An address range for the admin overlay that overlaps nothing in use, one address per
   node and one per operator, and the hub's public endpoint and port. Write the addressing down before anything
   is applied.
2. **Stand up the hub on hov1.** WireGuard, its own key, the port open, peers added as they are made. It is
   infrastructure of the same weight as the cluster, so it belongs in this repository's backup and restore story
   rather than in one person's notes.
3. **Patch the nodes.** A config patch through `omni-cluster applyPatch`, `dryRun` first, adding the WireGuard
   interface and the hub peer to every machine. Each node's private key is machine-config material and is
   generated per node, never shared.
4. **Verify the route while Omni is up.** From an operator peer, reach `:50000` and `:6443` on each node over the
   overlay. This proves the route alone, with the Omni-proxied credential still in hand.
5. **Mint the talosconfig.** Read the Talos CA from a control-plane machine config with an Operator key, sign an
   `os:admin` client certificate, and write a talosconfig whose endpoints are the overlay addresses. Encrypt it
   into `vaults/operator/break-glass/` with the two YubiKeys, and encrypt the operator peer key beside it.
6. **Run an access test.** With the Omni-proxied contexts deliberately unused, open the talosconfig, reach a
   control plane over the overlay, and take a `talosctl kubeconfig` from it. That is the whole procedure, and it
   is the only way to know it works. Record the date; repeat it when the cluster is rebuilt.
7. **Write the taint down where it will be read.** `vaults/operator/break-glass/README.md` already carries the rotation
   obligation; add the re-mint step and the access-test date.
8. **Decide what this means for the tiers.** The credential tiers lean on Omni for all of tier 2: the kube
   contexts, the talos context and both service account keys are minted by it. A replacement has to mint
   credentials with a lifetime on the authority of a human login, which is point 3 of "a service built later" in
   `docs/plans/2026-09-access-requests.md`. If it cannot, tier 2 falls back to permanent keys and the tiers lose
   their compensating control. Worth settling before the replacement is designed, not after.

## What is assumed and must be checked in step 4 and 5

- That the control-plane machine config is readable through Omni's proxy with the Operator role, and that the CA
  key is present in it rather than redacted. If it is not, the credential half falls back to Sidero's break-glass
  and this plan keeps only the route.
- The exact `talosctl` sequence for signing a client certificate against an existing CA. The mechanism is
  standard; the commands are not written here because they have not been run.
- That the nodes have egress to the hub's port, and that OpenStack's security groups allow the outbound flow.

## Not in this plan

- Kubernetes authentication. `docs/plans/2026-09-kubernetes-identity.md` moves it to Zitadel and needs the route
  this plan builds, which is the reason to build the route once and use it twice. It runs after this one.
- Cilium. The cluster's CNI is Omni-provisioned and nothing in this repository touches it; a CNI change is a
  next-cluster decision and is independent of everything above.
- Omni's etcd backups, which have no destination configured on this instance. Cluster state and cluster access are
  different problems and both are worth solving.
- Access for anyone but the two operators. The overlay is an administrative path, not a VPN for Dataverket.
