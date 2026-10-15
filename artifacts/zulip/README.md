# The zulip artifact

Zulip at `forum.dataverket.org`, delivered the way zot is: git holds the pointer, `apps/zulip/source.yaml`; this
directory is the artifact, pushed by `push.sh` into zot as `platform/zulip-config`, and Flux applies whatever the
`current` tag holds, decrypting the Secrets with the cluster key. The plan is `docs/plans/2026-10-zulip.md`.

## Contents

| File | What |
|---|---|
| `namespace.yaml` | Namespace `zulip` |
| `postgres.yaml` | `Cluster zulip-postgres`: one instance on a 10Gi `csi-cinder-sc-delete` volume, archiving to the hov1 site |
| `backup.yaml` | The `ObjectStore` on bucket `cnpg-zulip` at hov1, 14 days, and a daily base backup at 03:15 |
| `services.yaml` | RabbitMQ, memcached with SASL, and Valkey as `zulip-redis`, official images by digest, no volumes |
| `statefulset.yaml` | Zulip itself, its Service, and the routes for `forum.dataverket.org` on the `https` and `http` listeners |
| `zulip-secrets.enc.yaml` | The secrets a restore needs kept (`secret_key`, `avatar_salt`, `shared_secret`, `camo_key`, `zulip_org_id`, `zulip_org_key`) and the three service passwords, generated straight into sops |
| `zulip-mailer.enc.yaml` | Forgejo's Nordhost mailbox, `username` and `password`, a copy of `apps/forgejo/forgejo-mailer.enc.yaml` |
| `hov1-s3.yaml` | The hov1 site's endpoint and CA, from `backup/versitygw/bin/site-secret` |
| `s3-cnpg-zulip.enc.yaml` | The `cnpg-zulip` account on hov1, sops-encrypted to the cluster key and the two operators |
| `zulip-zitadel-oidc.enc.yaml` | The OIDC client `forum.dataverket.org` in Zitadel project `zulip`: `CLIENT_ID` and `CLIENT_SECRET`, sealed by a person from swamp's vault (operator rule 3) |
| `s3-zulip.enc.yaml` | The `zulip` account on the osl1 gateway, owner of `zulip-uploads` and `zulip-avatars`, for the app |
| `postgres-image.sh` | Builds `platform/postgresql-zulip`, the CNPG image with Zulip's search dictionaries, and writes its reference into `postgres.yaml`; not part of the artifact |
| `push.sh` | Pushes that image, then this directory, into zot; not part of the artifact |
| `s3proof/` | The S3 proofs against the osl1 gateway, in Go on tusd's AWS SDK; not part of the artifact |

## Ship a change

```sh
artifacts/zulip/postgres-image.sh   # only after changing its pins: rebuilds, writes the new reference into postgres.yaml
git commit ...                      # the revision annotation names the commit, so commit first
artifacts/zulip/push.sh             # PIN and one YubiKey touch for the fabrikk-ci credential
```

## The Postgres image

CNPG's image lacks the three files Zulip's full-text search reads from `tsearch_data`, and its image-volume
extensions cannot carry them, so `postgres-image.sh` appends one layer to the pinned CNPG image: `en_us.dict` and
`en_us.affix` from Debian trixie's `hunspell-en-us`, and `zulip_english.stop` from Zulip's source at its tag. Every
input is pinned by sha256 and the layer is fixed in owner, mode and mtime, so git carries the digest before the push.
CNPG reads the Postgres version from the tag and refuses a digest alone, hence `:18.4-system-trixie@sha256:…`. A
Postgres upgrade is a new base digest and major in the script, a rebuild, and the major in `tsearch`.

## First organization, once

Zulip runs with no organization until an owner makes one. Every step below is a command or a page; do them in
order, from a machine with the admin session open (`task admin:login`, then `task admin:renew`, which writes the
`dataverket-prod-admin` kube context). `zmanage` in the commands is a shorthand to define first:

```sh
zmanage() { kubectl --context dataverket-prod-admin -n zulip exec zulip-0 -c zulip -- \
          runuser -u zulip -- /home/zulip/deployments/current/manage.py "$@"; }
```

1. **Mail works.** Creating the organization sends a confirmation email, so prove mail first:
   `zmanage send_test_email you@example.org`, with your own address. The message arrives from `noreply@dataverket.org`
   through Forgejo's Nordhost mailbox (`zulip-mailer.enc.yaml`). If it does not, read
   `kubectl --context dataverket-prod-admin -n zulip exec zulip-0 -c zulip -- tail -50 /var/log/zulip/errors.log`.
