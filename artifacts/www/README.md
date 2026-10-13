# The www artifact

`www.dataverket.org`, the website, and `signal.dataverket.org`, a short link to the Dataverket Signal group. An nginx
pod behind the Gateway (`httproute.yaml`); the wildcard certificate on the `https` listener covers both names, and
external-dns makes the records from the routes. Delivered the way zot is: git holds the pointer,
`apps/www/source.yaml`; this directory is the artifact, pushed as it is by `push.sh` into zot as
`platform/www-config`, and Flux applies whatever the `current` tag holds, decrypting the Secret with the cluster key.
The website itself is a second image, `platform/www-site`, built from `site/` by `site.sh` and mounted into the pods
as an image volume; the manifests name it by digest.

## Contents

| File | What |
|---|---|
| `site/` | The website: `index.html`, its layout in `site.css`, and `static/`, the design system, below |
| `site.sh` | Builds `site/` into the `www-site` image and writes its digest into `deployment.yaml`; not part of the artifact |
| `nginx-conf.yaml` | nginx's configuration template, below |
| `deployment.yaml` | Two nginx-unprivileged replicas, image pinned by digest, the `www-site` image mounted read-only over `/usr/share/nginx/html` |
| `service.yaml` | `www:80` |
| `httproute.yaml` | Both names on the `https` listener; on `http`, a 301 to https |
| `www-secrets.enc.yaml` | `SIGNAL_GROUP_LINK`, sops-encrypted to the cluster key and the operators |
| `push.sh` | Pushes the `www-site` image, then this directory, into zot; not part of the artifact |

## Ship a change

```sh
artifacts/www/site.sh               # after a change in site/: rebuilds, writes the new digest into deployment.yaml
git commit ...                      # the revision annotation names the commit, so commit first
artifacts/www/push.sh               # PIN and one YubiKey touch for the fabrikk-ci credential; a real terminal, not `!`
```

Flux picks up `current` within ten minutes. A new page is a new digest in `deployment.yaml`, so it rolls the
Deployment by itself, one pod at a time.

## The website image

`site.sh` builds `site/` into one layer with every file owned by root, mode 0644, mtime 0, and the platform set to
`linux/amd64`, in crane's in-memory registry on a free local port. The same `site/` gives the same digest on any
machine with the same crane, so the digest is committed before anything is pushed, and `site.sh --check`, which
`push.sh` runs, refuses a `site/` that no longer builds to it. A crane upgrade may change the compression and with it
the digest; then `site.sh` and a commit is all it takes.

The pods mount it with an image volume (Kubernetes 1.36, containerd 2.3): the kubelet pulls it like any image, from
`registry.dataverket.org` with anonymous pull, and containerd mounts its filesystem read-only. No CSI driver and no
volume claim are involved; it lives in the node's image store on the EPHEMERAL partition and goes with image garbage
collection. There is no size limit beyond that, and subdirectories work.

`site/static/` is the design system, copied from `org/design` at `ceaa951` (Designsystemet 1.23.0): its CSS, the
generated theme, `dataverket.css`, the favicon and Inter. The page loads nothing from outside its own origin.
`site/site.css` is the page's layout, in tokens only. To follow a new version of the design system, copy the same
files again and run `site.sh`.

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

zot comes back empty (`docs/storage.md`, "Rebuild from git"), so Flux cannot fetch this artifact or the pods the
website image, and both names are down, until `push.sh` has run again from the checkout.
