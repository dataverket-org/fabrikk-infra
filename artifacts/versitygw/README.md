# The versitygw artifact

The S3 service at the osl1 site, `dataverket.s3.osl1.dvkt.no`: one versitygw with the posix backend on one Cinder
volume, delivered the way zot is. Git holds the pointer, `apps/versitygw/source.yaml`; this directory is the artifact,
pushed as it is by `push.sh` into zot as `platform/versitygw-config`, and Flux applies whatever the `current` tag
holds, decrypting the Secret with the cluster key. The plan is `docs/plans/2026-10-s3-osl1.md`; what the gateway holds
and how it is read is `backup/README.md` once the model `osl1-s3` exists.

## Contents

| File | What |
|---|---|
| `namespace.yaml` | Namespace `versitygw` |
| `statefulset.yaml` | The gateway, image pinned by digest, one 20 GB `csi-cinder-standard-retain` claim with `/data`, `/versioning` and `/iam` as subPaths |
| `service.yaml` | `versitygw:7070`, the S3 API for in-cluster writers and the route; `versitygw-admin:7071`, the admin API, never routed |
| `httproute.yaml` | `dataverket.s3.osl1.dvkt.no` on the Gateway's `https-s3-osl1` listener, request timeout off; the `http` redirect |
| `versitygw-root.enc.yaml` | The root key pair, source of record, sops-encrypted to the cluster key and the two operators |
| `push.sh` | Pushes this directory into zot; not part of the artifact |

## Ship a change

```sh
git commit ...                      # the revision annotation names the commit, so commit first
artifacts/versitygw/push.sh         # one YubiKey touch for the fabrikk-ci credential
```

Flux picks up `current` within ten minutes. The StatefulSet replaces its one pod; the volume stays attached to the
same claim.

## Operate

- **In-cluster writers** use `http://versitygw.versitygw.svc.cluster.local:7070`, path-style, region `us-east-1`.
  Browsers and anything outside use the public name over TLS.
- **The admin API** is reached with `kubectl port-forward svc/versitygw-admin 7071 -n versitygw` and signed with the
  root key pair, from the operator's terminal; the `osl1-s3` model reads it that way. No account secret and no root
  key is ever in an argument, a data record or a log line.
- **Accounts and buckets**: one account per writer, role `user`, owner of one bucket, as on the hov1 site
  (`backup/versitygw/README.md`, "Security model"). A bucket that wants object lock is created with lock, which turns
  versioning on for it; versitygw has no lifecycle rules, so non-current versions stay until a client deletes them by
  version id.
- **The root key pair** lives here and, by a person's copy, in `vaults/operator/osl1/root.enc.json`. Rotate here first:
  new values in the Secret, push, then the copy.

## After a rebuild

zot comes back empty (`docs/storage.md`, "Rebuild from git"), so Flux cannot fetch this artifact until `push.sh` has
run again from the checkout. The gateway's volume is retained, so the data comes back with the claim; the root key
pair and the accounts are on it.
