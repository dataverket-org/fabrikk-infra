# Plan: a swamp extension that administers Zitadel

Written 2026-09-29, updated 2026-10-01. The extension is built, unit tested, and exercised against a throwaway
Zitadel 4.19.3 in podman. It is published as `@dataverket/zitadel` and pulled here at 2026.10.01.2, and seven
models name it. Every read method has run against the real instance on 4.15.3. What is left is the write path on
a throwaway project.

## Why

`docs/plans/2026-09-kubernetes-identity.md` step 2 wants a Zitadel project for the cluster, an application for
kubelogin with its redirect URIs, roles that become the groups claim, and a service user for automation. Those are
objects someone would otherwise click into a console once and never be able to reproduce. Decision 015 makes
Zitadel the thing that decides who reaches the cluster, so what it holds belongs in git and in swamp like the rest
of the platform.

The registry has one Zitadel extension, `@thomas/zitadel` (MIT): one model type, machine identities only, no hard
deletes and no read of a single project, application or user. Its narrowness is its author's stated design, so
widening it belongs in a fork rather than in a pull request.

## What was built

`@dataverket/zitadel` in `~/kode/swamp-extensions/zitadel/`, forked from `@thomas/zitadel` with the licence notice
and attribution kept, split into one model type per resource the way `@dataverket/openstack` is. Seven types, 73
methods:

| Type                           | Methods                                                                                                     |
| ------------------------------ | ------------------------------------------------------------------------------------------------------------ |
| `@dataverket/zitadel/project`  | `list get ensure update setState delete roleList roleEnsure roleRemove`                                      |
| `@dataverket/zitadel/app`      | `list get ensureOidc ensureApi redirectSet update setState secretRotate delete keyCreate keyList keyDelete`  |
| `@dataverket/zitadel/user`     | `list get ensureMachine ensureHuman update setState delete pat{Create,List,Revoke} key{Create,List,Delete} secret{Generate,Remove} metadata{Set,List,Delete} passwordResetLinkCreate` |
| `@dataverket/zitadel/grant`    | `list ensure setState delete`                                                                               |
| `@dataverket/zitadel/org`      | `get list managerList`                                                                                      |
| `@dataverket/zitadel/action`   | v2 actions: `list get ensure delete`, `execution{List,Set,Remove}`, `catalog`, `key{List,Add,SetState,Remove}` |
| `@dataverket/zitadel/settings` | `read` (every settings kind in force, with the scope each came from), `securitySet`, `loginTranslationSet`   |

`project` also carries the grants to other organizations (`projectGrant*`, `projectGrantMember*`), and `user`
carries authentication factors and identity-provider links (`authFactorList`, `authFactorRemove`, `idpLink*`) —
which is what "does this person actually have MFA" is asked with.

Users speak the v2 user service, which is the supported surface on this instance (chart 10.0.4, Zitadel v4) and
the only one that reaches keys, tokens, metadata and password reset. Projects, applications, roles and grants
speak v1 Management, because their v2 services are still beta here. Paths and bodies were read from the
instance's own OpenAPI documents rather than from memory.

What live testing found, and what it changed:

- **The v2 user service wants three things v1 inferred.** A create needs the organization id in the body; a
  machine description must be absent rather than empty; a personal access token and a user key need an explicit
  expiry. The first is now looked up once and sent, the second omitted when not given, the third a required
  argument rather than an HTTP 400 at the end of a run.
- **Swamp reads a method's name as a lifecycle.** A method called `delete`, `destroy` or `remove` means "the
  resource this model stands for is gone", and swamp tombstones *every* declared resource of the model after it
  runs — including under `dryRun`, and including the projects the call never touched. These types hold a
  collection, so their destructive methods now declare `kind: "action"` and tombstone only the instance that went
  away, and the find-or-create methods declare `kind: "create"` so a model recovers after its last resource is
  deleted.
- **A malformed key said "Failed to decode base64" and nothing else.** It now says it is the service user's key
  that will not parse, and the smoke suite asserts the key material is not in the message.
- **A target Zitadel would not call said only `Errors.Target.DeniedURL`.** It resolves a target's host first and
  refuses what it cannot resolve, as well as anything on the instance's deny list; the error now says that.
- **Settings booleans were missing rather than false.** Proto3 omits a `false`, so an audit record where `forceMfa`
  was simply absent read as "nobody knows" when it meant "off". They are normalized to their effective value.
- **Data names embedded ids.** An application stored as `app-392938678139224587-kubelogin` cannot be named by a
  workflow that has not run yet, which makes `data.latest()` and therefore rule 4 unusable. Everything is keyed by
  the names a person types: `app-kubernetes-kubelogin`, `role-kubernetes-kube-admins`,
  `grant-svc-kubernetes-kubernetes`.
- **`dryRun` and `devMode` looked mandatory.** Their defaults lived inside a zod preprocessor where the schema
  could not see them, so `swamp workflow validate` demanded them on every step. Declared on the schema instead.

Three properties the repository cares about:

- **A hard delete is guarded.** It re-reads the resource, refuses unless `confirm` repeats the live name, and
  takes `dryRun`. Deactivating is reversible and is what the documentation points at first. A delete of something
  already gone records `deleted: false` rather than failing, so a re-run stays green.
- **A credential is emitted once**, into a spec marked sensitive, which swamp vaults. Listing a token or a key
  afterwards says it exists and when it expires, never what it is.
