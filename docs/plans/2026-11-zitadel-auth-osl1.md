# Plan: Zitadel moves from zitadel.dataverket.org to auth.osl1.dvkt.no

Written 2026-11-01. Nothing is applied. The instance, its database and its users stay where they are; what changes
is the name it is reached by. Zitadel serves one instance on several names at once, so the move is an overlap and
not a cutover: the new name is added beside the old, every client moves on its own day, and the old name is
retired last. Nothing in the plan needs the instance to be down.

## What was found

Read through swamp on 2026-11-01 (`zitadel-app list`, `zitadel-user list`, `zitadel-settings read`,
`dataverket-prod-helm list`, `dataverket-prod-deployments`, `zitadel-oidc health`) and in Zitadel's source at the
version that runs here, v4.15.3, chart 10.0.4.

| Piece | Today |
|---|---|
| The instance | HelmRelease `zitadel/zitadel`, chart 10.0.4, Zitadel v4.15.3, helm revision 1: this release has never been upgraded, so the chart's pre-upgrade hooks have never run here. `ExternalDomain: zitadel.dataverket.org`, `ExternalSecure: true`, no `ExternalPort` |
| Its names in Zitadel | Instance domains `zitadel.dataverket.org` and the generated `zitadel-obgyom.zitadel.dataverket.org`; the org `Operators` has the primary domain `operators.zitadel.dataverket.org`. The Management Console's redirect URIs carry `:8080`, Zitadel's default `ExternalPort`, which says the port was never set |
| The edge | Envoy Gateway, listeners `https` (`*.dataverket.org`), `https-dataverket-org`, `https-s3-osl1` (`*.s3.osl1.dvkt.no`). cert-manager makes a certificate per listener from the Gateway's annotation, DNS-01 through the Nordhost webhook; external-dns makes A records from HTTPRoute hostnames, `upsert-only`. Both zones, `dataverket.org` and `dvkt.no`, are at Nordhost; the deSEC plan has not started |
| The pods | `zitadel` and `zitadel-login`, one replica each, RollingUpdate with `maxSurge 25%` and `maxUnavailable 25%`: with one replica that is a surge of one and no pod taken down before its successor is ready |
| The database | CNPG, three instances on worker disks (decision 018), barman to hov1 nightly at 03:30, 14 days kept |
| Clients | Forgejo (`autoDiscoverUrl`), Zulip (`oidc_url` in the StatefulSet and the organization Job), zot (`issuer` in its config), the Incus host `incus-01` at 91.242.200.187 (outside this repository), the operator login app `cli` (device flow, `~/.config/zitadel/config.yaml`), and the eight swamp definitions under `models/@dataverket/zitadel/` plus the `zitadel-oidc` endpoint check. Every client's redirect URI is on the client's own host and does not change |
| People | Ten humans and three machine users. Login policy: password allowed, MFA not forced, passkeys allowed, second factors OTP and U2F |
| Tokens | Access and ID tokens 12 h, refresh tokens 90 days, 30 days idle |

## How Zitadel takes a new name

Three facts from the source decide the shape of the plan.

1. **A rerun of `zitadel setup` adds the name and removes nothing.** Setup has a repeatable step, `config_change`
   (`cmd/setup/config_change.go`), that runs when `ExternalDomain`, `ExternalPort` or `ExternalSecure` differ from
   the last run. It adds the new domain as a custom instance domain and a new generated domain
   (`zitadel-obgyom.<new>`), and rewrites the Management Console's redirect URIs for the new name
   (`internal/command/system_model.go`). No domain is removed, so `zitadel.dataverket.org` keeps serving. The
   chart runs setup as a `pre-upgrade` hook Job before the Deployments change, with `--init-projections=true` and a
   300 s deadline. Zitadel's own docs say the same in one line: these three settings are applied only during setup.
