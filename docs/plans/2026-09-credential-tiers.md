# Plan: credential tiers

Written 2026-09-27 from the live repository (the model definitions, `vaults/`, `.sops.yaml`, the vault audit trail)
and from the swamp host as it stands (`~/.config/sops/age/keys.txt`, `~/.config/openstack/clouds.yaml`,
`~/.kube/config`, `~/.talos/config`), read against swamp 20260918's vault and access-control design documents. The
rule it applies is decision 001; the request model that generalises tier 1 afterwards is
`docs/plans/2026-09-access-requests.md`, and the second door is `docs/plans/2026-09-break-glass.md`. Every step
here is applied, on 2026-09-29, bar the CI wiring noted in step 10.

The premise: the config files on the swamp host are trusted. A process on that host, an agent included, could
read them directly, by permission or by mistake. That is accepted, and invariant 2 is what bounds it: everything
readable there expires within the working day. What the tiers buy is that no model definition, workflow, data
record or log ever carries a secret, that every secret has one named owner and one named producer, and that the
later move to `swamp serve`, where grants and the audit log live, changes where a tier 2 file sits and nothing
else.

## Invariants

Decision 001 states these and why; they are repeated here in one line each because everything below cites them.
A step that breaks one is wrong even where it is convenient.

1. **A tier 1 secret is never on disk.** A value may live in this repository only if reading it requires one of
   the mechanisms; a reference to where a value lives may live here always.
2. **Tier 2 is on disk and always expires.** Anything permanent is tier 3 with a named human owner instead.
3. **Tier 2 never enters the swamp vault.** That would put the key to tier 3 inside tier 3.
4. **Agents reach tier 2 by using it, never by reading it.** Never an argument, a data record or a log line.
5. **Tier 3 is what processes hold.** The vaults, the Flux files and the cluster's live Secrets alike.

## The three tiers

| Tier | What | Decrypted or read by | Where it lives | Made by |
|---|---|---|---|---|
| 1 | The code and procedures that turn an external login into tier 2 | A human, with the human's own logins; never swamp | `Taskfile.yml`, `bin/`, `share/admin/`; the secrets themselves are outside this host | This repository |
| 2 | Ambient credentials, referenced by name, minted with a lifetime and never permanent | The CLIs the models wrap: `openstack`, `kubectl`, `talosctl`, `omnictl` | The standard config files on the swamp host, mode 0600, and nowhere else | Tier 1 |
| 3 | What processes hold: machine secrets, permanent | A process: Flux in the cluster, swamp on the swamp host, the cluster itself | The `infra` vault (`vaults/infra/<key>.enc.json`), `break-glass/` for what only a person may read, the Flux files (`*.enc.yaml` under `artifacts/`, `apps/`, `infrastructure/`), and the cluster's live Secrets | A human with a YubiKey, or a workflow that mints a value and `put`s it |

### Who holds what

Three kinds of consumer use these tiers, and they meet them in different places. Writing that down is what keeps
the design from being read as if it were only about the person at the keyboard.

| Consumer | Tier 3 | Tier 2 | Tier 1 | Identity of its own |
|---|---|---|---|---|
| A human operator | Through a YubiKey, deliberately | Holds it for the working day, through the CLIs | This is theirs | Yes, at each service |
| swamp on the swamp host, and the agents that drive it | Reads the `infra` vault with the repo key | Uses the files the session wrote, by name and never by value | Never | No |
| Flux in the cluster | Decrypts the Flux files with the cluster's own key | Never | Never | Yes, the cluster's |
| A workflow or a runner that reaches the cluster | Through swamp as above | Uses the session's contexts | Never | No |

Flux is the one consumer that lives entirely inside tier 3, which is why nothing in this plan touches it: it holds
a key that never leaves the cluster and reconciles what the repository says. Everything else that runs on the
swamp host, swamp and the agents included, stands downstream of the person: it reads tier 3 for the tokens a
process consumes, and it uses tier 2 by name for everything that talks to a cluster or a cloud.

