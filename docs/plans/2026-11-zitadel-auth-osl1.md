# Plan: Zitadel moves from zitadel.dataverket.org to auth.osl1.dvkt.no

Written 2026-11-01. Nothing is applied. The instance, its database and its users stay where they are; what changes
is the name it is reached by. Zitadel serves one instance on several names at once, so the move is an overlap and
not a cutover: the new name is added beside the old, every client moves on its own day, and the old name is
retired last. Nothing in the plan needs the instance to be down.

**Revised 2026-11-02.** Goals A to D added `auth.osl1.dvkt.no` and the instance serves it; nothing has bound to
it. Three decisions then changed the target: the organization's services carry a `dataverket.org` name and a
site's alias beside it (031), Zitadel's domain list is kept by a System API user the operators hold (032), and
operator-paced workflows run as the person at the terminal (033). So the name people and clients bind to is
`id.dataverket.org`, this site's alias is `id.osl1.dvkt.no`, `auth.osl1.dvkt.no` is removed before anyone uses
it, and the passkey link workflow runs as the operator rather than under a key of its own. The sections below
that say `auth.osl1.dvkt.no` describe what was done; the goals under "Goals to hand off" say what is next.

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
4. **The login pod decides which name a browser login belongs to.** "Requested domain" means the public host when
   one is sent, else the instance host (`internal/api/http/request_context.go`). The login pod sends both: the
   browser's host as `x-zitadel-instance-host`, and whatever `CUSTOM_REQUEST_HEADERS` says as
   `X-Zitadel-Public-Host`, which the chart sets to `ExternalDomain` (`configmap_login.yaml`). With the chart's
   default a browser at the old name would, after step 2, present a public host of the new name: Zitadel refuses
   that unless the new name is a trusted domain (`internal/query/instance.go`, `public domain not trusted`), and
   if it were trusted every passkey would answer to the new name only. The login's own token is not the problem:
   it is verified as a system token against the configured `ExternalDomain` (`cmd/start/start.go`), not against
   the request. So step 2 overrides the login's `.env` with the chart's lines minus the public-host header. Then
   the browser's host is both instance and public host, no trusted domain is needed, and each name keeps its own
   passkeys. Read in the clones at `~/kode/zitadel` and `~/kode/zitadel-charts`, both at the running versions.

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
so the console redirect URIs setup writes for the new name are the right ones and the `:8080` oddity ends. And,
for fact 4, the login's `.env` as the chart renders it today with one header fewer:

```yaml
    login:
      customConfigmapConfig: |
        ZITADEL_LOGINCLIENT_KEYFILE="/login-service-key/tls.key"
        AUDIENCE="https://${ZITADEL_EXTERNALDOMAIN}"
        ZITADEL_API_URL="http://zitadel:8080"
        CUSTOM_REQUEST_HEADERS="Host:${ZITADEL_EXTERNALDOMAIN}"
```

The live ConfigMap `zitadel-login-config-dotenv` has the same four lines with `:8080` on the audience and
`X-Zitadel-Public-Host:${ZITADEL_EXTERNALDOMAIN}` on the headers; the port goes because `ExternalPort` becomes 443,
the header goes so that the browser's host decides which name a login belongs to. The audience stays right because
the server checks the login's token against the same two values.

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
| People | Each passkey holder, when ready, gets a registration link by mail from a run of the `zitadel-passkey-link` workflow, opens it within the hour, registers a passkey on the new name and logs in there once. Nobody needs a password. `authFactorList` after each run says who still has only an old-name passkey, and the workflow is run again for them | A few minutes each, at a time of their choosing |

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

### 5. The pivot to the two names

Added 2026-11-06, after decisions 031 and 032; goal K. Four steps, each one commit on a branch that ends with a
stop for your squash-merge, signature and push, since Flux reads `main`. Zitadel's domain list is written only
through `task admin:zitadel-domains`, typed into your session without enter, one touch per run. Nothing anyone has
bound to changes until step 4's cleanup, and even that removes only what nobody uses.

