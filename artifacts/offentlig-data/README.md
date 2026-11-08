# The offentlig-data artifact

`offentlig-data.dataverket.org` serves the public overview site built in `../offentlig-data`.
The site image is `registry.dataverket.org/dataverket/offentlig-data:latest` (tenant-first, decision 034); this directory is a separate
Flux config artifact, pushed as `platform/offentlig-data-config` by `push.sh`. The pointer is
`apps/offentlig-data/source.yaml`.

`deployment.yaml` manages a two-replica ReplicaSet of unprivileged nginx pods. The image listens
on port 8080 and serves `/healthz`; `service.yaml` exposes it on port 80. `httproute.yaml` uses
the Gateway's wildcard HTTPS listener, with an HTTP-to-HTTPS redirect. external-dns creates
the DNS record from the route.

## Ship

```sh
git add artifacts/offentlig-data apps/offentlig-data apps/kustomization.yaml
git commit -m 'Add offentlig-data site artifact'
artifacts/offentlig-data/push.sh  # requires a terminal and the operator YubiKey
```

Flux picks up the `current` config artifact within ten minutes. The container image has already
been published separately. `latest` is mutable: moving it does **not** roll out existing pods,
even with `imagePullPolicy: Always`. For subsequent releases, pin the image by digest in
`deployment.yaml`, commit and push a new config artifact to trigger a rolling update. After
zot is rebuilt empty, push the site image again and then rerun `push.sh`.