That leaves one property worth naming rather than discovering. Swamp has no identity of its own here. It acts
inside whichever session is open, so Omni's log names the service account, the swamp audit names the model and the
method, and the person who joins them is whoever opened the session. That is honest while a human is at the
keyboard and it is exactly what `swamp serve` is for: a server identity, a grant per method, and an audit log that
does not need the join. Until then, an agent can do whatever the open session can do, which is the strongest
argument for asking for `read` when `read` is what the work needs.

### The cluster masterkey

Yes for the everyday one, no for the one that survives Omni. The kubeconfig that holds `system:masters` on
`dataverket-prod` is tier 2: Omni mints it against its own PKI, it lands in `~/.kube/config` as context
`dataverket-prod-admin`, it expires with the rest of the session, and Omni's log says who asked for it. Its power
is not what decides its tier. The line is minted and expiring against held and permanent, and the same reading
puts the Omni service account keys, the talosconfig and the application credential on the tier 2 side.

What cannot be tier 2 is the material that mints those, and anything signed from it that works when Omni does
not: the Talos PKI in the cluster, an `os:admin` talosconfig signed from it, and the cluster's own SOPS age key.
They carry CA-signed certificates or raw key material with no lifetime worth the name, so by invariant 2 they are
tier 3, with a named human owner, and what is extracted from them goes in `break-glass/` behind the two YubiKeys.
A cluster therefore has both: a permanent root in tier 3 that only a human with a touch can reach, and a minted
admin credential in tier 2 that everything else uses.

### The second door is a separate plan

This plan removed the long-lived Omni Operator key from the vault, which sharpened something that was already
true: every administrative path into `dataverket-prod` runs through Omni, and the nodes carry no address that
Omni is not part of. That matters more than an outage would suggest, because Omni is not part of future designs:
Dataverket will build its own, and everything in tier 2 is minted by the thing being replaced.

So the second door is its own plan, `docs/plans/2026-09-break-glass.md`: a WireGuard interface in the Talos
machine config for the route, and an `os:admin` talosconfig signed from the cluster's own CA for the credential.
What this plan keeps is the place the result goes, `break-glass/`, and the rule about what may go there.

### What the invariants change here

Three things in this plan were written before the invariants and do not survive them.

**The Omni operator service account key leaves the vault.** It is in `vaults/infra/omni/` today, it lives a year,
`omni-cluster` reads it with `vault.get`, and it can mint tier 2 and change every cluster. That is exactly the
cycle invariant 3 forbids: the host's vault key opens tier 3, tier 3 hands out cluster admin, cluster admin reads
the rest of tier 3. Under the invariants it becomes a tier 2 item of its own, `swamp-fabrikk-infra-operator`,
minted with `--role Operator --ttl $TIER2_TTL` into a key file beside the reader key, and `omni-cluster` names the
file. A task of its own mints it, deliberately, when you are about to change a cluster; `admin:renew` leaves it
out, so an ordinary session holds no key that can change a cluster, and `task admin:logout` removes it. The
request model in `docs/plans/2026-09-access-requests.md` later makes that follow from asking for `admin` rather
than from remembering to run a different task. Nothing unattended uses `omni-cluster` today, so the
move costs nothing now. The old vault entries, `omni/operator_service_account_key` and
`omni/service_account_key`, are then deleted rather than renamed.

**The reader key file stops being an improvement and becomes required.** Step 4's `serviceAccountKeyFile` argument
is what lets a model name a tier 2 file instead of pulling a value out of tier 3, so steps 4 and 5 are the ones
that make invariant 3 true; until they land, every omni and talos method breaks it on every run. The interim named
in step 4, the key in the swamp process's environment, breaks invariant 4 as well and is a stopgap for hours, not
days.

**Unattended work is bounded by the session.** `workflow-fabrikk-runner` talks to the cluster through context
`dataverket-prod-admin`, which is tier 2, so it can only run while a session is current, and a nightly job is not
possible under these invariants without a different answer: a machine identity of its own under `swamp serve`,
with its own short-lived credential and its own audit, not a longer-lived file on this host. That answer is not
in this plan, and until it exists, unattended means read-only or nothing.

### Tier 1: the session, and the code behind it