| # | Change | Done when | Rollback |
|---|---|---|---|
| 5.1 Edge | Listener `https-id-osl1` for `id.osl1.dvkt.no` with certificate `id-osl1-dvkt-no-tls`; the Zitadel routes carry `zitadel.dataverket.org` and `id.dataverket.org` on the `https` listener and `id.osl1.dvkt.no` on its own; endpoint behaviors `zitadel-oidc-id` and `zitadel-oidc-id-osl1` in the shape of `zitadel-oidc-auth-osl1` | Both new names resolve, the certificate is Ready, both answer 404 `unable to set instance` with TLS verified, the old name unchanged | Revert; the records and the certificate Secret stay, harmless |
| 5.2 Zitadel | After a fresh on-demand `Backup` you apply: `ExternalDomain: id.dataverket.org`, and `zitadel-system`'s `apiUrl` to `https://id.dataverket.org` in the same commit, since the assertion's audience follows `ExternalDomain` | The release reports an upgrade; `id.dataverket.org` answers 200 as its own issuer; the old name and `auth.osl1.dvkt.no` still answer 200 as theirs; health green | Revert; setup reruns; `id.dataverket.org` stays an instance domain until the task removes it |
| 5.3 Domains | Through the task, each followed by `domainList`: `domainAdd id.osl1.dvkt.no`; `domainSetPrimary id.osl1.dvkt.no`; `domainRemove auth.osl1.dvkt.no` with `confirm`, `dryRun` first | `domainList` shows `zitadel.dataverket.org`, `id.dataverket.org`, `id.osl1.dvkt.no`, the three generated twins, primary on the alias; `id.osl1.dvkt.no` answers 200 as its own issuer | `domainAdd` and `domainSetPrimary` undo each other's effect; a removed domain is re-added by the task |
| 5.4 Cleanup | The `https-auth-osl1` listener, the `auth.osl1.dvkt.no` route hostname and endpoint behavior go; the health workflow carries `zitadel-oidc`, `zitadel-oidc-id` and `zitadel-oidc-id-osl1`; the passkey-link workflow's URL template, `zitadel-me`'s `apiUrl`, the README's name table and this plan's tables say `id.dataverket.org` | `auth.osl1.dvkt.no` answers 404 from Envoy; health green; you confirm your passkey at the old name and the admin password at `id.dataverket.org` | Revert; the name serves again within a minute while its record exists |

The `auth` A record at Nordhost is yours to remove at the end; the plan touches no DNS by hand. Not in this
step: the clients (goal F) and the old name (goal G), which follow once people hold passkeys on
`id.dataverket.org`.

## What is assumed and must be checked

- `ExternalPort` is 8080 today: the console's redirect URIs and the login's live audience,
  `https://${ZITADEL_EXTERNALDOMAIN}:8080`, both say so. `ExternalPort: 443` changes the console URIs, the login's
  audience and the server's system-token issuer together, all derived from the same two values.
- There are no trusted domains today, and the instance's domains are `zitadel.dataverket.org` (primary) and the
  generated `zitadel-obgyom.zitadel.dataverket.org`. Read with the reader key through `share/admin/zitadel.sh`,
  since no swamp type reads them.
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
| `jibeddari@proton.me` | Two passkeys, nothing else; `IAM_OWNER` of the instance | No, until a passkey is registered there |
| `linus@dataverket.org` | One passkey, nothing else; `IAM_OWNER`, and `ORG_OWNER` of `Operators` | No, until a passkey is registered there |
| `admin@zitadel.zitadel.dataverket.org` | Password only, the install-time one in `release.yaml` unless it was changed, and nobody holds it elsewhere; `IAM_OWNER`, `ORG_OWNER` | Yes, once a password is known |
| `iam-admin` | Machine, `IAM_OWNER`, `ORG_OWNER`; its key is in the cluster Secret `task admin:zitadel-setup` reads | Yes, a signed JWT is not bound to the name |
| `fabrikk-infra-beddari-operator` | Machine, `PROJECT_OWNER` of the two projects in `ZITADEL_PROJECTS` and nothing else | Yes, but it can change no user and no setting |
| `fabrikk-infra-beddari-reader` and `-operator` | Machine keys on the operator's host | Yes |
| The cluster | Omni-issued kubeconfig; decision 015 is not built | Not Zitadel's business: a broken Zitadel login cannot stop a fix |

Neither of you has a password, and nobody wants one as a detour: the login policy allows passwords
(`allowUsernamePassword: true`) but the accounts were made passkey-only and stay so. TOTP does not help either,
since it is a second factor and the problem is the first. So the way to a first factor at the new name is the one
Zitadel has for passwordless onboarding: a **passkey registration link**, minted by an administrator at the new
name, which lets the account register a passkey there without logging in first. The link's host is whatever the
`urlTemplate` says, so it names the new one. The links come from a swamp workflow, `zitadel-passkey-link`, run by you
or Linus for one person at a time when they are ready, mailing through Zitadel's own SMTP
(`noreply@dataverket.org`, active), for the two of you and for everyone else alike; goal E names what it needs first. The console at the new name, as `admin@zitadel...`, is the fallback
for one link by hand. A logged-in user at the old name can also send themselves a link from the console's
Passwordless dialog and change the host in it, which is the self-service route until goal G.

