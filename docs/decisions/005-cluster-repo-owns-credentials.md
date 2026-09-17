# 005: This repository owns a credential; the factory copies it

Accepted 2026-09-17.

**Context.** The software factory (`fabrikk`) keeps its own vault. Some credentials, such as the registry push user,
are needed by both the cluster and the factory. Two sources of truth drift.

**Decision.** A credential the cluster uses is authored here as an encrypted Secret manifest and is the source of
record. When the factory needs the same value, it is copied from here into the factory's vault, and the commit says
so. Never the other way around.

**Consequences.** Rotation starts here: change the `*.enc.yaml`, push the artifact or merge, then copy. The first
credential born this way is `fabrikk-ci` (`artifacts/zot/zot-ci-credentials.enc.yaml`, copied to the vault as
`registry/ci_username` and `registry/ci_password`). Older hand-applied secrets are migrated one at a time.
