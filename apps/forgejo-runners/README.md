# The runners

Two Forgejo Actions runners from the runner chart (`repo.yaml`). `org-dataverket-runner/` is registered at org level
as `dataverket-runner` and runs as the chart documents it: an ordinary pod with a privileged dind sidecar.
`fabrikk-release-runner` is the factory's release runner. Both registration tokens are hand-made Secrets
(`bootstrap.sh`). Their volumes are in `docs/storage.md`.

## The org runner

**Out of Kata since 2026-10-16.** It ran under the `kata` RuntimeClass from its first commit. In the guest dind was
slow, a Filesystem claim arrived as virtiofs where overlay2 fails, and a job could not run docker itself. Now the pod
runs on the node's runtime; the RuntimeClass stays for the fabrikk runner (`workflows/workflow-fabrikk-runner.yaml`).

**Docker in jobs.** The runner config takes the chart's `values-dind-bypass.yaml`: jobs run on the pod's network,
so `DOCKER_HOST=tcp://127.0.0.1:2376` is the dind sidecar, and its client certificates are mounted from
`/certs/client`. A job runs `docker build` against the same daemon as the runner, with the same store.

**The docker store** is a Cinder volume at dind's `/var/lib/docker` (`docker-store-pvc.yaml`), so it survives a pod
restart and the multi-gigabyte job images are not pulled again. It is a plain Filesystem claim, ext4 on the node,
where overlay2 works. The Kata-era Block claim, `org-dataverket-runner-docker-store`, could not change `volumeMode`,
so this is a new claim and the store started empty once.

**Rollouts.** The store is one `ReadWriteOnce` disk attached to one worker at a time, so a rollout must stop the
old pod before starting the new one: `maxSurge: 0`, `maxUnavailable: 1`. With the chart's default surge the new pod
started while the old one held the disk on another worker and waited forever (2026-09-18 to 2026-10-04).
`Recreate` says the same, but server-side apply refuses to switch a live Deployment to it, since the defaulted
`rollingUpdate` block stays on the object. The chart has no strategy value, so the release patches the Deployment
(decision 021). The runner is down for the minutes a Cinder detach and attach take, on every rollout.

## Readers

The group `fabrikk-readers`, which the factory's kubeconfig and the operators' readers context carry, has `view`
cluster-wide since 2026-10-04 (`infrastructure/readers/`); Secrets are excluded by `view` itself (decision 003).
