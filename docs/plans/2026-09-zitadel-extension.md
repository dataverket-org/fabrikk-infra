# Plan: a swamp extension that administers Zitadel

Written 2026-09-29. The extension is built, unit tested, and exercised against a throwaway Zitadel 4.19.3 in
podman. It is published as `@dataverket/zitadel` 2026.09.29.2 and pulled here, and seven models name it. What is
left is the service-user credential for the real instance, which only a person can mint, and the verification
that follows it.

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

1. **A service user in Zitadel**, minted by a person: a machine user with `ORG_OWNER` (or `ORG_PROJECT_CREATOR`
   plus `ORG_USER_MANAGER` for a key that only provisions), and a JSON key downloaded from its page.
2. **The key into the vault**, by the person who downloaded it, since a value never reaches an agent's argument:

   ```sh
   swamp vault put infra zitadel/key_json "$(cat ~/Downloads/<the key>.json)"
   ```

   Or keep it out of the vault entirely and let the definitions name the file with `keyJsonFile`.
3. **Publish** `swamp extension push manifest.yaml --yes` from `~/kode/swamp-extensions/zitadel`, then
   `swamp extension pull @dataverket/zitadel --yes` here. Done: 2026.09.29.2.
4. **Model definitions**, done (`dd7fcc4`), under `models/@dataverket/zitadel/`, one per type, all pointing at
   `https://zitadel.dataverket.org` and `${{ vault.get('infra', 'zitadel/key_json') }}` — quoted arguments,
   which is the spelling `swamp model validate` recognizes.
5. **Verify against the instance**: the read methods first, then the write path on a throwaway project, walking
   the deletes back down and checking that a wrong `confirm` is refused and `dryRun` changes nothing. The same
   suite runs against a real instance by pointing the models at it, though the destructive batches want a project
   of their own.

## What is still untested

**The version the cluster runs.** Chart 10.0.4 pins Zitadel **v4.15.3**; every live run here was against v4.19.3.
All four API mismatches above were version-specific behaviour, so the first thing to do against the real instance
is the read-only batches, before anything writes.

Also out of scope and untried: SAML applications, instance-wide policy writes through the v1 Admin API (deliberate
— a key that can read every policy is smaller than one that can weaken them), identity providers and login
policies, and the MFA registration flows, which need the person present anyway.

## Not in this plan

The Kubernetes identity work itself. The project, the kubelogin application and the two groups of decision 015 are
created *with* this extension, in that plan, once its overlay exists — not here.
