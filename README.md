# fabrikk-infra

The infrastructure needed to stand up a fabrikk: the forge and its runners, identity, the registry, and the platform
under them (storage, gateway, certificates, DNS) on the `dataverket-prod` cluster, applied by Flux. This is the
platform baseline (L0) for the cluster that hosts the software factory. Application overlays (L2) live in `miljo`;
product manifests (L1) live next to the code in `fabrikk`. No product is deployed from here.

This repository was `flux-bootstrap` until 2026-09-17. The forge redirects the old name until it is reused.

## Layout

| Path | Applied by | Contents |
|---|---|---|
| `clusters/production/` | `flux bootstrap` | The Flux system and the two root Kustomizations below. |
| `infrastructure/` | Kustomization `infrastructure` | OpenStack cloud controller and Cinder CSI, CNPG, Envoy Gateway, cert-manager and the wildcard certificate, external-dns, Kata. |
| `backup/` | `docker compose` on a site host, nothing in the cluster | The sources-and-targets table (`backup/README.md`); `versitygw/` is a compose stack, versitygw with the posix backend behind its own private CA, that runs anywhere; `<site>/` is one instance of it, `hov1/` the S3 endpoint the backups are written to. |
| `apps/` | Kustomization `apps` (after `infrastructure`) | Forgejo, its runners, Zitadel, and the pointer to zot. |
| `artifacts/<name>/` | Nobody, from git | Sources of OCI config artifacts. Pushed with `artifacts/<name>/push.sh`, pulled by an `OCIRepository` declared under `apps/`. |
| `bootstrap/` | `bootstrap.sh` | What must exist before the rest can be applied: the cluster's SOPS key, and zot from git until zot serves its own config. |
| `Taskfile.yml`, `taskfiles/` | `task` | The commands of this repository, one namespace per group, one file per namespace. |
| `bin/`, `share/` | The tasks | One executable per task over shared libraries. Nothing here names this cluster, this Omni or this cloud, so another repository reuses them unchanged (decision 008). |
| `models/`, `workflows/`, `vaults/`, `extensions/` | `swamp` | The swamp repository: the instances a human uses to operate what is deployed here. See Operating models below. |
| `vaults/operator/` | Nobody, by design | Values only a person reads, behind the two YubiKeys: plain sops with no process key and no swamp vault config (decision 016). `break-glass/` for when a login fails, `hov1/` for the hov1 gateway's CA key and root key pair. |
| `talos/<cluster>/` | swamp's Omni and Talos models, never Flux | Talos machine config patches, one file each, applied to machines below Kubernetes; `workers-storage.yaml` is the workers' disk layout and kubelet thresholds (decisions 017, 019). |
| `docs/decisions/`, `docs/plans/`, `docs/storage.md` | Nobody | Why the repository is shaped as it is, what is being changed next, and where the cluster's data lives and how its workers are replaced. `task decisions` lists the records with what is still pending. |
| `Brewfile` | `brew bundle` | Every tool `bootstrap.sh` and the tasks need, on Apple silicon and Linux x86_64 and arm64. |

## Bootstrap and recovery

`bootstrap.sh`. Every step checks state and skips what is done, so it is the fresh-cluster path, the recovery path,
and the record of both. It stops once on a new cluster, when the freshly generated SOPS recipient must be put in
`.sops.yaml` and every `*.enc.yaml` re-encrypted with a YubiKey. It needs kubectl, kubectl-cnpg, flux, sops, git,
yq, jq and a YubiKey. The reasons behind each step are in `docs/decisions/`.

A rebuild of a lost cluster runs `./bootstrap.sh --source github`: Flux reads the GitHub mirror while Forgejo is gone,
and both databases come back from the hov1 site through the `bootstrap.recovery` in git (decision 021). The order,
and the one commit that must precede it, is `docs/storage.md`, "Rebuild from git".

## Commands