| Produces | Root identity | Mechanism | Where the code goes |
|---|---|---|---|
| clouds.yaml cloud `fabrikk-infra` | The operator's own OpenStack login: the clouds.yaml entry that reaches our Keystone, found rather than named, `OS_CLOUD` when there is more than one | `openstack application credential create`, then write the entry | `task admin:openstack` |
| kube contexts `dataverket-prod-readers`, `dataverket-prod-admin` | The operator's own Omni login | `omnictl kubeconfig --cluster dataverket-prod --service-account --user swamp-fabrikk-infra-<role> --ttl <d>`, readers with `--groups fabrikk-readers` | `task admin:kube-admin`, `task admin:kube-readers` |
| talos context `dataverket-prod` | The operator's own Omni login | `omnictl talosconfig --cluster dataverket-prod`, renamed to the cluster and merged into `~/.talos/config` | `task admin:talos` |
| The Omni reader key file | The operator's own Omni login | `omnictl serviceaccount create swamp-fabrikk-infra-reader --use-user-role=false --role Reader --ttl $TIER2_TTL`; renewal is destroy and create, because `serviceaccount renew` ignores `--ttl` | `task admin:omni-key` |
| The Omni operator key file | The operator's own Omni login | `omnictl serviceaccount create swamp-fabrikk-infra-operator --use-user-role=false --role Operator --ttl $TIER2_TTL`, into a key file, never into a vault | `task admin:omni-operator-key`, run deliberately, outside `admin:renew` |
| The break-glass talosconfig | The cluster's own Talos CA, reached with an Operator key | Signed offline and stored in `break-glass/` | `docs/plans/2026-09-break-glass.md`, by hand: permanent, so tier 3, and not a task |

A *session* is the unit this plan keeps using: the stretch of a working day in which an operator has logged in
and tier 2 exists. It is opened on purpose, it holds every credential for the same lifetime, and it ends by being
closed or by expiring. The Proton Pass session, the shell `admin:shell` may open and the Omni login key are not
other meanings of the word but parts of this one, opened inside it and closed with it.

Tier 1 is a Taskfile. `Taskfile.yml` at the root includes `taskfiles/admin.yml`, and its tasks are the whole of
tier 1: `task --list` is the list of what an operator does here. `admin:login` and `admin:logout` open and close
the session, `admin:status` reports what tier 2 holds, and one task per tier 2 item acquires it: `admin:omni-key`,
`admin:kube-admin`, `admin:kube-readers`, `admin:talos`, `admin:openstack`. `admin:renew` runs those five in that
order, after `admin:due` has said once whether any of them is due. Behind each task is one executable in `bin/`,
named after it, over `share/admin/admin.sh` and one function file per topic (`logging.sh`, `omni.sh`, `kube.sh`,
`talos.sh`, `openstack.sh`). The Taskfile holds the names, the order, the descriptions and what this repository
administers, and no logic at all: anything that needs a conditional, a loop or a computed value is a script, which
is why dueness is `bin/due` and not a template expression. Nothing under `bin/` or `share/admin/` names this
cluster, this Omni or this cloud, so the code is the same code a second repository would run. A namespace per group
leaves room for the other commands this repository will grow, `bootstrap` first.

The tasks take no options. Every setting is an environment variable, `RENEW=1` to force the session, `DEBUG=1` to
print every external command, `TIER2_TTL` for the lifetime, `OS_CLOUD` for the entry you log in with, so that one
spelling works from a shell, from a task and from whatever later calls the same thing.

What this repository administers, though, is not a setting at all, and it is held one level up.
`taskfiles/admin.yml` sets
`SWAMP_REPO`, `CLUSTER`, `OMNI_CONTEXT` and `OS_CLOUD`, and that is the whole of what another repository would
change while reusing `bin/` and `share/admin/` unchanged. The scripts require all four and default none of them,
so a missing value stops a run instead of pointing it at somebody else's cluster; a shell that exports one wins
over the Taskfile, which is how an operator whose own config uses other names gets their way.