Three rules follow. **The floor is proven before step 2**: `admin@zitadel.zitadel.dataverket.org` logs in at the
old name with a password that is not the one in `release.yaml`, and `task admin:zitadel-setup`, which acts as
`iam-admin` from the cluster, runs clean; one is the human administrator at the new name, the other the machine
path that needs no browser. **The old name stays until both of you hold a passkey at the new one**: your
existing passkeys keep working there, so nothing is lost before step 4. **Never both at once**: you register at
the new name first and log in with it; Linus, the human `ORG_OWNER`, follows only after that works.

## Goals to hand off

Each goal is a scope that ends in a clean state: Flux converged, `swamp workflow run health` green, the change
committed, and a dated line under the audit heading below. The agent works on a branch, commits there unsigned
and never pushes; you review, sign and merge to `main`, which is what Flux reads. Goals A to D ran under a one-off
grant to commit and push `main` directly, and their fifteen commits were re-signed in place afterwards. Stopping
between goals is always safe. Rollback is one `git revert` unless the goal says otherwise, and what a revert leaves
behind is named.

| # | Goal | Done when | Rollback | Needs a person for |
|---|---|---|---|---|
| A | **Baseline.** The read-only runs of step 0, `authFactorList` for all ten humans, the night's backup confirmed, this plan committed with the records' versions | Every record is dated today and the plan is pushed | Nothing to roll back | Confirming the Management Console login works today, and the barman backup through kubectl until a CNPG behavior exists |
| B | **The floor.** Nobody holds the `admin@zitadel...` password, so it is set anew: `bin/zitadel-floor`, run as you through the same device-flow login `admin:start` uses (you are `IAM_OWNER`), reads a password you first put in Proton Pass through `bin/with-secrets` and sets it on the account; then you log in with it at the old name. `task admin:zitadel-setup` proving `iam-admin` is deferred by your choice | The login is confirmed, and the `FirstInstance` block has left `release.yaml` in its own commit | Nothing to roll back; the password change is not reverted | Creating the Proton Pass entry, running the task, the console login |
| C | **The name.** Step 1: the listener, the certificate, the route, the second endpoint behavior | Certificate Ready, the A record resolves, the new name answers 404 with the `unable to set instance` text, the old name's health is unchanged | Revert. Left behind: the A record (external-dns is upsert-only) and the certificate Secret, both harmless; removing the record is by hand at Nordhost | Nothing |
| D | **Tell Zitadel.** Step 2, after the replica is re-cloned and a fresh on-demand backup taken: `ExternalDomain`, `ExternalPort: 443`, and the login's `.env` without the public-host header | Both endpoint checks 200 with their own issuer, the release reports an upgrade, the console's redirect URIs carry the new name, `admin@zitadel...` has logged in at the new name with its password, and you have logged in at the old name with your passkey as before | Revert; setup reruns and the pods roll once more. Left behind: `auth.osl1.dvkt.no` as an extra instance domain, which cannot be removed without the System API and harms nothing. The old name never stops serving in either direction | The two login checks, and the backup until a CNPG behavior exists |

Goals A to D are done (audit below). The goals that follow were reset on 2026-11-02 by decisions 031 to 033. The
first three build; the pivot applies; E to G then run against `id.dataverket.org`. Each is one branch, squash-merged
and signed by you.