2. **The issuer follows the request, not the config.** The instance is found by the Host header
   (`internal/api/http/middleware/instance_interceptor.go`), the origin in the discovery document and in every
   token is built from that host, and a host that is not an instance domain is answered with 404 and
   `unable to set instance using origin ... (ExternalDomain is ...)`. So with both names as instance domains, a
   client at the old name sees `issuer: https://zitadel.dataverket.org` and a client at the new one sees
   `https://auth.osl1.dvkt.no`. Each client moves on its own, and nothing moves until it is asked to.
3. **Passkeys and U2F are bound to the name.** The WebAuthn relying party id is the requested domain
   (`internal/webauthn/webauthn.go`), so a passkey or U2F key registered at `zitadel.dataverket.org` is not usable
   at `auth.osl1.dvkt.no`. This is the one cost that lands on people, and the overlap exists so they can pay it at
   their own pace.

## Goals

1. **No downtime that is Zitadel's.** The only restart is the pod roll in step 2, under a surge of one. Forgejo,
   Zulip and zot each restart once on their own day, as they do for any change.
2. **One change, one check, one way back**, in the order below. Every step is a commit Flux applies, verified
   through swamp, and reversible by reverting it.
3. **Nobody locked out.** The old name stays until `zitadel-user authFactorList` says every human can log in at
   the new one.

## Steps

### 0. Baseline, read-only

- `swamp workflow run health`; `swamp behavior run zitadel-app list`; `zitadel-user list`, then `authFactorList`
  for each human, so who holds a passkey or U2F key, and who has TOTP beside it, is on record before anything
  changes. `zitadel-settings read` for the login policy; `dataverket-prod-helm list` for the release.
- The night's barman backup succeeded, and an on-demand `Backup` of `zitadel-db` before step 2. There is no swamp
  behavior for CNPG yet (see the swamp notes), so this is the admin session's kubectl until there is.
- The Management Console login works today, at the old name, despite the `:8080` redirect URIs.

### 1. The name, its certificate and its route

Nothing a user can see changes. Two files, one commit.

| File | Change |
|---|---|
| `infrastructure/envoy/gateway.yaml` | A listener `https-auth-osl1`, port 443, `hostname: auth.osl1.dvkt.no`, `certificateRefs: auth-osl1-dvkt-no-tls`, routes from all namespaces. cert-manager makes the certificate through the Gateway annotation, as it did for `*.s3.osl1.dvkt.no`, with the `dvkt.no` key in `nordhost-config` |
| `apps/zitadel/httproute.yaml` | Both routes gain the hostname `auth.osl1.dvkt.no`; the https route gains a second parentRef, `sectionName: https-auth-osl1`, the way the versitygw route attaches to its listener. The redirect route's `http` listener has no hostname and needs only the hostname. external-dns writes the A record, `91.242.200.101`, from the route within a minute |

Check: the Certificate is Ready; `dig +short A auth.osl1.dvkt.no` is the LoadBalancer address;
`curl https://auth.osl1.dvkt.no/.well-known/openid-configuration` answers 404 with the `unable to set instance`
text. That is the right answer: TLS and routing work, and Zitadel has not been told yet. The old name is untouched.

Also now: a second `@dataverket/http/endpoint` behavior, `zitadel-oidc-auth-osl1`, at the new discovery URL with
`bodyContains: '"issuer":"https://auth.osl1.dvkt.no"'`. It fails until step 2 and is the step's check thereafter.

A single-name listener, not `*.osl1.dvkt.no`: a Gateway API wildcard matches more than one label, so a wildcard
listener would overlap `*.s3.osl1.dvkt.no` on the same port and lean on Envoy's most-specific-wins rule. One name
is the whole need today.

### 2. Tell Zitadel

One file, one commit, the one step with a restart.

`apps/zitadel/release.yaml`: `ExternalDomain: auth.osl1.dvkt.no` and, in the same change, `ExternalPort: 443`,
so the console redirect URIs setup writes for the new name are the right ones and the `:8080` oddity ends.