`task` lists them. One namespace per group. The `admin:` group is one *session*: the stretch of a working day in
which an operator has logged in and the short-lived credentials exist, opened deliberately and closed or expired at
the end of it. The Proton Pass session, the shell it may open and the Omni login are parts of it, not other things
with the same name. It runs on the swamp host with your own Omni, OpenStack and Zitadel logins, writes the credentials the
models then use by name, touches only config files in your home directory, and never reads the swamp vault. The
rule behind it is decision 001. What comes after it, in order: the second door in
`docs/plans/2026-09-break-glass.md`, then Kubernetes authentication in `docs/plans/2026-09-kubernetes-identity.md`.
`docs/plans/2026-09-access-requests.md` generalises the session itself and depends on neither.

| Task | What |
|---|---|
| `task admin` | All three tiers as tables with the same columns: where each credential lives, the name it is selected by, who holds it and when it expires. Only tier 2 has anything in the lifetime columns, which is the design in one screen. The same as `admin:status`. |
| `task admin:login`, `task admin:logout` | Open and close the session: the Proton Pass session and the Omni login key. |
| `task admin:renew` | Every credential of ours, in order, when any one of them is due. `RENEW=1` renews them now. |
| `task admin:omni-key`, `admin:kube-admin`, `admin:kube-readers`, `admin:talos`, `admin:openstack` | One credential each, to run alone. |
| `task admin:omni-operator-key` | The one key that can change a cluster. Run deliberately; `admin:renew` leaves it out and `admin:logout` removes it. |
| `task admin:zitadel-key` | The Zitadel reader key the zitadel models name. It reads the whole instance and changes nothing. A renewal logs you in through the browser; a current key opens nothing. Part of `admin:renew`. |
| `task admin:zitadel-operator-key` | The Zitadel key that can write, and only to the projects named in `ZITADEL_PROJECTS`. Run deliberately; `admin:renew` leaves it out and `admin:logout` removes it. After changing the list, run it with `RENEW=1`. |
| `task admin:zitadel-bootstrap` | Once per instance, and on a host whose config lacks the client id: the organization's name, the admin project and the application the browser login goes through. It acts as the machine user the chart made at install, whose key it reads from the cluster for that run and writes nowhere. |
| `task check-recipients` | Every encrypted file is encrypted to the recipients its rule names, and to nobody else. `bootstrap.sh` runs it first, `admin:renew` before it mints anything. |

What a session writes, and what reads it by name:

| File | Named by | Content | Lifetime |
|---|---|---|---|
| `~/.config/openstack/clouds.yaml`, cloud `fabrikk-infra` | the openstack models | An application credential `fabrikk-infra-<operator>-<timestamp>`, role `member` | `TIER2_TTL`, 8 h |
| `~/.kube/config`, contexts `dataverket-prod-readers` and `dataverket-prod-admin` | the kubernetes and flux models | Omni service-account kubeconfigs: group `fabrikk-readers`, and `system:masters` | `TIER2_TTL` |
| `~/.talos/config`, context `dataverket-prod` | `dataverket-prod-talos` | The Omni-proxied talosconfig, which carries no credential | none; the key file beside it expires |
| `~/.talos/omni/fabrikk-infra-reader.key` | `omni`, `dataverket-prod-talos` | An Omni service account key, role Reader | `TIER2_TTL` |
| `~/.talos/omni/fabrikk-infra-operator.key` | `omni-cluster` only | An Omni service account key, role Operator; `admin:omni-operator-key` mints it, `admin:logout` removes it | `TIER2_TTL` |
| `~/.config/zitadel/fabrikk-infra-reader.json` | the zitadel models | A Zitadel machine key, `IAM_OWNER_VIEWER` | `TIER2_TTL` |
| `~/.config/zitadel/fabrikk-infra-operator.json` | a definition that writes | A Zitadel machine key, owner of the projects in `ZITADEL_PROJECTS` and of nothing else | `TIER2_TTL` |

Every item shares the one lifetime, and `admin:renew` renews them all when any has less than a quarter of it left.
`admin:status` reads each item's expiry from its own file or record. The two process keys of tier 3 never rotate on a
schedule: `swamp-fabrikk-infra` lasts until the swamp host is rebuilt, `cluster-dataverket-prod` the cluster's life.