All four are names, and none is an address. The tasks pass `omnictl --context` and `openstack --os-cloud` and let
each CLI read the address, and the identity behind it, out of the operator's own config file, exactly as the
kubernetes and talos models name a context and let `kubectl` and `talosctl` do the same. That is the one shape
this design has for reaching a service, and the earlier draft had two: the Omni instance was a URL in the code
and the cloud was found by matching a Keystone address against `clouds.yaml`, which is not what `OS_AUTH_URL`
means to anyone who knows OpenStack. A URL now appears in three places only: each operator's two config files,
and the README that tells a new operator what to put in them.

What is checked is therefore not an address but a kind. The entry you log in with must exist, must not be the
entry this repository writes, and must not be an application credential, which is a machine's credential and
never a person's. The same for Omni: the named context must exist, and its URL is read from it for the service
account calls, which ignore the omniconfig and take the address from `OMNI_ENDPOINT`.

`admin:shell` is `admin:login` with `SESSION_SHELL=1`: it ends in a shell where `OS_PASSWORD` is resolved from
Proton Pass by `pass-cli run`, so inside it nothing prompts; without it the password is resolved for the length of
one script's run and nowhere else. `admin:logout` closes the Proton Pass session and removes the Omni login key,
and leaves tier 2 to expire by itself.

Each task announces the files it reads and may write, checks its own state, keeps what is current, and can be read
and run alone. Every tier 2 item shares one lifetime, `TIER2_TTL`, 8 hours by default, and one renewal window, a
quarter of it. `admin:due` names the items that are due or absent and prints 1 or 0; `admin:renew` reads that one
answer and hands it to all five, so they are renewed in the same session, expire together, and the operator logs
in once at the start of the working day. `RENEW=1 task admin:renew` forces the session. Together the tasks are
first setup, rotation and recovery. They run as the operator on the swamp host with the operator's own logins,
Omni in the browser and OpenStack through your own clouds.yaml entry, need `task`, `omnictl`,
`kubectl`, `talosctl`, `openstack`, `jq` and `yq`, all of them in the repository's `Brewfile`, and write files
with mode 0600. They never read or write the swamp vault and do not need swamp on PATH: a tier 1 script that
needed a tier 3 value would make the host's vault key a root credential, and that is the thing tier 1 exists to
avoid. What swamp needs in tier 3 is put there by hand in step 7.

The tasks never replace what they did not create. A kube context that exists and is not a token for the
script's own service account (another subject, an OIDC user, a client certificate), a talos context that is not
Omni-proxied or carries a certificate, or a cloud entry whose credential does not carry the `swamp-<repo>-` prefix,
is hand-made: the task names it, leaves it alone, does not count it as due, and says how to hand it over (delete
the context, or remove the entry, and rerun). Only entries that carry the scripts' own names are renewed,
replaced or deleted. An expired credential of ours cannot read its own record, so `admin:openstack` looks it up as
you before deciding, which is what makes the first run of a day work.

Tier 1 itself lives for a working day at most, because it only ever acquires tier 2 and does no operations of
its own. The Omni browser login is a PGP key that Omni issues for four hours (`~/.talos/keys/<context>-<you>.pgp`,
expiry inside the key). The OpenStack password is typed once per run, kept in that process's environment and
never written; the Keystone token behind it lasts an hour and is not cached. Nothing in tier 1 is a file that
outlives the session, and that is what allows tier 1 to hold the powers tier 2 must not.

Invariant 1 is about the secret, not about every byte a login leaves behind, and it is worth being exact about
what does land here. The passwords and passkeys are in Proton Pass and on the YubiKeys, and this host never sees
them. What the host holds is the Omni login key above and the Proton Pass session the CLI keeps, both artifacts of
a login that a person completed in a browser, both revocable at the far end, both removed by `task admin:logout`.
That is the whole of tier 1 on disk, and the thing that must stay untrue is a file or a vault entry from which a
tier 1 login could be reconstructed without a person: a Proton Pass personal access token, a stored password, an
Omni service account with the user's own role. The first is the reason `pass-cli` tokens are refused, the last is
why every service account this repository mints passes `--use-user-role=false`.