2. **The creation link.** `zmanage generate_realm_creation_link` prints a URL on `https://forum.dataverket.org/new/`,
   good for one organization. Treat it as a secret until it is used.
3. **The organization.** Open the link. Name: Dataverket. Organization URL: the option that is
   `forum.dataverket.org` itself, with no subdomain in front. Email: **the address of your Zitadel account**, since
   Zulip matches a Zitadel login to an account by its email, and step 7 turns password login off. Confirm the email
   that arrives, set your name and a password; you are the organization's owner.
4. **Who may join.** In Zulip, gear menu, Organization settings, Organization permissions: "Are invitations required
   for joining the organization?" With "No", anyone who can log in to Zitadel and press "Log in with Dataverket" gets an
   account at once (`auto_signup` in `statefulset.yaml` skips the sign-up form); Zitadel then decides who that is.
   With "Yes", each person needs an invitation first. Choose, and save.
5. **The Zitadel login, proven.** In a private browser window, `https://forum.dataverket.org/`, "Log in with
   Dataverket", and log in to Zitadel as a second person: they land in Zulip, invited or not as step 4 decided. Then
   log out and do the same as yourself: you must land in your owner account, not a new one. If you get a new account,
   your Zulip and Zitadel emails differ; fix that before step 7.
6. **The rest of the install, proven,** with the two browser windows open:
   - Send a message from one; it appears in the other with no reload (the long-poll through Envoy).
   - Attach a file to a message, open it from the other window, and change your avatar; both are served from the
     osl1 buckets `zulip-uploads` and `zulip-avatars`.
   - Search for a word from a message, in another form ("organizations" finds "organization"): the dictionary in
     `postgresql-zulip` is in use.
   - Organization settings, Data export: start an export and download it when it is ready.
   - Valkey ran Zulip's rate limiter for those logins:
     `kubectl --context dataverket-prod-admin -n zulip exec deploy/zulip-redis -- sh -c 'valkey-cli --no-auth-warning -a "$REDIS_PASSWORD" INFO commandstats' | grep -E 'evalsha|script'`
     shows `cmdstat_evalsha` with calls above 0; if it never does, Redis replaces Valkey (one image in
     `services.yaml`, `docs/plans/2026-10-zulip.md`, decision A).
7. **Password login off.** In `statefulset.yaml`, set `ZULIP_AUTH_BACKENDS` to `GenericOpenIdConnectBackend` and drop
   "email and password until the first owner is in" from the comment above it. Commit, `artifacts/zulip/push.sh`, and
   `swamp behavior run dataverket-prod-kustomizations reconcile --input name=zulip --input namespace=flux-system
   --input withSource=true`. The pod restarts on the new revision; the login page then offers only "Log in with
   Dataverket". Should `zulip-0` crash-loop on a new revision, the StatefulSet does not replace it by itself:
   `swamp behavior run dataverket-prod-pods delete --input namespace=zulip --input podName=zulip-0` after the fix is
   pushed.
8. **The administrator address** is `admin@dataverket.org` (`SETTING_ZULIP_ADMINISTRATOR` in `statefulset.yaml`),
   shown as the contact address and sent error mail; Zulip's mail goes out as plain `noreply@dataverket.org`.

If creating the organization fails halfway (on 2026-10-15 an S3 header Envoy refused, then a cache that outlived
the rollback), clean up before trying again:

- Restart memcached: `swamp behavior run dataverket-prod-deployments restart --input namespace=zulip --input
  deploymentName=zulip-memcached`. A rolled-back attempt leaves cached rows the database no longer has.
- An organization left with no users is deleted, not repaired: `zmanage list_realms` names its numeric id, then
  `zmanage delete_realm -r <id>` run in an interactive shell inside the pod, since the command reads its confirmation
  from a terminal and the pipe through `kubectl exec` gives it none. The confirmation it wants is the organization's
  subdomain, which for `forum.dataverket.org` itself is empty: press Enter. Then a new link from step 2.

What remains of `docs/plans/2026-10-zulip.md` after this is its restore test and documentation.

## After a rebuild

zot comes back empty (`docs/storage.md`, "Rebuild from git"): run `push.sh` again from the checkout. Once the first
base backup is on hov1, `postgres.yaml` bootstraps by recovery from that archive, so the database comes back with it.