| # | Goal | Done when | Rollback | Needs a person for |
|---|---|---|---|---|
| H | **The extension.** In `~/kode/swamp-extensions`, `@dataverket/zitadel`: `accessTokenFile` beside `keyJson` and `keyJsonFile` on every type, a bearer sent as is with no exchange (033); a new type `@dataverket/zitadel/system` with `systemKeyFile` and `systemUser`, signing the system JWT, and four methods: `domainList`, `domainAdd`, `domainRemove` (verify-first, `confirm` repeats the domain, `dryRun`) and `domainSetPrimary` (032). `passkeyRegistrationLinkCreate` is already on the branch. Tests for each; the adversarial review recorded; version 2026.11.02.1 published and pulled here | `deno task check`, `lint` and `test` clean, `bin/push` runs without findings of ours, `swamp extension pull` here shows the methods | The pull is reverted to 2026.10.27.1 | The publish, which signs with your account |
| I | **Run as you.** `task admin:zitadel-login` writes the device-flow access token to `~/.config/zitadel/fabrikk-infra-me.token`, 0600; `admin:stop` removes it; `task admin` shows its expiry. The definition `zitadel-me` (`@dataverket/zitadel/user`, `accessTokenFile`) replaces `zitadel-user-manager`; `bin/zitadel-users-key`, its task, its setting and its README rows leave the `zitadel-passkey-link` branch. `zitadel.sh` says the token is written when asked | `swamp behavior run zitadel-me authFactorList --arg user=<you>` succeeds after the login and fails with a clear message after `admin:stop`; the branch rebased on this | Revert; nothing is minted in Zitadel | Logging in once per run of the check |
| J | **The system key.** You make the key pair at a terminal: private half into `vaults/operator/osl1/zitadel-system.enc.json`, public certificate into the HelmRelease as `SystemAPIUsers.operators` with `SYSTEM_OWNER` (032). One upgrade. `task admin:zitadel-domains` wraps `sops exec-file` around a `@dataverket/zitadel/system` run; the store's README gains the row | `domainList` through the task returns the four domains the instance has today; the upgrade converged; health green | Revert the HelmRelease; the key file is yours to keep or shred | Making the key pair, the sops encryption, every run of the task |
| K | **The pivot.** Step 5, its four sub-steps in order, each its own commit, push and check | Step 5.4's done-when | Per sub-step, as step 5 says | The on-demand backup, four merges, three touches, two logins |
| E | **The two of you.** `task admin:zitadel-login`, then `swamp workflow run zitadel-passkey-link --input user=<your login>`: Zitadel mails you a link on `id.dataverket.org`, you register a passkey there within the hour and log in with it. Then Linus, as himself, the same way | `authFactorList` shows, for each of you, a passkey with an id newer than K's setup run, and each has logged in at `id.dataverket.org` with it | Nothing to roll back; the old passkeys stay valid at the old name until G | The logins, the two runs, the registrations |
| F | **The clients.** The other five passkey holders first, each mailed by a run when they say they are ready, mailed again if `authFactorList` still shows them without a new passkey. Then one commit each: zot, Forgejo, Zulip, the swamp definitions' `apiUrl` and the operator config files, each to `https://id.dataverket.org`; `incus-01` is yours. A client moves only when every human who logs in through it has a passkey at `id.dataverket.org`: there the login offers a passkey-only user no other way in | A login through Zitadel works at each client; the swamp definitions answer at the new `apiUrl` | Revert the one client's commit; it restarts once more | One login per client; `incus-01`; running the mail when people are present |
| G | **Retire the old name.** When every human who logs in has a passkey at `id.dataverket.org` and every client is moved: `zitadel.dataverket.org` leaves the routes, `domainRemove` takes it out of the instance (its generated twin stays, as every generated domain does), `zitadel-oidc` is deleted, the README and the deSEC plan name the two new names, and the rescue playbook is drafted with the flip as `domainAdd`, `domainSetPrimary`, `domainRemove` | The old name answers 404 from Envoy; `domainList` shows the two names and the three generated twins that remain; health green | Revert the routes; re-add the domain by the task; the old name works again within a minute while its record and certificate exist, so the record is removed last | Removing the record at Nordhost; the playbook's review |

H, I and J touch no user; K changes what the instance answers on but nothing anyone has bound to; E to G wait on
people and can be given one at a time.

## Audit

### 2026-11-01

Plan written. Nothing applied. Baseline runs recorded through swamp: `zitadel-oidc health` version 4,
`dataverket-prod-helm list` (release `zitadel.v1`), `zitadel-user list` and `authFactorList` for the three admin
accounts, `zitadel-org managerList`.

### 2026-11-01, goal A: baseline

**Status:** Done. Read-only; nothing in the cluster or in Zitadel changed.