Behind both logins stands Proton Pass, where the Omni and Nexthop web credentials live. That makes the Proton
Pass session the root of tier 1: Omni's credential is filled by the browser extension, and OpenStack's reaches the
scripts as `OS_PASSWORD`, typed once per run or handed over by `pass-cli run` from a `pass://` reference for the
duration of that one process. The CLI's personal access tokens are not used; a token that lets `pass-cli` answer
without a person present would make tier 1 unattended, which is the property the tiers exist to prevent.

### Tier 2: files by name, presumed present

A model definition names a context and nothing more. No `vault.get`, no path to a key, no environment variable
that holds a value. If the file is missing the CLI fails and the method fails with it; the models do not check for
tier 2, tier 1 does.

| Tool | File | Name the models use | Content | Lifetime |
|---|---|---|---|---|
| `openstack` | `~/.config/openstack/clouds.yaml` | cloud `fabrikk-infra` | An application credential named `swamp-fabrikk-infra-<timestamp>`, `member` role or the roles of the one it replaces | The shared tier 2 lifetime, 8 hours |
| `kubectl` | `~/.kube/config` | context `dataverket-prod-readers`, context `dataverket-prod-admin` | An Omni service-account kubeconfig, token signed by Omni, validated by Omni's Kubernetes proxy | The shared tier 2 lifetime, 8 hours |
| `talosctl` | `~/.talos/config` | context `dataverket-prod` | The Omni-proxied talosconfig, which carries no credential of its own | No credential, so nothing to expire; the key file beside it is what has a lifetime |
| `talosctl`, `omnictl` | `~/.talos/omni/swamp-fabrikk-infra-reader.key`, beside the omniconfig | the file, through the type's `serviceAccountKeyFile` argument (step 4) | An Omni service account key, `Reader` role | The shared tier 2 lifetime, 8 hours |
| `omnictl` | `~/.talos/omni/swamp-fabrikk-infra-operator.key`, beside the reader key | the file, the same argument, named only by `omni-cluster` | An Omni service account key, `Operator` role | The shared tier 2 lifetime, minted deliberately and not by `admin:renew` |

Two of these are already in place under other names: cloud `fabrikk-infra` and the kube contexts `fabrikk-readers`
and `dataverket-prod-admin`. Naming is `<cluster>-<role>` for kube contexts, `<cluster>` for the talos context, and
`swamp-<repo>` or `swamp-<repo>-<role>` for anything created in a provider on this repository's behalf, so that the
provider's own listing says who owns it.

Scope follows the role, not the tool. The readers kubeconfig binds to the `fabrikk-readers` group and nothing more;
the admin kubeconfig is `system:masters`. Both live as long as everything else in tier 2, because one lifetime
means one session; the admin context is not shorter. The Omni reader key can list machines and fetch talosconfigs
and can change nothing, and it is in every session. The operator key that can change things is tier 2 as well,
under the same lifetime, but it is minted by a task of its own when a change is about to be made, and it goes at
logout, so an ordinary session holds no key that can mutate Omni. Tier 1 itself never uses either: it runs on the
operator's own login.

The Omni case needs one sentence more. An Omni-issued talosconfig authenticates with whatever `talosctl` finds in
`OMNI_SERVICE_ACCOUNT_KEY`, so today the talos and omni model definitions pull an Omni key out of the vault on
every run, which is the clearest breach of invariant 3 in the repository. Under the plan they name a key file
instead: the reader key for everything that only looks, the operator key file for `applyPatch`, `addMachine`,
`removeMachine`, `reset` and `upgrade`, which is the one file a session mints deliberately. Neither is a vault
value, and a method that cannot find its file fails rather than falling back to one.

### Tier 3: one key per decrypting process

Every tier 3 store is encrypted to the process that decrypts it plus the two operators' YubiKeys, and to nothing
else.
A process key is named after the process, and the name is what `.sops.yaml`, the vault config and this plan call it.

| Key name | Identity | Where the private key is | Decrypts |
|---|---|---|---|
| `cluster-dataverket-prod` | `age1g3x9w…` | Secret `flux-system/sops-age`, generated in-cluster, never leaves it (decision 003) | The Flux files |
| `swamp-fabrikk-infra` | `age15d64a…` | `~/.config/sops/age/keys.txt` on the swamp host | The `infra` vault |
| `beddari`, `linus` | `age1yubikey1…` | The YubiKeys | Both, for recovery, re-keying and writes from a terminal |

