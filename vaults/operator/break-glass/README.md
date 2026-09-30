# break-glass

Permanent, human-only material: what tier 1 falls back on when a login mechanism fails. The Omni break-glass
talosconfig and kubeconfig first, and later the same for other services.

**Empty as of 2026-09-29.** What fills it is `docs/plans/2026-09-break-glass.md`: a WireGuard interface in the
Talos machine config for the route, and an `os:admin` talosconfig signed from the cluster's own CA for the
credential. Sidero's own break-glass is off for this account and is not being pursued: Omni is not part of future
designs, so the route and the credential here are the first pieces of what replaces it.

**Using what will live here taints the cluster.** An operator talosconfig issued through break-glass exists
outside Omni's control; Omni can neither revoke it nor watch it being used. Coming back to a cluster Omni fully
controls means rotating both certificate authorities, one at a time, with workloads possibly needing a restart
afterwards:

```sh
omnictl cluster -n dataverket-prod secret rotate talos-ca
omnictl cluster -n dataverket-prod secret rotate kubernetes-ca
omnictl cluster -n dataverket-prod secret rotate status
```

So reading a file from here is not a convenience. It is the first step of a recovery that ends in a CA rotation,
and that is why it takes a touch.

Part of `vaults/operator/` (decision 016): plain sops, encrypted to the two operators' YubiKeys and to nothing
else, with no swamp vault config. A write needs only public keys, so a workflow may put a value here; a read needs
a physical touch.

```sh
sops -d vaults/operator/break-glass/<name>.enc.yaml     # a touch, every time
sops -e -i vaults/operator/break-glass/<name>.enc.yaml  # public keys only
```

Two rules keep it honest, and they hold for any store of this kind (decision 001):

- Nothing here may complete a routine login. Break-glass passes because it goes around a service instead of
  logging in to it, and because using it is an incident that leaves a trace. A stored identity-provider password
  would not.
- Nothing here may be needed to recover what hosts it. The forge's own break-glass belongs somewhere that does
  not depend on the forge being up.