| Finding | Where | Assessment |
|---------|-------|------------|
| The health workflow is green | run `e565ff82`, 11:59 UTC, 11 s; `zitadel-oidc health` v5, 200, TLS verified | baseline |
| The release is at its first helm revision | `dataverket-prod-helm` `zitadel--zitadel` v4: `InstallSucceeded`, `zitadel.v1`, chart 10.0.4, app v4.15.3 | as the plan says: the pre-upgrade hooks have never run here |
| The console's redirect URIs carry `:8080` | `zitadel-app` `app-zitadel-management-console` v2, both URIs | confirms `ExternalPort` is unset; step 2 sets 443 |
| Apps listed in all six projects, settings read | `zitadel-app list` ×6, `zitadel-settings read` (`login-org` v2) | baseline |
| Factors of all ten humans | `zitadel-user authFactorList` ×10; `frank_solli@icloud.com` is the login name, not the mail | seven have a passkey only (`jibeddari@proton.me` two, the rest one), `dataverket@km.krot.org` TOTP, and `admin@zitadel...`, `lars.solem.no@gmail.com`, `postmannen@gmail.com` have no factor at all, so a password or nothing. Every passkey holder needs goal E's link; the three without a factor are untouched by the move |
| Org managers | `zitadel-org managerList` v1: `iam-admin`, `admin@zitadel...`, `linus@dataverket.org`, all `ORG_OWNER` | as the access table says |
| The night's backup | `zitadel-db-daily-20261101033000`, `completed`, 03:30:00 to 03:30:05 UTC; the cluster's `LastBackupSucceeded` and `ContinuousArchiving` conditions True | confirmed, through kubectl: no CNPG behavior yet |
| **The database runs on two of three instances** | `zitadel-db` phase `Failing over from zitadel-db-1 to zitadel-db-3`, unchanged since 2026-10-18 02:42 UTC; `zitadel-db-2` in `CrashLoopBackOff`, 4391 restarts, PostgreSQL `PANIC: could not locate a valid checkpoint record at 2A/7B000028` on every start; `Ready` False | pre-existing, not the move's. The primary `zitadel-db-3` and the replica `zitadel-db-1` are healthy and the backups come from the primary. The repair is a re-clone of instance 2 (its PVC removed, CNPG rebuilds it from the primary) and is a decision for a person before step 2, not part of goals A to D |
| Stale pod records | `zitadel-pods` holds records for pods that no longer exist, so its latest set is not a live view | `dataverket-prod-deployments` is the live count: 1/1 for both |

**Action Required:** Decide on the replica before goal D. Goal B asks for the floor.

### 2026-11-01, goal B: the floor

**Status:** Done, with the `iam-admin` check deferred.

| Finding | Where | Assessment |
|---------|-------|------------|
| Nobody held the admin password | the operator | `bin/zitadel-floor` and `task admin:zitadel-floor` written: as you, through the device-flow login, the password in the Proton Pass item with the admin address in its email field is set on the account (`POST /v2/users/{id}/password`). Commits `d1c0fee`, `f57562d`, `db45bd6` |
| Two Proton Pass items share the title | `share/secrets.sh` | a `pass://` reference takes `?FIELD=VALUE`, matched by reading that field of each candidate |
| A request body was an argument to curl | `share/admin/zitadel.sh` | every body now reaches curl as a config line on stdin, compacted by `jq -c` first; the first run failed on a multi-line body and was fixed |
| The admin login works | `https://zitadel.dataverket.org/ui/console`, confirmed by you | the floor stands at the old name; it needs no passkey, so it will stand at the new one |
| `task admin:zitadel-setup` as `iam-admin` | run by you after goal D, 2026-11-01: the key read from the cluster, the organization named `Operators`, project `fabrikk-infra-admin` and application `cli` there, nothing changed | the machine floor is proven, at the instance that now carries both names |
| The install password left git | `apps/zitadel/release.yaml` | the `FirstInstance` block removed in its own commit. The ConfigMap changes, so this is the release's first helm upgrade: the `init` and `setup` hook Jobs run, and the pod rolls under a surge of one, which rehearses step 2's path |
| Replica decision | you | re-clone `zitadel-db-2` before goal D, done by the agent |

| The first upgrade converged | `dataverket-prod-helm` v5 then ready: `UpgradeSucceeded`, `zitadel.v2`; `zitadel-jobs listJobs`: `zitadel-init` 11 s, `zitadel-setup` 36 s, both succeeded; new `zitadel` and `zitadel-login` pods at 12:44:57 UTC, 1/1 each; health run `5c4b07df` green, `zitadel-oidc health` v6 at 200 | the path step 2 takes is proven: hooks, then a roll under a surge of one, with the old name answering throughout |

