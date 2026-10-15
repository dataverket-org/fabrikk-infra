# The zulip artifact

Zulip is Dataverket's chat and forum, at `https://forum.dataverket.org`. People log in with their Zitadel account.
This directory holds everything Zulip runs on: the app, its database, three helper services and their secrets.

It is delivered the way zot is. `push.sh` pushes this directory into zot as `platform/zulip-config`. Git holds only
the pointer, `apps/zulip/source.yaml`, and Flux applies whatever the `current` tag holds. Flux decrypts the Secrets
with the cluster key. How it was built, step by step, is `docs/plans/2026-10-zulip.md`.

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
| `postgres-image.sh` | Builds the database image with Zulip's search dictionaries; not part of the artifact |
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

Zulip's management commands run inside the pod as the user `zulip`. Open the admin session first (`task admin:login`,
then `task admin:renew`), and define this shorthand:

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

## Set up the first organization

Zulip runs with no organization until someone makes one. Dataverket's was made on 2026-10-15. Follow these steps
again after a fresh install, or a rebuild with no database to restore.

1. **Check that mail works.** Creating the organization sends a confirmation email.
   Run `zmanage send_test_email admin@dataverket.org`. Two messages should arrive, one from `admin@dataverket.org` and
   one from `noreply@dataverket.org`. If they do not, read the error log.
2. **Make a creation link.** Run `zmanage generate_realm_creation_link`. It prints a link on
   `https://forum.dataverket.org/new/`, good for one organization. Keep it private until you have used it.
3. **Create the organization.** Open the link. Name it Dataverket. For the URL, choose `forum.dataverket.org` itself,
   with no subdomain. Use **the email of your Zitadel account**. Zulip matches a Zitadel login to an account by
   email, and step 7 turns password login off. Confirm the email Zulip sends, and set a password. You are now the
   owner.
4. **Decide who may join.** Go to Organization settings, then Organization permissions, and find "Are invitations
   required for joining the organization?". With "No", anyone who can log in to Zitadel gets an account. With "Yes",
   each person needs an invitation first.
5. **Test the Zitadel login.** Open a private browser window, go to `https://forum.dataverket.org/` and choose "Log in
   with Dataverket". Log in as a second person. They should land in Zulip. Then log out and do the same as yourself.
   You must land in your owner account. If Zulip makes a new account for you, your Zulip and Zitadel emails differ.
   Fix that before step 7.
6. **Test the rest.** Use two browser windows.
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
7. **Turn off password login.** In `statefulset.yaml`, set `ZULIP_AUTH_BACKENDS` to `GenericOpenIdConnectBackend`
   and update the comment above it. Ship the change. The login page should then offer only "Log in with Dataverket".

### If creating the organization fails

Zulip mails the error to `admin@dataverket.org`. Fix the cause first. Then clean up, or the next try fails too.

1. **Clear both caches.** A failed try is rolled back in the database, but Zulip keeps some of its rows cached, in
   memcached and in every Zulip process. The next try then fails with "Client matching query does not exist".
   Restart memcached first, then Zulip:

   ```sh
   swamp behavior run dataverket-prod-deployments restart --input namespace=zulip --input deploymentName=zulip-memcached
   swamp behavior run dataverket-prod-pods delete --input namespace=zulip --input podName=zulip-0
   ```

2. **Delete an empty organization.** A failed try can leave an organization with no users. Find its id with
   `zmanage list_realms`, then run `delete_realm -r <id>` in an interactive shell in the pod. It asks for the
   organization's subdomain. For `forum.dataverket.org` itself the subdomain is empty, so press Enter.
3. **Make a new creation link** (step 2 above) and try again.

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
| Zulip trusts forwarded client addresses only from the proxies in `LOADBALANCER_IPS`, and rate-limits by that address | It lists Envoy's pod network, `10.244.0.0/16` |
| Zulip's default no-reply address is on `forum.dataverket.org`, which has no mail domain | `ADD_TOKENS_TO_NOREPLY_ADDRESS` is off, so mail comes from `noreply@dataverket.org` |
| Zulip uses Redis for rate limits, through one Lua script and basic commands. Valkey implements all of them | Valkey 9.1 runs as `zulip-redis`. Redis can replace it with one image change |
| memcached needs a login, since Zulip sends one | memcached runs with SASL and the user `zulip@localhost` |

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
The database then restores itself from the hov1 archive, since `postgres.yaml` bootstraps by recovery. If there is
no archive to restore, set up the first organization again, as above.
