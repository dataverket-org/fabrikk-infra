# 002: zot is plain manifests, not a Helm chart

Accepted 2026-09-17.

**Context.** Upstream ships a Helm chart for zot. Everything else in `apps/` is a HelmRelease.

**Decision.** `artifacts/zot/` is a StatefulSet, a Service, a ConfigMap, two Secrets, and two HTTPRoutes, written
by hand, image pinned by digest. The chart wraps exactly those objects and would add helm at build time and a chart
version to track, for nothing.

**Consequences.** The artifact is the authored directory itself, pushed as-is: nothing is rendered or templated,
in a build or in the cluster. Upgrading zot is changing one digest. The security posture (non-root, read-only root
filesystem, no capabilities) is explicit in the file rather than a values key.