A behavior `zitadel-jobs` (`@swamp/kubernetes/job`, namespace `zitadel`) was added so the hook Jobs are read
through swamp.

**Action Required:** Goal C.

### 2026-11-01, goal C: the name

**Status:** Done. Commit `265483e`, applied by Flux at 12:49 UTC. Nothing a user does has changed.

| Finding | Where | Assessment |
|---------|-------|------------|
| The listener | `envoy-gateway`, `https-auth-osl1`: `Accepted`, `ResolvedRefs`, `Programmed` all True, one attached route | done |
| The certificate | `auth-osl1-dvkt-no-tls`, Let's Encrypt, SAN `auth.osl1.dvkt.no`, valid to 2027-01-30; Ready two minutes after the push, through the Nordhost DNS-01 solver | done |
| The record | `auth.osl1.dvkt.no` A `91.242.200.101` at `ns1.nordkapp.net` within a minute, from the route by external-dns | done |
| The routes | `zitadel`: both parents `Accepted` and `ResolvedRefs`; `zitadel-redirect`: 301 to https at the new name | done |
| Zitadel's answer at the new name | 404, `unable to set instance using origin &{auth.osl1.dvkt.no https} (ExternalDomain is zitadel.dataverket.org)`, TLS verified | the right answer before step 2 |
| The new check | `zitadel-oidc-auth-osl1 health` v1: 404, TLS verified, body not matched | fails by design until D |
| The old name | `zitadel-oidc health` v7: 200; health run `b6ebea08` green | unchanged |

**Action Required:** Re-clone `zitadel-db-2`, then a fresh backup, then goal D.

### 2026-11-01, goal D: the instance is told

**Status:** Done. Commit `a71c106`, applied by Flux at 12:57 UTC; both names serve, nothing a user does has
changed. The replica repair was deferred by your choice: it drains `dataverket-wrkr-6`, which since the first
upgrade runs both Zitadel pods, and needs the Omni operator key; it gets its own window (`docs/storage.md`,
"Destroying an instance on a worker that stays").

| Finding | Where | Assessment |
|---------|-------|------------|
| The backup before | `Backup zitadel-db-before-rename-20261101`, method plugin, completed 12:56:00 to 12:56:06 UTC | applied from the ScheduledBackup's spec with kubectl; no CNPG behavior yet |
| The upgrade | `dataverket-prod-helm`: `UpgradeSucceeded`, `zitadel.v3`; `zitadel-init` 4 s, `zitadel-setup` 10 s; both Deployments 1/1 updated; the only warnings are the new pods' startup and readiness probes | the roll under a surge of one, as rehearsed in B |
| The names | instance domains read with the reader key: `zitadel.dataverket.org` (primary), `zitadel-obgyom.zitadel.dataverket.org`, `auth.osl1.dvkt.no`, `zitadel-obgyom.auth.osl1.dvkt.no`; no trusted domain | setup added, removed nothing, as fact 1 says |
| The issuers | `https://zitadel.dataverket.org/.well-known/openid-configuration` says `https://zitadel.dataverket.org`; the same at `auth.osl1.dvkt.no` says `https://auth.osl1.dvkt.no`; `zitadel-oidc health` v9 and `zitadel-oidc-auth-osl1 health` v2 both 200 with the body matched | each name is its own issuer, as fact 2 says |
| The console | redirect URIs v3: the two old `:8080` ones kept, `https://auth.osl1.dvkt.no/ui/console/auth/callback` and the generated one added, without a port | `ExternalPort: 443` did its work; the old URIs are harmless and leave with the old name |
| The login pod | live `.env`: `AUDIENCE="https://${ZITADEL_EXTERNALDOMAIN}"`, `CUSTOM_REQUEST_HEADERS="Host:${ZITADEL_EXTERNALDOMAIN}"`, no public-host header; the login UI answers 200 at both names | fact 4 applied |
| The two logins | `admin@zitadel...` with its password at `https://auth.osl1.dvkt.no/ui/console`; your passkey at `https://zitadel.dataverket.org/ui/console` as before, confirmed by you | the floor stands at the new name, and the overlap holds at the old |
| The health workflow | carries `zitadel-oidc-auth-osl1` beside `zitadel-oidc` from now on; run `90523cc6` green | the uptime log covers both names |

**Action Required:** Goals E to G, one at a time, as people are ready: the registration links at the new name's
console (you first, then Linus), the clients, the old name's retirement. The replica repair in its own window.

### 2026-11-01, the replica