The `decisions:` group is the records in `docs/decisions/`. `task decisions` lists them with their audit status, so
what is decided and what is still pending read at a glance; `decisions:new` starts one from the template and opens
it in `$EDITOR`; `decisions:index` rewrites the generated index.

Settings are environment variables, not options: `RENEW=1`, `DEBUG=1`, `TIER2_TTL` for the shared lifetime,
and `OPERATOR` for the name a provider records you under, which defaults to `$USER`.
What this repository administers, its cluster and the names its three logins go by, is not a setting but a fact,
and `taskfiles/admin.yml` sets it; `bin/` and `share/admin/` name no cluster and no cloud of their own.

The logins are named, never addressed, the way a kube context is: the tasks pass `omnictl --context` and
`openstack --os-cloud`, and each CLI reads the address and the identity out of your own config file. Zitadel has
no CLI, so its config is a file the tasks read themselves, in the same shape. So the addresses below are yours to
put there once, and no script here names one:

| Your file | Name the tasks use | Where it points |
|---|---|---|
| `~/.talos/omni/config` | context `default` | `https://dataverket.eu-central-1.omni.siderolabs.io`, with `omnictl config new --url <that>` |
| `~/.config/openstack/clouds.yaml` | cloud `nexthop` | `https://identity-api.nexthop.no:5000/v3`, your own Keystone login, never an application credential |
| `~/.config/zitadel/config.yaml` | context `default` | `url: https://zitadel.dataverket.org` and `login_url: https://zitadel.dataverket.org/ui/v2/login` under `contexts.default`; `task admin:zitadel-bootstrap` adds `client_id` |

If your own config uses other names, export `OMNI_CONTEXT`, `OS_CLOUD` or `ZITADEL_CONTEXT`; a shell wins over the
Taskfile.

The Zitadel login is the device flow: the task prints an address and a code, and you confirm in the browser as
yourself. The token that comes back stays in that process, is revoked when the task ends, and is never written.
`login_url` is there because Zitadel sends a device code to its old login UI, where a passkey registered in the
new one is refused.

Two operators on one cluster share every file: the same key paths, the same kube context names, the same cloud
entry, because a model definition in git names them and reads the same for both. What a provider stores under its
own name carries the operator — `fabrikk-infra-<you>-reader` in Omni and in Zitadel, `fabrikk-infra-<you>-admin` as a kube
subject, `fabrikk-infra-<you>-<timestamp>` as an OpenStack application credential — so its listing says who to ask,
and renewing yours cannot destroy theirs.

None of these names says `swamp`. You use these contexts from a terminal exactly as a swamp model method uses them,
so a name that claimed either one would be wrong half the time. The one thing still called `swamp-fabrikk-infra` is
the age key that decrypts the vault, which no person reads. When a name here does change, the tasks migrate it:
they recognise a former name as ours, mint the new one, and remove what the old one left behind.

## Names

| Name | Used by | Why |
|---|---|---|
| `registry.dataverket.org` | Everything that pushes or pulls artifacts: CI, developers, other clusters, cosign | The registry's identity (TLS through the gateway, anonymous pull, push for `fabrikk-ci`) |
| `zot.zot.svc.cluster.local:5000` | Only `apps/zot/source.yaml`, this cluster fetching zot's own config | Must survive external DNS, the LoadBalancer, or the certificate being broken (decision 013) |
| `git.dataverket.org` | Flux's `GitRepository`, humans, the push mirror to GitHub | The source of record; `github.com/dataverket-org/fabrikk-infra` is Flux's source for a rebuild (decision 021) |
| `213.128.185.82:443` | CNPG's Barman Cloud plugin, the backup writer; kopia later | The hov1 site's versitygw (`backup/hov1`), by address so no zone is in the backup path; TLS from the site's private CA, its root pinned here |

## Secrets

Three SOPS stores live here, with different readers and different recipients. One key per decrypting process,
named after the process, and the name is what `.sops.yaml`, the vault config and decision 001 call it.
`.sops.yaml` holds all three, one creation rule each, and names every recipient in its comments. Public keys only;
the file is safe to commit.

