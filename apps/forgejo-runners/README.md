# The runners

Two Forgejo Actions runners from the runner chart (`repo.yaml`). `org-dataverket-runner/` is registered at org level
as `dataverket-runner`, labels `ubuntu-latest` and `kata`, and runs jobs under the `kata` RuntimeClass
(`infrastructure/kata-containers/`). `fabrikk-release-runner` is the factory's release runner. Both registration
tokens are hand-made Secrets (`bootstrap.sh`). Their volumes are in `docs/storage.md`.

## The org runner under Kata

**Sizing.** Kata sizes the guest from the container's limits: `default_vcpus` (1) plus the cpu limit, and
`default_memory` (2Gi) plus the memory limit. Without a cpu limit the VM had one vCPU.

**The docker store** is a Cinder volume, so it survives a pod restart; dind's default `/var/lib/docker` is on the
guest's ephemeral rootfs, and every restart would pull the multi-gigabyte job image again. The claim
(`docker-store-pvc.yaml`) is `volumeMode: Block`: a Filesystem claim reaches a Kata guest as a virtiofs share, on
which overlay2 fails with `EINVAL`, so dind fell back to vfs and copied the whole image for every job, three minutes
per `docker create` (tested 2026-10-04). A Block claim is a virtio-blk disk in the guest, the guest's own ext4 runs
on it and overlay2 works with layers shared copy-on-write. The disk is handed to dind as a device in the release's
patch, since the chart's `volumeMounts` value has no place for a device. dind formats it once, when `blkid` finds
no filesystem, and only mounts it afterwards; formatting unconditionally would wipe the store on every restart.
`blkid`, `mkfs.ext4` and `mount` are in the dind image. `volumeMode` cannot change on an existing claim, so the
Block claim was a new claim and the store started empty once.

**Rollouts.** The store is one `ReadWriteOnce` disk attached to one worker at a time, so a rollout must stop the
old pod before starting the new one: `maxSurge: 0`, `maxUnavailable: 1`. With the chart's default surge the new pod
started while the old one held the disk on another worker and waited forever (2026-09-18 to 2026-10-04).
`Recreate` says the same, but server-side apply refuses to switch a live Deployment to it, since the defaulted
`rollingUpdate` block stays on the object. The chart has no strategy value, so the release patches the Deployment
(decision 021). The runner is down for the minutes a Cinder detach and attach take, on every rollout.

## Readers

The group `fabrikk-readers`, which the factory's kubeconfig and the operators' readers context carry, has `view`
cluster-wide since 2026-10-04 (`infrastructure/readers/`); Secrets are excluded by `view` itself (decision 003).