**Status:** Done, 13:44 to 13:46 UTC, with no downtime and no drain.

| Finding | Where | Assessment |
|---------|-------|------------|
| Instance 2 destroyed | `kubectl cnpg destroy zitadel-db 2`; the released PV `local-pv-47f3d4b8` deleted | the join pod was pending within seconds |
| The slot came back by itself | the static provisioner republished the PV under the same name at 13:44:41, the new claim bound, and CNPG's join cleared the old directory and cloned from the primary | three instances healthy at LSN `3C/680154A8`, `ContinuousArchiving` True, cluster `Ready` |
| The Talos reset | `dataverket-prod-talos-operator reset` on `10.0.0.141` with `u-pg-zitadel`: refused, `not authorized` | Omni's Operator role does not carry `os:admin`; the reset was not needed either, and you waived it with the outcome in hand. `docs/storage.md` corrected |
| Zitadel | `zitadel` on `wrkr-8` and `zitadel-login` on `wrkr-6` untouched; health run green | nothing a user does changed |

**Action Required:** None for the database. Goals E to G as above.

### 2026-11-06, goal I: run as you

**Status:** Done, on branch `zitadel-passkey-link`, rebuilt from `main` with only the workflow carried over; the
users key, its task, its lifetime setting and its rows never reached `main`.

| Finding | Where | Assessment |
|---------|-------|------------|
| Your login as a file | `bin/zitadel-login`, `task admin:zitadel-login`: the device-flow login, the token written 0600 to `~/.config/zitadel/fabrikk-infra-me.token` with its expiry in `.expires`; `admin:stop` removes both; `task admin` shows the row with who it authenticates as | run in your session at 12:48 UTC; `task admin` showed `fabrikk-infra-me.token ours 11 h 11-07 00:48 jibeddari@proton.me` |
| The definition | `zitadel-me`, `@dataverket/zitadel/user` 2026.11.02.1 with `accessTokenFile`; `zitadel-passkey-link` runs through it | `swamp behavior run zitadel-me authFactorList --arg user=jibeddari@proton.me` succeeded as you and recorded your two passkeys, `initiatedBy: user:beddari` |
| Without the file | after `task admin:stop` | the same run fails with `cannot read accessTokenFile ~/.config/zitadel/fabrikk-infra-me.token: No such file or directory`; `task admin:start` then brought the day back |
| The scripts' own rule | `share/admin/zitadel.sh` | the comment now says one task writes the token, every other lets it die with the run (033) |
| The extension | `@dataverket/zitadel` 2026.11.02.1, published 2026-11-06 and pulled | goal H |

**Action Required:** Goal J, the system key. The workflow's URL template still says `auth.osl1.dvkt.no`; K moves it.

### 2026-11-06, goal J: the system key

**Status:** Done. The public half is on `main` (`9ebb891`, upgrade `zitadel.v4`); the task's two fixes are on
branch `zitadel-domains-fix` for your merge.

| Finding | Where | Assessment |
|---------|-------|------------|
| The key pair | made at your prompt: `openssl genpkey` piped into `sops`, never on disk; `vaults/operator/osl1/zitadel-system.enc.json`, field `ZITADEL_SYSTEM_KEY`, the two YubiKeys; the public half derived once with a touch into `apps/zitadel/zitadel-system-operators.pub.pem` | done, 4096 bit |
| Zitadel knows it | `apps/zitadel/release.yaml`, `SystemAPIUsers.operators`, `KeyData` base64 of the PEM (the config loader decodes it), `SYSTEM_OWNER`; the chart merged it beside its login client | `zitadel.v4` upgraded 12:01 UTC, hooks 5 s and 10 s, both names 200 with their own issuer, health run `6338f053` green |
| The task | `bin/zitadel-domains`, `task admin:zitadel-domains -- <method>`: `sops exec-file` decrypts the entry for one command, which is the script again; it reads the field once into memory and hands it to swamp through a FIFO at the path `zitadel-system` names, removed after the run | two bugs found by running it: `printf %q` had escaped sops's `{}` placeholder, so the writer opened a file named `\{\}` and swamp got an empty key; then a guard read sops's own FIFO, which is readable once, and the run hung. Both fixed on `zitadel-domains-fix` |
| The checks with the key present | `task admin:zitadel-domains -- validate`, one touch | `zitadel-system` ten of ten, `reachable` included; outside a run the live check cannot pass, since the key exists only inside one |
| The list | `task admin:zitadel-domains -- domainList`, one touch, 12:12 UTC | the four domains, `zitadel.dataverket.org` primary, two generated; recorded under `zitadel-system`, `initiatedBy: user:beddari`; the FIFO gone and no process left |

