# The www artifact

`www.dataverket.org`, the website, and `signal.dataverket.org`, a short link to the Dataverket Signal group. An nginx
pod behind the Gateway (`httproute.yaml`); the wildcard certificate on the `https` listener covers both names, and
external-dns makes the records from the routes. Delivered the way zot is: git holds the pointer,
`apps/www/source.yaml`; this directory is the artifact, pushed as it is by `push.sh` into zot as
`platform/www-config`, and Flux applies whatever the `current` tag holds, decrypting the Secret with the cluster key.

## Contents

| File | What |
|---|---|
| `site/index.html` | The website, a single self-contained page; `kustomization.yaml` turns `site/` into ConfigMap `www-site` |
| `nginx-conf.yaml` | nginx's configuration template, below |
| `deployment.yaml` | Two nginx-unprivileged replicas, image pinned by digest, `www-site` mounted over `/usr/share/nginx/html` |
| `service.yaml` | `www:80` |
| `httproute.yaml` | Both names on the `https` listener; on `http`, a 301 to https |
| `www-secrets.enc.yaml` | `SIGNAL_GROUP_LINK`, sops-encrypted to the cluster key and the operators |
| `push.sh` | Pushes this directory into zot; not part of the artifact |

## Ship a change

```sh
git commit ...                      # the revision annotation names the commit, so commit first
artifacts/www/push.sh               # one YubiKey touch for the fabrikk-ci credential
```

Flux picks up `current` within ten minutes. The ConfigMap's name carries a hash of the page, so a new page rolls the
Deployment by itself.

**https only.** The Gateway terminates TLS; plain http gets a 301 from the `www-redirect` route and never reaches the
pod. nginx adds `Strict-Transport-Security` to the website's responses so browsers stay on https.

## nginx

**Why a pod and not a `RequestRedirect` filter.** A Signal invite carries its payload in the URL fragment
(`https://signal.group/#...`). `RequestRedirect` can rewrite scheme, host, path, port and status, and has no fragment
field; nginx puts the fragment in the `Location` header verbatim.

**The configuration** (`nginx-conf.yaml`) is a template: the image's entrypoint runs envsubst over
`/etc/nginx/templates/*.template` into `/etc/nginx/conf.d/`, and only names present in the environment are
substituted, so `${SIGNAL_GROUP_LINK}` comes from Secret `www-secrets` while nginx's own `$host` and `$request_uri`
survive. The `return` line keeps its quotes: unquoted, nginx reads the invite's `#` as a comment and redirects to a
bare `https://signal.group/`. The second server block, the default, serves `www.dataverket.org` and takes everything else, probes included, since
probes arrive addressed to the pod IP. The emptyDir over `/etc/nginx/conf.d` hides the image's `default.conf`.

**Rotating the invite** is a new value in `www-secrets.enc.yaml` and a rollout: `envFrom` is read once per
container start.

```sh
kubectl -n www rollout restart deploy/www
```

The root filesystem is read-only; `conf.d`, the cache and `/tmp` are emptyDirs.

## After a rebuild

zot comes back empty (`docs/storage.md`, "Rebuild from git"), so Flux cannot fetch this artifact, and both names are
down, until `push.sh` has run again from the checkout.
