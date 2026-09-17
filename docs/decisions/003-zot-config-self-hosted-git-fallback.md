# 003: zot hosts its own config; git is the bootstrap and recovery source

Accepted 2026-09-17.

**Context.** zot is delivered gitless: Flux pulls its manifests as an OCI artifact. The artifact must live in a
registry that exists before zot does. The forge's container registry was considered and rejected: a recreated
cluster would depend on a forge that may not exist yet either.

**Decision.** The artifact lives in zot. `apps/zot/source.yaml` is the only thing git applies for zot in steady
state. `bootstrap/zot-from-git.yaml`, a second Kustomization without prune, applies the same directory straight
from git until zot serves its first artifact, and again whenever a bad artifact leaves zot unable to serve.
`bootstrap.sh` applies it and removes it.

**Consequences.** Nothing outside this repository and the cluster is needed to recreate the registry. `artifacts/zot`
is authored in git and travels as an artifact, the same shape every later artifact will have. A bad artifact
cannot lock the registry out: the git path brings it back, then a fixed artifact is pushed.