The rule that follows: the cluster key is never a vault recipient and the repo key is never a Flux recipient. That
is already true in `.sops.yaml`; the plan makes it a stated invariant and gives the repo key its name. A second swamp
repository gets a second key, `swamp-<repo>`, never a copy of this one.

The vault holds today: the forge token, the GitHub mirror token, the registry push credential (copied from the
cluster, decision 006), the runner registration token, two Omni service account keys, and two Kubernetes Secret
payloads the release runner writes. Both Omni keys leave: they mint tier 2 and change clusters, which invariant 3
puts outside tier 3 altogether. What stays in `infra` is what a process consumes and nothing that opens a door.

**Break-glass values are tier 3 with a smaller recipient list, and no vault at all.** The `@dataverket/sops` vault
encrypts every value to the vault's whole recipient list, so a value only a human may read cannot sit in `infra`.
It does not go in a second vault either: a vault is a thing a definition can name, and `vault.get("human", …)` is
a line someone could write. `break-glass/` is plain sops instead, outside `vaults/`, with the two YubiKeys as its
only recipients. Nothing swamp runs can name it; encryption needs only public keys, so a workflow can still write
there, and only a touch reads it. It is empty until the break-glass plan fills it.

### The two stores never share a reader

The cluster key is never a recipient of a vault file and `swamp-<repo>` is never a recipient of a cluster file. A
value that has to exist in both stores is copied by a human with a YubiKey, from the store where it was born to
the other, and the commit says so. The origin is the source of record and rotation starts there. Which store is
the origin follows from who consumes the value: a credential the cluster uses is born as a cluster manifest, one
only swamp uses is born in the vault and never touches a cluster file, and one both use is born wherever it is
created, the registry push credential in zot's manifest, a token a workflow mints in the vault. Decision 006's
direction, cluster repository first and the factory copies, was about two repositories; inside this one it reads
as "origin first".

Swamp can still write a cluster file, because encryption needs only public keys, and it reads the vault on every
run. What it cannot do is move a value from one store to the other, or run `sops updatekeys` over cluster files
when a cluster is added or an operator leaves. Those stay human steps, and `bootstrap.sh` already stops and says so.

Stated at its true size, the rule bounds three things. A leaked swamp key opens the vault files, which are mirrored
to codeberg with the rest of the repository, but not the cluster manifests beside them. Re-keying after such a leak
is the vault alone, not every encrypted file. And the copy stays rare and reviewed because a person does it.
The rule does not keep the swamp host from reading a live cluster Secret: an admin kubeconfig reaches every
Secret through the API, and a minted Operator key reaches the PKI behind it. Live Secrets are tier 3 too
(invariant 5), so what actually bounds this is not the recipient rule but invariant 2: the credentials that open
that door are minted, short-lived and logged at Omni. The README today claims the larger thing; step 9 corrects it.

The rule is written down in five places and checked in one, so that it does not depend on anyone remembering it:
decision 002, the README's Secrets section, the header of `.sops.yaml`, an operator-rules section in `CLAUDE.md`
and `AGENTS.md` for the agents that work here, and `bin/check-recipients`, which reads the recipient list out of
every encrypted file and fails when a key appears on the wrong side. Steps 8 to 11, all done 2026-09-29.

## Steps

1. **Name the repo key and close its permissions.** Done 2026-09-29. `chmod 600 ~/.config/sops/age/keys.txt` (it is
   0664 today).
   Add a `# name: swamp-fabrikk-infra` line beside `age-keygen`'s `# public key:` comment. Rewrite the recipient
   comments in `.sops.yaml` and the Secrets section of `README.md` with the names in the tier 3 table.
2. **Turn on read auditing.** Done 2026-09-29. `auditReads: true` in `vaults/@dataverket/sops/29f189c7-….yaml`. Every
   `vault.get`
   then leaves a line in `.swamp/audit/vault-audit-<date>.jsonl` naming the model and method, and
   `swamp vault audit-trail --action get` shows which definitions still reach into tier 3. That list is the
   checklist for step 5.
