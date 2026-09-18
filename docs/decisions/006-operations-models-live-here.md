# 006: The models that reach this cluster live here, not in the factory

Accepted 2026-09-18.

**Context.** The software factory (`fabrikk`) carried, next to its loop, the swamp models a human uses to operate
what this repository deploys: the cluster through an admin kube context, the Talos fleet through an Omni key, the
registry's push side, the release runner, and forge-wide settings. A workbench runs an agent; whatever that agent
can reach, a mistake can reach.

**Decision.** This repository has its own swamp (`swamp repo init`, 2026-09-18) and its own vault, `infra`, and
holds every model whose credential reaches what it deploys. The factory keeps a repository-scoped forge token and
anonymous registry reads, nothing more. The boundary is structural: no such credential exists in `fabrikk`, and its
`models/` and `workflows/` are protected paths, so an instance that would cross it is a change a human sees.

**Consequences.** Operating the cluster, the fleet, the registry mirror, the release runner, and forge-wide settings
means this checkout. The credentials moved with the models and keep their names (`forgejo/api_token`,
`omni/service_account_key`, `registry/ci_username`, `registry/ci_password`); decision 005 still holds, so the
registry credential's source of record stays `artifacts/zot/`, copied into the `infra` vault. The vault's recipients
are the operator's YubiKey and the factory host's soft key, so the same host can run these unattended when needed;
the cluster's own key never decrypts it. The factory's `uat` and `promoting` stages, once built, read the environment
from the outside (health endpoint, registry) and retag from CI, never through a model from here.