**Action Required:** Merge the fix. Goal K, the pivot, is next: `ExternalDomain` to `id.dataverket.org`, the
alias added and made primary by this task, `auth.osl1.dvkt.no` removed by it.

### 2026-11-06, step 5.1: the edge

**Status:** Done. Commit `dfaab6b`, applied by Flux at 12:31 UTC; nothing a user does has changed.

| Finding | Where | Assessment |
|---------|-------|------------|
| The names | `id.dataverket.org` and `id.osl1.dvkt.no` A `91.242.200.101` at `ns1.nordkapp.net` within a minute, from the routes | done |
| The listener and certificate | `https-id-osl1`, `Programmed`, one route; `id-osl1-dvkt-no-tls` Ready two minutes after the push; `id.dataverket.org` under the wildcard | done |
| Zitadel's answer | both names 404 `unable to set instance using origin … (ExternalDomain is auth.osl1.dvkt.no)`, TLS verified; `zitadel.dataverket.org` unchanged | the right answer before 5.2 |
| The checks | `zitadel-oidc-id`, `zitadel-oidc-id-osl1` | fail by design until 5.2 and 5.3 |

**Action Required:** A fresh on-demand backup, then 5.2.

### 2026-11-06, step 5.2: the instance is told its name

**Status:** Done. Backup `zitadel-db-before-pivot-20261106` completed 12:34:21 to 12:34:27 UTC on three healthy
instances; commit `e8f7e1b` applied at 12:35, `zitadel.v5` upgraded by 12:36.

| Finding | Where | Assessment |
|---------|-------|------------|
| `ExternalDomain: id.dataverket.org`, `zitadel-system`'s `apiUrl` with it | `apps/zitadel/release.yaml`, `models/@dataverket/zitadel/system/zitadel-system.yaml` | setup added `id.dataverket.org` and `zitadel-obgyom.id.dataverket.org` |
| The names | `id.dataverket.org` 200 as its own issuer; `zitadel.dataverket.org` and `auth.osl1.dvkt.no` 200 as theirs; `id.osl1.dvkt.no` 404 until 5.3 | as the plan says |
| The pods, the checks | both Deployments 1/1 updated; `zitadel-oidc`, `zitadel-oidc-auth-osl1`, `zitadel-oidc-id` 200; health run `395d4e42` green | nothing a user does changed |

### 2026-11-06, step 5.3: the domain list

**Status:** Done through `task admin:zitadel-domains`, typed into your session, one touch per run, 12:37 to
12:41 UTC.

| Finding | Where | Assessment |
|---------|-------|------------|
| `domainAdd id.osl1.dvkt.no` | record `created`; the alias answered 200 as its own issuer at once | done |
| `domainSetPrimary id.osl1.dvkt.no` | record `updated`, `primary: true` | the primary names the site (032) |
| `domainRemove auth.osl1.dvkt.no` | `dryRun` first, record `planned`, nothing changed; then `removed`; the name answers 404 `unable to set instance` | done |
| `domainList` after each | six domains: `zitadel.dataverket.org`, `id.dataverket.org`, `id.osl1.dvkt.no` (primary) and the three generated twins | the done-when of 5.3; `zitadel-oidc-id-osl1` 200 |

**Action Required:** 5.4, the cleanup.

## Not in this plan

- Moving `dataverket.org` or `osl1.dvkt.no` to deSEC; this plan adds one record and one certificate under the
  existing Nordhost path and the deSEC plan copies them later.
- Kubernetes authenticating against Zitadel (decision 015, not built). When it is, the API server's issuer is the
  site's alias, `https://id.osl1.dvkt.no`: the cluster is the site's, so what it trusts is the site's name (031),
  and a credential for it does not outlive the site. A person who reaches the cluster with kubelogin therefore
  logs in at the alias and needs a passkey registered there too, one per site; the link workflow with the alias as
  its URL template mints it.
- The rescue playbook itself, beyond its draft in goal G: serving `id.dataverket.org` from another site needs a
  second cluster to exercise it against, and a CNPG replica cluster from the hov1 archive as its warm form.
- A login-time passkey migration as a Zitadel Action, and a recovery page on a name of Dataverket's; both in the
  swamp notes, neither needed for seven people.