- **A password is never an argument.** A person sets their own from the link `passwordResetLinkCreate` mints.

The suite lives in the extension at `smoke/`: sixteen batches, around 180 checks against a throwaway instance, the
large majority negative — a `confirm` that does not match, a delete of something already gone, a token id
belonging to nobody, a human where a machine was meant, credentials missing or doubled or malformed, a converge
that must not clobber the rest of a client, a project named `Prosjekt æøå / test`, the cascade when a user with a
grant is deleted, an execution with no condition, a project grant taken back with the wrong name, settings writes
refused before the API sees them, an authentication factor nobody has, more than a page of users and projects, and
a swamp workflow run twice.

`smoke/workflow-zitadel-selftest.yaml` is the decision-015 shape as a real swamp workflow — project, both groups,
the kubelogin client, the service user, the grant, and five assert steps wired with `data.latest`. It runs, and on
a second run every resource reports `unchanged`. That is the closest thing to a rehearsal of this plan's step 2
that exists without touching the real instance.

## What is left

1. **A service user in Zitadel.** Done 2026-10-01, and not as first written. A permanent key with `ORG_OWNER` in
   the `infra` vault would have been the Omni operator key again, so the credential is a tier 2 item: a session
   mints a key that expires (`docs/plans/2026-09-credential-tiers.md`, "Zitadel"). The reader is
   `fabrikk-infra-<operator>-reader` with `IAM_OWNER_VIEWER`. The operator is `fabrikk-infra-<operator>-operator`,
   owner of the projects in `ZITADEL_PROJECTS`.
2. **The key where the models find it.** Done 2026-10-01: `task admin:zitadel-key` writes
   `~/.config/zitadel/fabrikk-infra-reader.json`, and nothing goes in the vault.
3. **Publish and pull.** Done: 2026.09.29.2, then 2026.10.01.1, which expands a leading `~/` in `keyJsonFile`.
   2026.10.01.2 names grants as `ensure` does and reads a `basic` auth method.
4. **Model definitions.** Done (`dd7fcc4`, then `fc133d1`), under `models/@dataverket/zitadel/`, one per type, all
   pointing at `https://zitadel.dataverket.org` and `keyJsonFile: '~/.config/zitadel/fabrikk-infra-reader.json'`.
5. **Verify against the instance.** The read methods are done, below. Left: the write path on a throwaway
   project, walking the deletes back down and checking that a wrong `confirm` is refused and `dryRun` changes
   nothing. It needs the operator key, with the throwaway project added to `ZITADEL_PROJECTS` for that session,
   and each write approved first.

## What ran on 2026-10-01

Against `https://zitadel.dataverket.org`, Zitadel 4.15.3, with the reader key and 2026.10.01.1:

| Type | Read methods that ran |
|---|---|
| `org` | `get`, `list`, `managerList` |
| `project` | `list`; `get`, `roleList` and `projectGrantList` on three projects |
| `app` | `list` on three projects, `get` on two applications, `keyList` |
| `user` | `list`, also machines only; `get`, `patList`, `keyList` and `metadataList` on a person and a machine; `authFactorList`, `idpLinkList` |
| `grant` | `list`, also narrowed to one project and to one user |
| `action` | `list`, `executionList`, `catalog` |
| `settings` | `read` for the organization and for the instance |

None of them met an API mismatch on 4.15.3. `IAM_OWNER_VIEWER` was enough for all of it, the instance-level
reads included. A project, an application, a user and a target that do not exist each failed with a message that
names them. `action get`, `action keyList` and `projectGrantMemberList` had nothing to read, since the instance
has no targets and no project grants, so only their not-found paths ran.

Three things the reads found:

- **`grant list` named its records by id** while `ensure` names them by username and project. Fixed in
  2026.10.01.2: both use the names, and an id stands in only where Zitadel sends none.
- **An application's `authMethod` read as nothing when it was `basic`**, because Zitadel omits a default. Fixed in
  2026.10.01.2, for OIDC and API applications.
- **The chart made an owner at install.** A machine user `iam-admin` with a key and a token valid until
  2029-01-01, in Secrets `iam-admin` and `iam-admin-pat` in the `zitadel` namespace. No workload uses them.
  `task admin:zitadel-bootstrap` uses the key once per instance. Whether the key then moves to
  `vaults/operator/break-glass/` and the token is revoked is not decided.

The write path has been walked on a throwaway Zitadel 4.15.3 in podman, not on the real instance: the operator
key added an application and a role to a project it owns and was refused on every other project, and `ensureOidc`
made the login application and reported `unchanged` on a second run.

One write was tried on the real instance by mistake: `project ensure` with the reader key, to show it is refused.
It was refused, and a project list afterwards showed nothing new.

## What is still untested

**The write path on the real instance**, as step 5 says.

**The smoke suite on 2026.10.01.1 and 2026.10.01.2.** It was not run again for either. The two fixes were checked
on the real instance from the registry: the grant is stored as `grant-linus-dataverket-org-zitadel` and Forgejo's
client reads `basic`. The record `grant list` wrote under the old id name is still in the datastore beside it.

Also out of scope and untried: SAML applications, instance-wide policy writes through the v1 Admin API (deliberate:
a key that can read every policy is smaller than one that can weaken them), identity providers and login
policies, and the MFA registration flows, which need the person present anyway.

## Not in this plan

The Kubernetes identity work itself. The project, the kubelogin application and the two groups of decision 015 are
created *with* this extension, in that plan, once its overlay exists — not here.
