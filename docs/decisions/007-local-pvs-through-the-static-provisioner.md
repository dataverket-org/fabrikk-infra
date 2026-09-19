# 007: Talos leaves room on the system disk, and the local static provisioner turns that room into PVs

Accepted 2026-09-19.

**Context.** Every node has one disk. By default Talos gives all of it to EPHEMERAL, and the only way to get
storage for workloads is a Cinder volume per claim. Talos can carve user volumes out of the system disk, but only
from space EPHEMERAL has not taken, and Kubernetes has to be shown those partitions as PersistentVolumes.

**Decision.** Talos does not get the whole disk. EPHEMERAL is capped (16 GiB on the cloud workers, 32 GiB at
most anywhere), and the rest is for `UserVolumeConfig` partitions, one per workload, mounted under
`/var/mnt/<name>`. The `sig-storage-local-static-provisioner` publishes each mount as a `local` PV behind a
StorageClass named `<name>-storage`. `local` and not `hostPath`, because the kubelet chowns a `local` PV for the
pod's `fsGroup`, so non-root databases need no init container.

**Consequences.** A PV lives on one node; what uses it replicates itself across nodes (CNPG) or is disposable.
Growing a volume means a new partition or a Cinder volume, not a bigger flavor. Anything that needs snapshots,
clones or shared access is a CSI question, and Cinder stays installed for it.