3. **Create the `break-glass/` store.** Done 2026-09-29. Plain sops, not a swamp vault: a vault is addressable
   by a definition and this must not be, so it is a directory with a rule in `.sops.yaml` naming the two YubiKeys
   and nothing else. That rule goes first, because sops takes the first match and the general `vaults/` rule would
   otherwise add `swamp-fabrikk-infra` to a human-only file. `break-glass/README.md` says what may go in it: one
   source of human-only material among several, the one that travels with this repository, permanent break-glass
   and recovery material, never a value that completes a routine login. Empty until step 7.
4. **Extend the omnictl and talosctl types** in `dataverket/swamp-extensions` with a `serviceAccountKeyFile`
   global argument, read at call time and exported as `OMNI_SERVICE_ACCOUNT_KEY` to the child, mutually exclusive
   with `serviceAccountKey`. Done 2026-09-29, published as `@dataverket/omnictl@2026.09.29.1` and
   `@dataverket/talosctl@2026.09.29.2` and pulled here. `talosctl` also gained `talosContext`, so a definition
   names the context it targets instead of inheriting whichever one was selected last. The interim the step
   allowed for, the key in the swamp process's environment, was never needed.
5. **Move every Omni-reading model to tier 2.** Done 2026-09-29. `omni` and `dataverket-prod-talos` name the
   reader key file; `omni-cluster` names the operator key file, which `task admin:omni-operator-key` mints
   deliberately and `admin:renew` leaves alone, so no model reads an Omni key out of the vault and an ordinary
   session holds no key that can change a cluster. The kubernetes and openstack models already name contexts and a
   cloud. Verified by running `omni discover` and `dataverket-prod-talos version` against the key files, and then
   by the audit trail with step 2 in place: both ran and the trail recorded no vault read at all. What is left in
   the definitions is the forge, codeberg, GitHub and registry tokens, all of them values a process consumes.
6. **Run `task admin:renew`** once. Done 2026-09-29; the hand-made contexts, the backup kubeconfig and the
   stale contexts are gone, and no definition names the old readers context. As written: after reading
   `taskfiles/admin.yml` and the scripts in `bin/`. It creates the
   reader service account, the two kubeconfig contexts under their new names, merges the talos context, creates the
   application credential through your own clouds.yaml entry and writes the `fabrikk-infra` cloud, and touches
   nothing it did not create. Today's hand-made admin context and `fabrikk-infra` credential stay until you delete
   them; `task admin:status` reports them on every run. Rename the
   `fabrikk-readers` context to `dataverket-prod-readers` in the definitions that use it in the same change. Delete
   `config.bak-2026-09-17` and the dev-cluster and talos-default contexts that no model uses.
7. **The human steps, once.** Done 2026-09-29. Both Omni keys are deleted from the `infra` vault and both
   unnamed service accounts are destroyed in Omni, so the only service account that exists is the reader one a
   session mints. The break-glass fetch that used to be part of this step has moved to
   `docs/plans/2026-09-break-glass.md`, which does not depend on Sidero enabling anything.

8. **Write the decision down.** Done 2026-09-29 as `docs/decisions/002-two-sops-stores-one-reader-each.md`:
   one key per decrypting process, named after it; neither key a recipient of the other store's files; a value
   that must exist in both copied by a human with a YubiKey, from the store where it was born, with the commit
   naming the copy. The whole set of decisions was renumbered the same day, so this one is 002 and the tiers
   themselves are 001; `docs/decisions/README.md` maps the old numbers.

9. **README, Secrets section.** Done 2026-09-29. Three changes. The recipients table names the keys
   (`cluster-dataverket-prod`, `swamp-fabrikk-infra`, the operators) instead of describing them. The sentence "the
   swamp host is not, so no unattended process can read a cluster secret" becomes what the rule delivers: the
   host's key opens no cluster file, so a leak of it costs the vault and not the manifests, and a live Secret is a
   different door. A new short paragraph, "Moving a value between the stores", says who does it, with what, that
   the origin store is the source of record and the direction follows from it, and that the commit message says so;
   it points at decision 002 and at the check in step 10. The 005 sentence at the end of the section is rewritten
   the same way.