What happens, in order: Flux reconciles the HelmRelease; the first helm upgrade of this release runs the `init`
and `setup` hook Jobs; `config_change` adds `auth.osl1.dvkt.no` and `zitadel-obgyom.auth.osl1.dvkt.no` to the
instance and rewrites the console's redirect URIs; the `zitadel` Deployment rolls on its changed ConfigMap, the
new pod ready before the old one stops; `zitadel-login` rolls with `ZITADEL_EXTERNALDOMAIN` and so its
`Host` and `X-Zitadel-Public-Host` headers set to the new name, which the instance now owns. The old pods serve
throughout the hook Jobs.

Check, through swamp: `zitadel-oidc health` still 200 with the old issuer; `zitadel-oidc-auth-osl1 health` 200
with the new; `zitadel-app get` on `Management Console` shows the new URIs; `dataverket-prod-helm list` shows the
release ready after an upgrade, not an install; `zitadel-events getWarnings` on the namespace is quiet. By hand:
a login at `https://auth.osl1.dvkt.no/ui/console` with a password, and a login at the old name as before.

Way back: revert the commit. Setup reruns, the console URIs are rewritten for the old name, the pods roll once
more; the old name never stopped being an instance domain, so nothing was ever unreachable. If a hook Job fails,
helm stops before the Deployments and the running pods are untouched; fix the cause and
`swamp behavior run dataverket-prod-helm reset`.

### 3. Move the clients, one commit each, in any order, over days

| Client | Change | Cost |
|---|---|---|
| Forgejo | `autoDiscoverUrl` in `apps/forgejo/release.yaml` | Forgejo's own restart; its sessions survive; the Zitadel app `git.dataverket.org` is unchanged |
| Zulip | `oidc_url` in `artifacts/zulip/statefulset.yaml` and `organization-job.yaml`, pushed as the artifact | Zulip's restart, a minute or three |
| zot | `issuer` in `artifacts/zot/configmap.yaml`, pushed | zot's restart; pulls retry; the cluster is unaffected (decision 013) |
| incus-01 | `oidc.issuer` on the host, outside this repository | Its users log in again |
| Operators | `url` and `login_url` in `~/.config/zitadel/config.yaml` on each host; the README's row. The reader and operator key files carry no address and need no re-mint | None |
| swamp | `apiUrl` in the eight `models/@dataverket/zitadel/*/*.yaml`; `zitadel-oidc` keeps the old URL until step 4 and the health workflow carries both endpoints meanwhile; `docs/plans/2026-10-s3-zitadel.md` names the new issuer | None |
| People | Each human logs in at the new name with their password and registers a passkey there. Someone whose only second factor is U2F cannot pass the second factor at the new name: at the old name first, add TOTP, then at the new name log in with password and TOTP and register the key again. `authFactorList` after each says who is still only on the old name | A few minutes each |

A client validates the issuer it is configured with, so a client that has moved rejects an ID token minted under
the old issuer. Forgejo, Zulip and zot keep no ID tokens past the login, so the move costs them nothing; a user
with an open session stays logged in and the next login goes through the new name.

### 4. Retire the old name

When `authFactorList` shows every human with a usable factor at the new name and every client in step 3 is moved:

- `apps/zitadel/httproute.yaml`: the `zitadel.dataverket.org` hostname and the `https` parentRef leave. A client
  still pointing at the old name then fails loudly, which is the point. The A record stays at Nordhost until
  removed by hand, since external-dns is `upsert-only`.
- The instance domain `zitadel.dataverket.org` stays in Zitadel's eventstore; removing it needs the System API,
  which this chart does not configure, and leaving it is harmless.
- `zitadel-oidc` moves to the new URL and the second endpoint behavior is deleted; the README's name table gains
  the row; the deSEC plan's osl1 inventory gains `auth.osl1.dvkt.no` and its certificate, so the record is copied
  with the rest when `osl1.dvkt.no` moves.
- A decision: the platform's own services are named under the site's zone, and why.

## What is assumed and must be checked

