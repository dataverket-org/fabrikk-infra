# The zulip artifact

Zulip at `forum.dataverket.org`, delivered the way zot is: git holds the pointer, `apps/zulip/source.yaml`; this
directory is the artifact, pushed by `push.sh` into zot as `platform/zulip-config`, and Flux applies whatever the
`current` tag holds, decrypting the Secrets with the cluster key. The plan is `docs/plans/2026-10-zulip.md`; so far the
artifact is the database alone (its step 4), the app follows.

## Contents

| File | What |
|---|---|
| `namespace.yaml` | Namespace `zulip` |
| `postgres.yaml` | `Cluster zulip-postgres`: one instance on a 10Gi `csi-cinder-sc-delete` volume, archiving to the hov1 site |
| `backup.yaml` | The `ObjectStore` on bucket `cnpg-zulip` at hov1, 14 days, and a daily base backup at 03:15 |
| `hov1-s3.yaml` | The hov1 site's endpoint and CA, from `backup/versitygw/bin/site-secret` |
| `s3-cnpg-zulip.enc.yaml` | The `cnpg-zulip` account on hov1, sops-encrypted to the cluster key and the two operators |
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

## After a rebuild

zot comes back empty (`docs/storage.md`, "Rebuild from git"): run `push.sh` again from the checkout. Once the first
base backup is on hov1, `postgres.yaml` bootstraps by recovery from that archive, so the database comes back with it.
