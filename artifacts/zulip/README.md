# The zulip artifact

Zulip is Dataverket's chat and forum, at `https://forum.dataverket.org`. People log in with their Zitadel account.
This directory holds everything Zulip runs on: the app, its database, three helper services and their secrets.

It is delivered the way zot is. `push.sh` pushes this directory into zot as `platform/zulip-config`. Git holds only
the pointer, `apps/zulip/source.yaml`, and Flux applies whatever the `current` tag holds: it builds
`kustomization.yaml`, decrypts the Secrets with the cluster key, and applies the result. The organization itself,
its name, owner, brand and open channels, is in the artifact too, applied by a Job ("The organization"). How it was
built, step by step, is `docs/plans/2026-10-zulip.md`.

## Contents

| File | What |
|---|---|
| `namespace.yaml` | Namespace `zulip` |
| `statefulset.yaml` | Zulip itself, one pod with a 5 GiB `/data` volume; its Service; the routes for `forum.dataverket.org` |
| `services.yaml` | RabbitMQ, memcached and Valkey, which Zulip needs; official images pinned by digest, no volumes |
| `postgres.yaml` | The database: `Cluster zulip-postgres`, one instance on a 10 GiB volume, archived to the hov1 site |
| `backup.yaml` | The database backup: bucket `cnpg-zulip` at hov1, a base backup every day at 03:15, kept 14 days |
| `zulip-secrets.enc.yaml` | Secrets Zulip would otherwise make itself, kept here so a restore keeps sessions, avatars and image links |
| `zulip-zitadel-oidc.enc.yaml` | The Zitadel client `forum.dataverket.org` (project `zulip`): `CLIENT_ID` and `CLIENT_SECRET` |
| `zulip-mailer.enc.yaml` | The Nordhost mailbox Zulip sends from; a copy of Forgejo's |
| `s3-zulip.enc.yaml` | The account `zulip` on the osl1 S3 gateway, owner of `zulip-uploads` and `zulip-avatars` |
| `s3-cnpg-zulip.enc.yaml`, `hov1-s3.yaml` | The database backup's account at hov1, and the site's address and CA |
| `kustomization.yaml` | Lists the files above and generates the two ConfigMaps below, each named with a hash of its content |
| `organization/` | `organization.json`, what the organization is, and `apply.py`, which makes it so; the ConfigMap `zulip-organization` |
| `brand/` | The icon and the two logos as PNG, rendered by `brand.sh`; the ConfigMap `zulip-brand` |
| `organization-job.yaml` | The Job that runs `apply.py` in a pod of Zulip's image, again on every change to the two ConfigMaps |
| `postgres-image.sh` | Builds the database image with Zulip's search dictionaries; not part of the artifact |
| `brand.sh` | Renders `brand/` from the design repository at a pinned commit; not part of the artifact |
| `push.sh` | Pushes that image, then this directory, into zot; not part of the artifact |
| `s3proof/` | Tests Zulip's S3 use against the osl1 gateway, in Go; not part of the artifact |

All `*.enc.yaml` files are encrypted to the cluster key and the two operators.

## Ship a change

Edit the files, commit, then push. The revision annotation names the commit, so commit first.

```sh
git commit ...
artifacts/zulip/push.sh             # your YubiKey PIN and one touch, for the fabrikk-ci credential
```

Flux applies the new artifact within ten minutes. To apply it now:

```sh
swamp behavior run dataverket-prod-kustomizations reconcile --input name=zulip --input namespace=flux-system \
  --input withSource=true
```

A change to `statefulset.yaml` restarts Zulip, which takes about two minutes. If `zulip-0` then crash-loops, fix the
cause, push again, and delete the pod: a StatefulSet does not replace a broken pod on its own.

```sh
swamp behavior run dataverket-prod-pods delete --input namespace=zulip --input podName=zulip-0
```

## Run a management command

Zulip's management commands run inside the pod as the user `zulip`. Open the admin session first
(`task admin:start`), and define this shorthand:

```sh
zmanage() { kubectl --context dataverket-prod-admin -n zulip exec zulip-0 -c zulip -- \
          runuser -u zulip -- /home/zulip/deployments/current/manage.py "$@"; }
```

For example, `zmanage list_realms` lists the organizations. A command that asks a question, such as `delete_realm`,
needs an interactive shell in the pod, since `kubectl exec` without a terminal gives it no input.

Zulip's own error log is in the pod. Zulip also mails every server error to the administrator, `admin@dataverket.org`.

```sh
kubectl --context dataverket-prod-admin -n zulip exec zulip-0 -c zulip -- tail -50 /var/log/zulip/errors.log
```

## The organization

