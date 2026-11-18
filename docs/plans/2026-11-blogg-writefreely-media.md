# Plan: a blog on WriteFreely, with per-author media in S3 behind a Zitadel login

Written 2026-11-18 from an architecture summary that arrived as a pitch: WriteFreely for writing and ActivityPub,
a small Go and HTMX service for uploading images into per-tenant S3 buckets under Zitadel identities, Nginx in
front for caching, and Litestream to replicate WriteFreely's SQLite into S3. This plan keeps what fits the
platform as it is built, says what does not and why, and orders the work. Nothing is applied. Work in progress:
the open questions at the end decide the shape of goals 3 and 4.

## Status, 2026-11-18

**Not started.** Nothing exists for a blog: no artifact, no Zitadel application, no bucket, no name. What this plan
builds on is in place and read with swamp: the osl1 S3 gateway (`osl1-s3`: versitygw 1.9.0, internal IAM, two
accounts, three buckets, healthy), the upstream Zitadel instance with six projects and no blog client
(`zitadel-project`, `zitadel-app`), the Envoy Gateway with the `*.dataverket.org` certificate
(`infrastructure/envoy/`), and the www artifact as the pattern for a web pod behind it (`artifacts/www/`).

## What the summary asks for, and what it meets here

| The summary says | What the platform has | What this plan does |
|---|---|---|
| Nginx as the edge: path split, header split on `Accept: application/activity+json`, `proxy_cache` | Envoy Gateway is the edge; every service is an `HTTPRoute` (decision 031 names them, 034 places tenants). Nginx exists only as an app pod, `www` | The path split is an `HTTPRoute`: `/media/` to the gateway with a `URLRewrite`, the rest to WriteFreely. No cache in goal 2; a micro-cache is an nginx pod in front of WriteFreely if a measurement asks for it, goal 5 |
| A bucket per tenant, `tenant-<zitadel-sub>`, and per-tenant S3 credentials from Zitadel through STS (option A) or minted on first login through the admin API (option B) | One versitygw per org with internal IAM (029); accounts made with the admin CLI, one account owning one bucket, which the `osl1-s3` check enforces; standalone IAM with STS is a separate plan, not started, with five open questions (`docs/plans/2026-10-s3-zitadel.md`) | Goal 3 is one account and one bucket, `blogg-media`, with a prefix per author; the boundary between authors is the Go service's, which is also where it would be under option B, since the service does every upload. Option A is the natural second step once standalone IAM exists, goal 6 |
| Litestream streams SQLite to a bucket on the same gateway, and a read-only presentation service renders pages from a VFS replica | Backups go to the hov1 site (020); Zulip's Postgres already does. Litestream 0.5 is current; its VFS is marked experimental in every release | Litestream replicates to hov1, as backup and restore only. The VFS read path is dropped: WriteFreely itself cannot run on a read-only replica, as the summary says, and a second renderer is WriteFreely's templates rewritten in Go for a cache's worth of gain |
| An upload page of its own, the author pasting the Markdown tag into WriteFreely | WriteFreely has no image insert of its own (Snap.as is Write.as's hosted service), but its editor is one template file, replaceable with `editor = <name>` and `templates_parent_dir` | The upload service also serves the editor hook: our copy of the editor template adds an "Insert image" tool and a drop target on the text, which post to the service and put the returned tag at the cursor (goal 4) |
| "Zero JavaScript" | HTMX is 14 kB of JavaScript | "No JavaScript of our own": HTMX vendored by digest and served from the same origin, as the design system is in `www` |
| Users keyed by the `sub` claim, in bucket names and public URLs | `sub` is a person's stable identifier at the identity provider | Public URLs carry an opaque per-author id, not `sub` (question 4) |
| A reference Nginx configuration | | Broken as written; what it meant is in the appendix, for the nginx pod of goal 5 if it comes |

### What holds

- **WriteFreely** is alive: 0.17.3 fixed an authentication bypass in the API, 0.17.2 of 2026-08-10 a registration
  bypass, 0.17.1 added a mass account purge, 0.17 hardened ActivityPub. SQLite and MySQL or MariaDB are its databases; no Postgres, so CNPG is no help.
- **Login through Zitadel** without code of ours: WriteFreely's `[oauth.generic]` takes an OIDC provider's
  authorization, token and userinfo endpoints and a client id and secret; the callback is `/oauth/callback/generic`;
  `disable_password_auth` turns the password form off once it works. Authelia and Authentik publish the same
  recipe. One catch: a first OAuth sign-in creates the account only when `open_registration` is on, so who may
  write is decided at the identity provider, by which people the Zitadel application lets in, not in WriteFreely.
- **Media straight from the gateway.** A public-read bucket policy on `blogg-media` and an `HTTPRoute` that
  rewrites `/media/<author>/<key>` to the bucket path lets Envoy serve every image from versitygw with WriteFreely
  never in the path. Keys named by content hash make `Cache-Control: public, max-age=31536000, immutable` true.
- **Litestream** for the database: continuous replication of SQLite to S3, `restore -if-replica-exists` on start,
  a few megabytes of state. LTX replaced generations in 0.5; the format is stable.
- **The editor hook.** The editor is `templates/pad.tmpl`: a toolbar `<header id="tools">` whose `<div id="belt">`
  holds edit metadata, theme, view posts, preview and publish, and the textarea `#writer`. A copy of it under
  `templates_parent_dir`, named by `editor = <name>` in `config.ini`, adds an "Insert image" tool that opens the
  upload service in one of WriteFreely's modals and a drop target on the textarea that posts the file with `fetch`;
  both put the returned Markdown tag at the cursor. About forty lines of script of our own, inside an editor that is
  already script. The service must answer on the blog's host, under a path, so the call is same-origin and the
  cookie travels; a 401 opens the Zitadel login once, and Zitadel already knows the author from the WriteFreely
  login.
- **A stateless Go service** with `net/http`, `html/template` and HTMX: OIDC code flow with PKCE against
  `id.dataverket.org`, an encrypted `HttpOnly; Secure; SameSite=Lax` cookie, one multipart upload handler that
  streams to S3 and answers an HTML fragment. Built with ko and signed, the shape `zitadel-seed` takes in
  `docs/plans/2026-11-zitadel-github-and-dataverket-org.md`.

### What does not hold, or not yet

- **STS per login (option A)** needs versitygw's standalone IAM: a second process, one replica, the gateway failing
  closed without it, every account recreated. That is `2026-10-s3-zitadel.md`, and it waits for a human use of S3
  that justifies it. This plan is not that use: readers never touch S3, and authors upload through one service.
- **Per-user accounts on internal IAM (option B)** give one key pair per account, no quota, no policy language,
  and the secret is known only when the account is made, so the service would keep every author's key in a store
  of its own. That is a key store for no boundary the service does not already enforce. Not done.
- **The VFS replica as a read path** is experimental by Litestream's own label, and nothing we run can consume it:
  WriteFreely needs read-write at boot and for the ActivityPub inbox. Backup only.
- **Litestream to the same gateway** puts the backup beside the data on one Cinder volume at one site. Decision 020
  says hov1.
- **An image insert inside WriteFreely** does not exist to hook into: the self-hosted code has never shipped an
  upload, the maintainer's promise of one for 0.17 did not land, and the editor template has no image, upload or
  photo element. The hook is the template itself, below; its cost is a copy of `pad.tmpl` pinned to the WriteFreely
  version and re-diffed at every upgrade.
- **`sub` in public URLs** publishes a stable identifier of a person on every image. Replaced by an opaque id.
- **The Nginx configuration** has `map \(http_accept\)is_activitypub` for `map $http_accept $is_activitypub`,
  `proxy_pass http://127.0.0;` with no host or port, a regex location whose captures are escaped out of existence,
  `proxy_cache wf_cache` without a `proxy_cache_path` zone, and `proxy_cache_bypass` with its two variables
  joined into one name. The intent is right; the appendix has it as it would read.
- **"Zero JavaScript"** is not what HTMX is. The honest claim is above.

## What carries it

Desired state lives in what Flux applies, never in a swamp definition; swamp reads and asserts.

| Part | Where | Is |
|---|---|---|
| `artifacts/blogg/` | This repository, pushed into zot as `platform/blogg-config`, pointer in `apps/blogg/source.yaml`, the way `www` and `versitygw` are delivered | Namespace, WriteFreely StatefulSet with one Cinder claim, Litestream sidecar and restore init container, the Go service's Deployment, Services, the `HTTPRoute`, and the Secrets sops-encrypted to the cluster key |
| WriteFreely's image | Upstream `writeas/writefreely` 0.17.3, mirrored into zot by digest (`2026-10-registry-mirror.md`, decision 035) | Run as is; `config.ini` from a ConfigMap plus a Secret for the OAuth client secret |
| The editor template | `artifacts/blogg/editor/`: upstream `pad.tmpl` at the pinned version, our patch, and the result as a ConfigMap mounted at `templates_parent_dir` | `editor = dataverket` in `config.ini`; a check in the artifact's push script that the patch still applies to the pinned version, so an upgrade cannot silently drop the hook |
| Litestream's image | Upstream 0.5.x, mirrored by digest | Sidecar; its target is a bucket on hov1 with the gateway's CA, the shape of `artifacts/zulip/hov1-s3.yaml` |
| `dataverket/blogg-media` | Its own repository on the forge, one Go module, image `registry.dataverket.org/dataverket/blogg-media` built by ko, signed by cosign once the gitless plan's key exists | The upload service. Name open, question 1 |
| Two Zitadel applications | One project `blogg` with two OIDC clients, WriteFreely's and the service's, in `zitadel-seed`'s `identity.json` once that plan lands; by hand through `zitadel-app` until then | Client secrets written by a person into the sops files; definitions name them |
| Bucket and account | `user.sh` on the gateway mints account `blogg` owning `blogg-media`, a tier 3 credential with a named owner (001); the public-read policy on the bucket | The `osl1-s3` model reads it; its check keeps the one-account-one-bucket rule true |
| swamp | `zitadel-app` and `zitadel-project` for the clients, `osl1-s3` for the bucket and policy, an `@dataverket/http` endpoint `blogg` for health, the same reads as assertions in the health workflow | No extension release is part of the result |

## Goals, in order

1. **Name and host.** The blog is an organization service, so `<name>.dataverket.org` (031). WriteFreely's host is its
   federation identity, `@author@<host>`, and cannot change later without every follower lost. Question 1 decides
   it before anything is deployed; `blogg.dataverket.org` is the working assumption.
2. **WriteFreely alone**, on a kind cluster first, then osl1: SQLite on a Cinder claim, Litestream to a hov1 bucket,
   restore proven by deleting the pod's volume on kind and watching it come back, login through Zitadel with the
   password form off, registration as question 2 decides, `HTTPRoute` on the `https` listener. Federation checked
   from a Mastodon account: WebFinger, follow, a post arriving.
3. **Media.** Account and bucket on the osl1 gateway, public-read policy, the `/media/` route with its rewrite,
   `Cache-Control` from the gateway or added at the route. Checked with one object put by hand.
4. **The upload service and the editor hook.** OIDC login, session cookie, upload limited to images of a size
   (question 3), key by content hash under an opaque author prefix (question 4), the HTML fragment with the Markdown
   tag, a CSRF token in the form, and a JSON answer for the editor's `fetch`. Routed under the blog's host at
   `/media-upload/`. Then the editor template: the tool, the drop target, the insert at the cursor, tried on the
   kind cluster against the pinned WriteFreely. ko, signed, the manifests in the artifact. The service holds the one
   S3 credential, from the sops Secret.
5. **If needed, a cache.** Measured first: WriteFreely renders a page in milliseconds and the readership is small. If
   a cache is wanted, an nginx-unprivileged pod in front of WriteFreely with the configuration of the appendix,
   bypassing on the ActivityPub `Accept` and on WriteFreely's session cookie.
6. **Later: the gateway enforcing the boundary.** When `2026-10-s3-zitadel.md` brings standalone IAM, the service
   exchanges each author's ID token for STS credentials scoped to a bucket of their own, and goal 3's single bucket
   becomes one per author. The service's code changes in one place; the URLs do not.

## What must be settled

1. **The name**, of the host and of the service's repository. `blogg.dataverket.org` and `blogg-media` are proposals.
2. **Who may write.** WriteFreely creates an account on the first OAuth login only with `open_registration` on, so the
   Zitadel application decides: everyone in the `dataverket` organization, a role, or a list. The GitHub login plan
   makes the organization something people register into, which widens that door; a role is the likely answer.
3. **What may be uploaded**: image types, a size limit, and whether EXIF is stripped. Stripping means decoding and
   re-encoding in Go; not stripping publishes camera and location data an author did not mean to.
4. **The opaque author id** in URLs and keys: WriteFreely's collection alias, which the author chose and may change,
   or an HMAC of `sub` under a key the service holds, which never changes and names nobody.
5. **Deleting.** versitygw has no lifecycle rules (`2026-10-versitygw-lifecycle.md`); an author leaving means the
   service, or a person with the account, deletes the prefix. Who, and on what request.
6. **Whether a cache is wanted at all** before goal 5 is written.
7. **The hook's shape**: the toolbar tool, the drop target, or both; and whether pasting an image from the clipboard
   should upload too, which the same script can do.

## Appendix: the Nginx configuration as it would read

For goal 5 only, inside an nginx-unprivileged pod behind the Gateway; the media split is the `HTTPRoute`'s and is
not here. The session cookie's name is WriteFreely's and is read from its source before this is used.

```nginx
proxy_cache_path /var/cache/nginx/wf levels=1:2 keys_zone=wf_cache:10m max_size=512m inactive=1h;

map $http_accept $is_activitypub {
    default 0;
    "~*application/(activity|ld)\+json" 1;
}

server {
    listen 8080;
    server_name blogg.dataverket.org;

    # federation, API and authoring: never cached
    location ~ ^/(\.well-known|api|login|logout|me|admin|oauth) {
        proxy_pass http://writefreely:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto https;
    }

    # public pages: cached for anonymous readers, bypassed for the fediverse and for a session
    location / {
        proxy_pass http://writefreely:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_cache wf_cache;
        proxy_cache_key "$scheme$host$request_uri";
        proxy_cache_bypass $is_activitypub $cookie_SESSION;
        proxy_no_cache $is_activitypub $cookie_SESSION;
        proxy_cache_valid 200 10m;
        add_header X-Cache-Status $upstream_cache_status;
    }
}
```