| Setup | Files | Who decrypts | Recipients |
|---|---|---|---|
| Cluster files | `*.enc.yaml` under `apps/`, `artifacts/`, `infrastructure/` | Flux, on apply, with the cluster's own key | `cluster-dataverket-prod` (Secret `flux-system/sops-age`, generated in-cluster, decision 003), `beddari`, `linus` |
| Swamp vault | `vaults/infra/<key>.enc.json`, one file per secret | The swamp models in `models/`, on every run | `swamp-fabrikk-infra` (`~/.config/sops/age/keys.txt` on the swamp host), `beddari`, `linus` |
| Operator values | `vaults/operator/**/*.enc.json` (and `.enc.yaml`) | Nothing automated. A person, with a touch | `beddari`, `linus`, and no process key at all |

**Cluster files** are Secret manifests with only `data`/`stringData` encrypted, so kind, name and namespace stay
readable and diffs stay meaningful. Flux decrypts them on apply; nothing else ever does. Charts and workloads take
secrets by reference (`existingSecret`, `secretKeyRef`, a mounted Secret), never as inline values. The humans are
recipients so that the files can be edited and re-encrypted; `swamp-fabrikk-infra` is not. What that buys is
bounded and worth stating exactly: a leak of the swamp host's key opens the vault files, which are mirrored to
GitHub with the rest of this repository, but not the cluster manifests beside them, and re-keying after such a
leak is the vault alone. It does not keep the swamp host away from a live cluster Secret: an admin kubeconfig
reaches every Secret through the API. What bounds that is decision 001's second invariant, that the credentials
opening the door are minted, short-lived and logged at Omni, not the recipient list here.

**The swamp vault** holds the credentials the operating models use (decision 005): the forge and codeberg tokens,
the GitHub mirror token, the registry push credential. Not the Omni keys: those are minted per session into a key
file the definitions name, because a credential that can mint cluster admin must not sit where the host's own key
opens it (decision 001). The `@dataverket/sops` vault type keeps one SOPS-encrypted file per secret under
`vaults/infra/`, so a write touches one file, `git log` on a file is that secret's history, and a `put` needs only
the recipients' public keys. Its recipient list lives in `vaults/@dataverket/sops/*.yaml` (`agePublicKey`) and it
ignores `.sops.yaml`; the second rule there repeats the same recipients so that `sops` on a file under `vaults/`
from a terminal encrypts to the same set. The swamp host's key is a file rather than a YubiKey, and is a recipient
so that scheduled runs decrypt unattended; it is never a recipient of a cluster file. A model whose output schema
marks a field sensitive writes into this vault too, under a generated key; `swamp vault audit-trail --vault infra`
shows who wrote what.

**Moving a value between the stores** is a human step, never an automated one. A value that has to exist in both
is copied by a person with a YubiKey, from the store where it was born to the other, and the commit message says
so. Which store is the origin follows from who consumes the value: a credential the cluster uses is born as a
cluster manifest, one only swamp uses is born in the vault and never touches a cluster file, and one both use is
born wherever it is created. The origin is the source of record and rotation starts there. Decision 002 states the
rule and `bin/check-recipients` enforces it.

**Adding an operator** is a few edits and one re-encryption: their key in all three rules of `.sops.yaml` and in
the vault's `agePublicKey`, then `sops updatekeys` on every `*.enc.yaml` cluster file and every file under
`vaults/infra/`, with a YubiKey that is already a recipient. Removing one is the same with the key taken out.

Decision 006 said the same thing about two repositories: a credential the cluster uses is authored here and the
software factory copies it, never the other way around. Inside this repository it reads as "origin first", which
is the rule above.

Not migrated yet: the Forgejo admin, mailer and OAuth secrets, the runner registration token, and `cloud.conf` are
still created by hand (see `apps/forgejo/*.example.yaml`). They move here one at a time. The Zitadel masterkey and
Forgejo's generated security keys are here since 2026-09-30, pinned, since a restore needs them (`backup/README.md`).

## Gitless delivery