- `ExternalPort` is 8080 today, read from the console's redirect URIs and Zitadel's defaults, not from a config
  dump. If a config read says otherwise, the `ExternalPort: 443` line is still right and changes less.
- The hook Jobs run here for the first time. `--init-projections=true` on a three-instance CNPG inside 300 s is
  expected to be seconds; if the setup Job hits the deadline, raise `setupJob.activeDeadlineSeconds` and reset.
- The Nordhost keys in `nordhost-config` are not near expiry (`task admin`); step 1 needs both a record and a
  challenge in `dvkt.no`.
- Mail: `smtpSenderAddressMatchesInstanceDomain` is false, so the sender address is not tied to the name.
  Links in mails sent from background jobs are built from `ExternalDomain` after step 2; a password-reset mail
  after step 2 should carry the new name.
- Only the login pod sends `X-Zitadel-Public-Host`, equal to the Host it sends, so no trusted domain is needed.
  Anything that later sets a public host other than the instance host needs one (`POST /admin/v1/trusted_domains`).
- A refresh token minted under the old issuer and presented at the new name: tokens are the instance's, not the
  name's, and should refresh, but it is untested and no client here depends on it.
- The org's primary domain `operators.zitadel.dataverket.org` and the login names under it are not changed by
  setup. `loginNameIncludesDomain` is false, so people log in by username and nothing breaks; whether the org gets
  a domain under the new name is cosmetic and left alone.

## Access during the move

Read 2026-11-01 with `zitadel-user authFactorList` and `zitadel-org managerList`.

| Account | Holds | Works at the new name |
|---|---|---|
| `jibeddari@proton.me` | Two passkeys, nothing else; not a manager of `Operators` (instance roles are not readable through swamp yet) | No, until a passkey is registered there |
| `linus@dataverket.org` | One passkey, nothing else; `ORG_OWNER` of `Operators` | No, until a passkey is registered there |
| `admin@zitadel.zitadel.dataverket.org` | Password only, the install-time one in `release.yaml` unless it was changed; `ORG_OWNER` | Yes, a password is not bound to the name |
| `iam-admin` | Machine, `ORG_OWNER`; its key is in the cluster Secret `task admin:zitadel-setup` reads | Yes, a signed JWT is not bound to the name |
| `fabrikk-infra-beddari-reader` and `-operator` | Machine keys on the operator's host | Yes |
| The cluster | Omni-issued kubeconfig; decision 015 is not built | Not Zitadel's business: a broken Zitadel login cannot stop a fix |

Neither of you has a password, and nobody wants one as a detour: the login policy allows passwords
(`allowUsernamePassword: true`) but the accounts were made passkey-only and stay so. TOTP does not help either,
since it is a second factor and the problem is the first. So the way to a first factor at the new name is the one
Zitadel has for passwordless onboarding: a **passkey registration link**, minted by an administrator at the new
name, which lets the account register a passkey there without logging in first. The link's host follows where it
is minted, so it is minted at `https://auth.osl1.dvkt.no/ui/console`, never at the old one. The swamp user type
has no method for it yet (user v2 `CreatePasskeyRegistrationLink`; in the swamp notes), and the extension's source
is in the factory, not here, so until it exists the link is made by hand in the console.

Three rules follow. **The floor is proven before step 2**: `admin@zitadel.zitadel.dataverket.org` logs in at the
old name with a password that is not the one in `release.yaml`, and `task admin:zitadel-setup`, which acts as
`iam-admin` from the cluster, runs clean; one is the human administrator at the new name, the other the machine
path that needs no browser. **The old name stays until both of you hold a passkey at the new one**: your
existing passkeys keep working there, so nothing is lost before step 4. **Never both at once**: you register at
the new name first and log in with it; Linus, the human `ORG_OWNER`, follows only after that works.

## Goals to hand off