`organization/organization.json` says what the organization is: its subdomain, empty for `forum.dataverket.org`
itself, its name and description, its owner, whether readers without an account may read, and which channels are
web-public. `brand/` holds its icon and two logos. The Job in `organization-job.yaml` makes the organization match,
by running `organization/apply.py` in a pod of Zulip's own image: `app:init` writes Zulip's settings from the same
env the StatefulSet has, then `manage.py shell` runs the file, so every change goes through Zulip's actions and lands
in the organization's audit log under the owner.

The Job runs again on every change. `kustomization.yaml` generates the two ConfigMaps with a hash of their content in
the name, so a change to the file, the code or the brand changes the Job's spec, and the force annotation on the Job
lets Flux recreate it, which runs it. A finished Job stays, so Flux has nothing to re-apply; a failed one fails the
`zulip` Kustomization, where `dataverket-prod-kustomizations list` shows it.

What the Job does, in order:

- **Creates the organization when the database holds none**, with the owner from the file, who then logs in through
  Zitadel: Zulip matches a login to an account by email, so the owner's Zitadel email must be the one in the file.
  Creation sends the owner Zulip's welcome mail and posts the welcome messages. On a database that holds an
  organization the file does not name, it refuses, so a wrong file on an empty database makes nothing.
- **On an existing organization, checks the owner.** The email in the file must be an active owner, or the Job fails;
  a wrong email never makes an account.
- **Sets the name, the description and spectator access**, each only when it differs.
- **Uploads the icon and the logos.** Zulip resizes on upload, so there is nothing to compare, and every run uploads
  and bumps their version numbers. That is the one thing a rerun changes.
- **Opens the channels.** Each listed channel is made to exist with its `webPublic` flag; with `publicChannels` set
  to `web-public`, every public channel is then made web-public, with history visible. Private channels stay private.

Reading without an account needs three settings, each of which alone does nothing: the server allows web-public
channels (`statefulset.yaml`, `SETTING_WEB_PUBLIC_STREAMS_ENABLED`, off in Zulip until set), the organization allows
them (`spectatorAccess`), and a channel is web-public. A visitor with no account then sees the open channels at
`https://forum.dataverket.org/`, can search and read, and is asked to log in to write. A channel made later is public
but not web-public until the Job runs again or someone opens it in its channel settings.

### The brand

Zulip shows four things of ours: the organization's name, its description, its icon and its logo. Everything else is
Zulip's own light or dark theme, which each person picks; there is no custom CSS. `brand.sh` renders the three images
from `dataverket/org`'s `design/build` at a pinned commit, following the design README's rules: the glyph, white on
the theme's navy, as the icon, which every square icon slot takes; and the wide mark as the logo, navy for the light
theme and white for the dark one. Zulip takes PNG, not SVG. A new mark is a new commit and three new hashes in the
script, then:

```sh
artifacts/zulip/brand.sh            # rewrites brand/; review the diff as pictures, then commit and push
```

librsvg's output can differ between versions, so a rerun on another machine may change the bytes without changing
the picture.

### After a fresh install, or a rebuild with no archive

The Job creates the organization. Then:

1. **Check that mail arrived.** The owner, `admin@dataverket.org`, gets Zulip's welcome mail. If not, run
   `zmanage send_test_email admin@dataverket.org` and read the error log.
2. **Log in.** Open `https://forum.dataverket.org/` and choose "Log in with Dataverket", as the owner. You must land in
   the owner account. If Zulip makes a new account instead, the Zitadel email and the one in the file differ.
3. **Decide who may join.** Go to Organization settings, then Organization permissions, and find "Are invitations
   required for joining the organization?". With "No", anyone who can log in to Zitadel gets an account. With "Yes",
   each person needs an invitation first.
4. **Test the rest.** Use two browser windows, logged in as two people.
   - Send a message in one. It should appear in the other without a reload.
   - Attach a file to a message, and change your avatar. Both should show in the other window.
   - Search for "organizations" after writing "organization". The search should find it.
   - Start a data export (Organization settings, then Data export) and download it.
   - Check that Valkey ran Zulip's rate limiter during the logins. The `cmdstat_evalsha` line should show calls
     above 0:

     ```sh
     kubectl --context dataverket-prod-admin -n zulip exec deploy/zulip-redis -- \
       sh -c 'valkey-cli --no-auth-warning -a "$REDIS_PASSWORD" INFO commandstats' | grep evalsha
     ```

     If it stays at 0, replace Valkey with Redis: one image in `services.yaml`.
5. **Turn off password login.** In `statefulset.yaml` and `organization-job.yaml`, set `ZULIP_AUTH_BACKENDS` to
   `GenericOpenIdConnectBackend` and update the comment. Ship the change. The login page should then offer only
   "Log in with Dataverket".

### If the Job fails

The `zulip` Kustomization reports it. Read the Job's log from the admin session, fix the cause, then delete the Job
and reconcile: Flux creates it again, which runs it again.

```sh
kubectl --context dataverket-prod-admin -n zulip logs job/zulip-organization
kubectl --context dataverket-prod-admin -n zulip delete job zulip-organization
swamp behavior run dataverket-prod-kustomizations reconcile --input name=zulip --input namespace=flux-system
```