`apps/zot/source.yaml` is the pattern: an `OCIRepository` on the registry and a Kustomization that applies whatever
the artifact holds, decrypting with the cluster key. `artifacts/zot/` is the artifact's source, plain manifests with
the image pinned by digest; `push.sh` pushes the directory as it is, tagged with the commit and `current`.
`artifacts/versitygw/` and `apps/versitygw/source.yaml` are the second use of the pattern, the S3 service at the
osl1 site (`docs/plans/2026-10-s3-osl1.md`).

zot hosts its own config artifact. The loop is closed by git: `bootstrap/zot-from-git.yaml` applies the same
directory straight from the repository, without prune, until zot serves its first artifact, and again whenever a bad
artifact leaves zot unable to serve (decisions 011 and 013). Nothing outside this cluster and this repository is
needed to recreate the registry. Verification with cosign is a TODO until the platform signing key exists.

## The registry

zot at `registry.dataverket.org`: anonymous pull, push for `fabrikk-ci` (`artifacts/zot/zot-htpasswd.enc.yaml`; the
plaintext is `zot-ci-credentials.enc.yaml`, the source the factory's vault copies from). One replica on a retained
Cinder volume; the zot image itself comes from ghcr.io, pinned by digest.

## Operating models (swamp)

This repository is also a swamp repository: `models/` holds the instances a human uses to operate what is deployed
here, `extensions/models/` their custom methods, `workflows/` the release runner, the forge-to-GitHub mirror and
the fleet disk survey, and `vaults/infra/` the credentials, one file per secret (decision 005). They came from
`fabrikk` on 2026-09-18 so that the factory holds no credential for this cluster. Run them from this checkout, with
`_bin` on `PATH` for the Flux model and `omnictl` and `talosctl` on `PATH` for the Omni and Talos models:

```sh
swamp model search --json | jq '.results[].name'     # forgejo, omni, registry, hov1-s3, runner-pods, dataverket-prod-*, <namespace>-pods, forgejo-events
swamp model method run forgejo health
swamp model method run omni discover                  # the Talos fleet, read-only
swamp model method run dataverket-prod-kustomizations reconcile --input name=apps --input namespace=flux-system --input withSource=true
swamp workflow run fleet-volumes                      # every node's disks, partitions and EPHEMERAL usage, read-only
swamp model method run runner-pods list               # context dataverket-prod-readers
swamp model method run runner-events getWarnings      # the same namespace's warning events, same context
swamp model method run dataverket-prod-helm list      # context dataverket-prod-admin
swamp model method run registry copy --input source=<upstream>@sha256:<digest> --input name=<image> --input tag=<tag>
swamp workflow run fabrikk-runner                     # the release runner; every step is guarded by its record
swamp workflow run worker-join --input name=dataverket-wrkr-N   # one half of a worker swap, docs/storage.md
swamp model method run hov1-s3 check                  # the hov1 gateway against its rules; inventory needs the root key, vaults/operator/README.md
```

`dataverket-prod-talos` (`@dataverket/talosctl/node`) reaches the machines through Omni's proxy; its node list and
talosconfig are the `talosconfig-dataverket-prod` record that `omni talosconfig` writes and `fleet-volumes` refreshes,
so run the workflow rather than the model's methods alone. Its `reset`, `upgrade` and `patchConfig` change machines;
`volumes`, `version` and `services` do not.

Kube contexts come from your default kubeconfig (`dataverket-prod-readers` for reading, `dataverket-prod-admin`
for changes), and `task admin:renew` mints both for the working day. A model definition names a context, or a key
file the same session wrote, and never a secret value. The vault holds what a process consumes and decrypts with
an operator's YubiKey or the swamp host's key, see Secrets above; `swamp vault list-keys infra` shows what it
holds.

## Decisions

`docs/decisions/`: one record per decision, in the Structured MADR shape Dataverket validates, with a dated audit
entry saying whether it has actually landed. A number is an identity and nothing else: a new record takes the next
free one whatever its subject, so the index groups by each record's `category` instead and is generated from them.

```sh
task decisions        # the set as a table, with what is still pending
task decisions:new    # the next number, the template, and $EDITOR
task decisions:index  # rewrite docs/decisions/README.md from the records
```

New shape, new record: a decision is not edited to change its meaning once accepted.