Each goal is a scope that ends in a clean state: Flux converged, `swamp workflow run health` green, the change
committed, and a dated line under the audit heading below. Work is local and commits are unsigned: the agent
commits as you directly, with `--no-gpg-sign` since the repository's config asks for signatures, and pushes when
you say. Stopping between goals is always safe. Rollback is one `git revert` unless the goal says otherwise, and
what a revert leaves behind is named.

| # | Goal | Done when | Rollback | Needs a person for |
|---|---|---|---|---|
| A | **Baseline.** The read-only runs of step 0, `authFactorList` for all ten humans, the night's backup confirmed, this plan committed with the records' versions | Every record is dated today and the plan is pushed | Nothing to roll back | Confirming the Management Console login works today, and the barman backup through kubectl until a CNPG behavior exists |
| B | **The floor.** The `admin@zitadel...` account logs in at the old name with a password that is not the git one, and `task admin:zitadel-setup` runs clean as `iam-admin` | Both are confirmed on the day, and the `FirstInstance` block has left `release.yaml` in its own commit | Nothing to roll back; the password change is not reverted | The console login and the password change |
| C | **The name.** Step 1: the listener, the certificate, the route, the second endpoint behavior | Certificate Ready, the A record resolves, the new name answers 404 with the `unable to set instance` text, the old name's health is unchanged | Revert. Left behind: the A record (external-dns is upsert-only) and the certificate Secret, both harmless; removing the record is by hand at Nordhost | Nothing |
| D | **Tell Zitadel.** Step 2, after a fresh on-demand backup | Both endpoint checks 200 with their own issuer, the release reports an upgrade, the console's redirect URIs carry the new name, and `admin@zitadel...` has logged in at the new name with its password | Revert; setup reruns and the pods roll once more. Left behind: `auth.osl1.dvkt.no` as an extra instance domain, which cannot be removed without the System API and harms nothing. The old name never stops serving in either direction | The login check, and the backup until a CNPG behavior exists |
| E | **Passkeys at the new name.** At the new name's console, `admin@zitadel...` mints a passkey registration link for you; you register and log in with it; then the same for Linus. Each passkey is named for the name | `authFactorList` shows, for each of you, a passkey with an id newer than the setup run, and each has logged in with it | Nothing to roll back; the old passkeys stay valid at the old name until G | Both links, both registrations, both logins |
| F | **The clients.** Step 3, one commit each: zot, Forgejo, Zulip, then the swamp definitions and the operator config files; `incus-01` is outside the repository and is yours | A login through Zitadel works at each client, and the swamp definitions answer at the new `apiUrl` | Revert the one client's commit; it restarts once more | One login per client; `incus-01` |
| G | **Retire the old name.** Step 4, when every human who logs in has a factor at the new name and every client is moved | The old name answers 404 from Envoy, the health workflow carries only the new endpoint, the README and the deSEC plan name the new name | Revert; the old name works again within a minute as long as its A record and certificate exist, so the record is removed last, weeks later | The decision record's acceptance, and the record's removal at Nordhost |

Goals A to D are a natural first hand-off: at the end of D both names serve, nothing a user does has changed,
and the way back is a revert. E to G wait on people and can be given one at a time.

## Audit

### 2026-11-01

Plan written. Nothing applied. Baseline runs recorded through swamp: `zitadel-oidc health` version 4,
`dataverket-prod-helm list` (release `zitadel.v1`), `zitadel-user list` and `authFactorList` for the three admin
accounts, `zitadel-org managerList`.

## Not in this plan

- Moving `dataverket.org` or `osl1.dvkt.no` to deSEC; this plan adds one record and one certificate under the
  existing Nordhost path and the deSEC plan copies them later.
- Configuring `SystemAPIUsers` to manage instance domains by API. Setup does what is needed here; a System API
  user is a credential with reach over every instance and deserves its own decision.
- Kubernetes authenticating against Zitadel (decision 015, not built). When it is, the API server's issuer is the
  new name from the start.
- Building `passkeyRegistrationLinkCreate` into `@dataverket/zitadel/user`; that is factory work, listed in the
  swamp notes, and goal E does not wait for it.
