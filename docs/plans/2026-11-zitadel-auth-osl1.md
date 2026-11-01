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
| E | **The link workflow, and the two of you.** A swamp workflow `zitadel-passkey-link` mails one user, named by login name as its input, a passkey registration link on the new name, by `zitadel-user passkeyRegistrationLinkCreate` with `delivery: email` and a `urlTemplate` of `https://auth.osl1.dvkt.no/ui/v2/login/passkey/set?codeId={{.CodeID}}&code={{.Code}}&userId={{.UserID}}&organization={{.OrgID}}`. Two prerequisites: that method, the twin of `passwordResetLinkCreate`, in the factory's `@dataverket/zitadel`; and a key that may write users, since the operator key owns the two projects and nothing else, so `admin:elevate` mints a third, `ORG_USER_MANAGER` on `Operators`, named only by the definition that writes users. It is run on demand, by you or Linus, for one person at a time when they are ready, never as a batch. You run it for yourself first, register and log in at the new name; then for Linus | `authFactorList` shows, for each of you, a passkey with an id newer than the setup run, and each has logged in with it; the workflow and its key are in the README | Nothing to roll back; the old passkeys stay valid at the old name until G | The two registrations and logins, and the decision on the third key |
| F | **The clients.** Step 3. First the other five passkey holders, each mailed by a run of the workflow when they say they are ready, since a code lives an hour, and mailed again if `authFactorList` still shows them without a new passkey. Then one commit each: zot, Forgejo, Zulip, then the swamp definitions and the operator config files; `incus-01` is outside the repository and is yours. A client moves only when every human who logs in through it has a passkey at the new name: at the new name the login offers a passkey-only user no other way in, not even a mail | A login through Zitadel works at each client, and the swamp definitions answer at the new `apiUrl` | Revert the one client's commit; it restarts once more | One login per client; `incus-01`; running the mail when people are present |
| G | **Retire the old name.** Step 4, when every human who logs in has a factor at the new name and every client is moved | The old name answers 404 from Envoy, the health workflow carries only the new endpoint, the README and the deSEC plan name the new name | Revert; the old name works again within a minute as long as its A record and certificate exist, so the record is removed last, weeks later | The decision record's acceptance, and the record's removal at Nordhost |

Goals A to D are a natural first hand-off: at the end of D both names serve, nothing a user does has changed,
and the way back is a revert. E to G wait on people and can be given one at a time.

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

## Not in this plan

- Moving `dataverket.org` or `osl1.dvkt.no` to deSEC; this plan adds one record and one certificate under the
  existing Nordhost path and the deSEC plan copies them later.
- Configuring `SystemAPIUsers` to manage instance domains by API. Setup does what is needed here; a System API
  user is a credential with reach over every instance and deserves its own decision.
- Kubernetes authenticating against Zitadel (decision 015, not built). When it is, the API server's issuer is the
  new name from the start.
- Building `passkeyRegistrationLinkCreate` into `@dataverket/zitadel/user`; that is factory work, listed in the
  swamp notes, and goal E does not wait for it.