When creating the organization failed, clean up first, or the next try fails too. A failed try is rolled back in
the database, but Zulip keeps some of its rows cached, in memcached and in every Zulip process, and the next try
then fails with "Client matching query does not exist". Restart memcached first, then Zulip:

```sh
swamp behavior run dataverket-prod-deployments restart --input namespace=zulip --input deploymentName=zulip-memcached
swamp behavior run dataverket-prod-pods delete --input namespace=zulip --input podName=zulip-0
```

A failed try can also leave an organization with no users, which the Job then refuses to touch, since it has an
organization but not the owner. Find its id with `zmanage list_realms`, then run `delete_realm -r <id>` in an
interactive shell in the pod. It asks for the organization's subdomain. For `forum.dataverket.org` itself the
subdomain is empty, so press Enter.

## What Zulip needs from the platform

Each line was learned while setting Zulip up. The first column is the fact, the second what we do about it.

| Fact | What we do |
|---|---|
| Zulip's full-text search needs three dictionary files in Postgres. CNPG's image does not have them | `postgres-image.sh` adds them to the CNPG image (below) |
| Zulip's image installs Postgres client tools for the version in `CONFIG_postgresql__version`, and it can only install version 14 | The setting is left out. Zulip talks to Postgres 18 without it |
| Zulip's own nightly backup uses `pg_dump` 14, which cannot read Postgres 18 | `AUTO_BACKUP_ENABLED` is off. CNPG backs up the database |
| Zulip's nginx and the browsers fetch uploads and avatars by the S3 gateway's public name | Zulip uses `https://dataverket.s3.osl1.dvkt.no`, not the in-cluster Service. `zulip-avatars` is public by policy |
| Zulip's S3 uploads carry metadata headers with underscores, such as `x-amz-meta-user_profile_id`. Envoy refuses those by default | `infrastructure/envoy/clienttrafficpolicy-s3.yaml` allows them on the S3 listener only |
| Zulip long-polls: a request can stay open for minutes | The route has no request timeout |
| Zulip trusts forwarded client addresses only from the proxies in `LOADBALANCER_IPS`, and rate-limits by that address | It lists Envoy's pod network, `10.244.0.0/16`. The Octavia load balancer sends Envoy each visitor's address with PROXY v2 (`infrastructure/envoy/`), so X-Forwarded-For names the visitor |
| Zulip's default no-reply address is on `forum.dataverket.org`, which has no mail domain | `ADD_TOKENS_TO_NOREPLY_ADDRESS` is off, so mail comes from `noreply@dataverket.org` |
| Zulip uses Redis for rate limits, through one Lua script and basic commands. Valkey implements all of them | Valkey 9.1 runs as `zulip-redis`. Redis can replace it with one image change |
| memcached needs a login, since Zulip sends one | memcached runs with SASL and the user `zulip@localhost` |
| Web-public channels are off on a self-hosted server until `WEB_PUBLIC_STREAMS_ENABLED` is set, and then off in the organization until it allows them | `statefulset.yaml` sets it; the organization Job opens the organization and its public channels |
| Zulip takes the organization's icon and logos as PNG, JPEG, GIF, WebP, AVIF, HEIC or TIFF, never SVG, and keeps them in the avatar bucket | `brand.sh` renders the design repo's SVG files with rsvg-convert, in the factory |
| The organization's name, owner, brand and channel flags are rows in the database and objects in the avatar bucket; no file or manifest sets them | `organization/apply.py` sets them through Zulip's own actions, run by a Job of the artifact in a pod of Zulip's image, whose `app:init` mode writes the settings from the env |

## Change the Postgres image

The database runs `platform/postgresql-zulip`, which is CNPG's Postgres image plus Zulip's three search files:
`en_us.dict` and `en_us.affix` from Debian's `hunspell-en-us`, and `zulip_english.stop` from Zulip's source.
`postgres-image.sh` builds it. Every input is pinned by sha256, so the same inputs always give the same digest.

To change it, edit the pins in the script, then:

```sh
artifacts/zulip/postgres-image.sh   # rebuilds and writes the new reference into postgres.yaml
git commit ...
artifacts/zulip/push.sh             # pushes the image first, then the manifests
```

CNPG reads the Postgres version from the image tag, so `postgres.yaml` names the image by tag and digest:
`:18.4-system-trixie@sha256:…`. For a new major version, change the base image, the tag and the `tsearch` path in
the script.

## After a rebuild

zot comes back empty after a rebuild (`docs/storage.md`, "Rebuild from git"). Run `push.sh` again from the checkout.
The database then restores itself from the hov1 archive, since `postgres.yaml` bootstraps by recovery, and the
organization Job finds the organization and leaves it as it is. If there is no archive to restore, the Job creates
the organization; then follow "After a fresh install, or a rebuild with no archive" above.