10. **`.sops.yaml` and the check.** Done 2026-09-29. Each identity is declared once as a YAML anchor under a
    top-level `identities:` key that sops ignores, and every rule names it by alias inside `key_groups`, whose
    `age:` is a list, so a recipient list reads as names. Verified by encrypting one file per rule and reading
    back who it went to: `break-glass/` to the two operators, a Flux file to `cluster-dataverket-prod` and
    the two operators, a vault file to `swamp-fabrikk-infra` and the two operators. `bin/check-recipients` reads the
    identities and the rules, matches every `*.enc.yaml` and `*.enc.json` to the first rule that matches its path
    as sops does, and compares. It decrypts nothing, so it runs unattended with no YubiKey. `bootstrap.sh` runs it
    as its first step and `admin:renew` before it mints anything; `task check-recipients` runs it by hand. Proved
    against both failures it exists for: a vault file with the cluster key added, and a file no rule covers. The
    `fabrikk-runner` workflow and a pull-request check are still to do; this repository has no CI configuration
    yet.
11. **Operator rules for agents.** Done 2026-09-29. A section after the swamp-managed block in `CLAUDE.md` and
    `AGENTS.md`, four
    lines: never add a recipient to `.sops.yaml` or a vault's `agePublicKey`; never run `sops updatekeys`; when a
    task needs a value that lives in the other store, stop and give the human the exact `sops` or
    `swamp vault put` command to run; definitions name contexts and vault keys, never values.

## Rotation

| What | Lifetime | Renewed by | Signal |
|---|---|---|---|
| Every tier 2 item: admin and readers kubeconfig, Omni reader key, application credential | 8 h, one lifetime (`TIER2_TTL`) | `task admin:renew`, all in one session when any has less than a quarter of its lifetime left, or on `RENEW=1`; the old application credential is deleted after the new entry answers | `task admin:status` lists each item's owner and remaining time; before that, a model's CLI fails to authenticate |
| Omni operator key | The shared tier 2 lifetime | `task admin:omni-operator-key`, before changing a cluster; never by `admin:renew` | `task admin:status` lists it when present; `omnictl serviceaccount list` shows the expiry |
| Break-glass talosconfig, `break-glass/` | Until the Talos CA is rotated | Never; using it obliges a CA rotation and a re-mint | `docs/plans/2026-09-break-glass.md` |
| Repo key `swamp-fabrikk-infra` | Until the host is rebuilt | A human: new key, `sops updatekeys` over `vaults/infra/`, new name if the repo moves | Never automatic |
| Cluster key `cluster-dataverket-prod` | The cluster's life | `bootstrap.sh` on a new cluster (decision 003) | A new cluster |

For tier 2 the signal is `admin:status`, which reads the expiry out of each kubeconfig token, the service account
listing and the credential's own record, in one place. For tier 3 the signals are still "the next run fails",
which is acceptable while a human runs the models.

## Not in this plan

- `swamp serve`, server tokens, grants and the chain-hashed audit log. When serve arrives it runs as its own user
  on the swamp host, that user owns the tier 2 files and the repo key, and agents hold a server token and
  nothing else. The tiers do not change.
- Isolating agents from the swamp host's files. The premise above accepts that they can read them.
- A credential broker or `exec` plugins in the kubeconfig. Omni's service-account kubeconfig makes the file itself
  short-lived, which is enough for now.
- OpenStack access rules on the application credential. Worth doing when the openstack models' method list is
  stable; today it would be rewritten with every extension release.
- The hov1 site's credentials, which the backup plan owns.
- The request model, the service list and the mechanisms as a pluggable set: `docs/plans/2026-09-access-requests.md`.
- The second door, its route and its credential: `docs/plans/2026-09-break-glass.md`.
- Bare metal. The metal under the cluster is the provider's, which is the shape Dataverket is built around, and
  our root begins at the OpenStack API, so there is
  no third root identity to acquire and nothing below the cloud for tier 1 to reach.
