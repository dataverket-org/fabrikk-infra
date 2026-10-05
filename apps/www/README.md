# www

`signal.dataverket.org`, a short link to the Dataverket Signal group, and the home of the website when there is
one. An nginx pod behind the Gateway (`httproute.yaml`); the wildcard certificate on the `https` listener covers the
name, and external-dns makes the record from the route.

**Why a pod and not a `RequestRedirect` filter.** A Signal invite carries its payload in the URL fragment
(`https://signal.group/#...`). `RequestRedirect` can rewrite scheme, host, path, port and status, and has no fragment
field; nginx puts the fragment in the `Location` header verbatim.

**The configuration** (`nginx-conf.yaml`) is a template: the image's entrypoint runs envsubst over
`/etc/nginx/templates/*.template` into `/etc/nginx/conf.d/`, and only names present in the environment are
substituted, so `${SIGNAL_GROUP_LINK}` comes from Secret `www-secrets` while nginx's own `$host` and `$request_uri`
survive. The `return` line keeps its quotes: unquoted, nginx reads the invite's `#` as a comment and redirects to a
bare `https://signal.group/`. The second server block, the default, takes everything else, probes included, since
probes arrive addressed to the pod IP. The emptyDir over `/etc/nginx/conf.d` hides the image's `default.conf`.

**Rotating the invite** is a new value in `www-secrets.enc.yaml` and a rollout: `envFrom` is read once per
container start.

```sh
kubectl -n www rollout restart deploy/www
```

The root filesystem is read-only; `conf.d`, the cache and `/tmp` are emptyDirs.
