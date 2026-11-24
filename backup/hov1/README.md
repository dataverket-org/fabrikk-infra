# Site: hov1

The backup target of dataverket-prod, as the cluster sees it. The gateway is a service of the hov1 site and lives in
the `hov1` repository, a checkout beside this one (`../hov1` from the repository root): its scripts,
runbooks and secrets are in `s3/` and `vaults/operator/s3/` there. What is written here and by whom: `../README.md`.
This page holds what a client of the site needs, and how to check what the gateway holds.

## Facts

| | |
|---|---|
| Endpoint | `https://213.128.185.82:443`, path-style |
| Region | `us-east-1` |
| Trust | The site's private CA root in `certs/ca.crt`, made 2026-09-20 with `step`, valid three years; delivered as Secret `hov1-s3` to `forgejo`, `zitadel` and `zulip` |
| Buckets | `cnpg-forgejo`, `cnpg-zitadel`, `cnpg-zulip`; one account each, named after the bucket; `kopia-forgejo` when the repositories get a backup of their own |
| Name | None. `s3.hov1.dvkt.no` is for the day an address change should not touch every client; not needed before |

## Files

| File | Purpose |
|---|---|
| `certs/ca.crt` | The CA root every client pins; a copy of `s3/certs/ca.crt` in the `hov1` repository, read by the model `hov1-s3` |

The Secrets the writers read are with each writer: `artifacts/<name>/hov1-s3.yaml`, the endpoint, region and CA
root in plain, and `artifacts/<name>/s3-<bucket>.enc.yaml`, the writer's key pair. Both are made at the site and
piped into this repository (`s3/README.md` in the `hov1` repository, runbook "Add a writer").

## Checking what the gateway holds

The model `hov1-s3` (`models/@dataverket/versitygw/gateway/hov1-s3.yaml`) reads the admin API on the site host's
loopback, the S3 API at the endpoint above and the CA root from `certs/ca.crt`. It runs on the site host. `health`
needs no key; the rest sign with the root key pair, supplied from the `hov1` repository for one run:

```sh
swamp model method run hov1-s3 health
sops exec-env ../hov1/vaults/operator/s3/root.enc.json 'swamp model method run hov1-s3 inventory'   # one touch
swamp model method run hov1-s3 check
```

## When the address or the root changes

The site's runbooks "Change the address" and "Reissue the certificate" (`s3/README.md` in the `hov1` repository) end
here: `bin/site-secret` per writing namespace into `artifacts/<name>/hov1-s3.yaml`, for a new root also the new
`certs/ca.crt`, for a new address also `s3Url` in the model, then a commit. Plaintext Secrets change; no writer key
does.

## When the host is lost

The cluster keeps running; only the target is gone. The site's runbook "Site host lost" rebuilds it. Until the next
base backup completes there is no restorable copy.
