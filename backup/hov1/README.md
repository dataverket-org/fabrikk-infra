# Site: hov1

The first instance of the stack in `../versitygw/`, and the backup target of dataverket-prod. What is written here and
by whom: `../README.md`. How the stack runs and every runbook: `../versitygw/README.md`. This page holds only what makes
the site hov1.

## Facts

| | |
|---|---|
| Endpoint | `https://213.128.185.82:443`, path-style |
| Region | `us-east-1` |
| Trust | The site's private CA root in `certs/ca.crt`, made 2026-09-20 with `step`, valid three years; delivered as Secret `hov1-s3` to `forgejo` and `zitadel` |
| Buckets | `cnpg-forgejo`, `cnpg-zitadel`, `restic-forgejo`; one account each, named after the bucket |
| Host | The hov1 site, Docker Compose 2.24 or newer; port 443 forwarded to the gateway |
| Data | `DATA_DIR` and `VERSIONS_DIR` per `.env`, on an xattr filesystem |
| Name | None. `s3.hov1.dvkt.no` through DirectAdmin's DNS API for `dvkt.no` is the day an address change should not touch every client; not needed before |

## Files

| File | Committed | Purpose |
|---|---|---|
| `compose.yaml` | yes | Includes `../versitygw/compose.yaml` with this directory as project directory |
| `.env.example` | yes | Template for `.env` |
| `.env` | never | The site's values and root key pair; also in the operator's password manager |
| `certs/ca.crt` | yes | The CA root every client pins |
| `certs/ca.key` | never | The CA key; also in the operator's password manager, so a rebuilt host keeps the same root |
| `certs/tls.*` | never | The gateway's certificate and key, written by `bin/cert` |

## Operating it

From this directory: `docker compose ps`, `docker compose logs --tail 100`, `docker compose restart`. Accounts and
certificates are the scripts in `../versitygw/bin`, run from here. A swamp model for the lifecycle is the follow-up
noted in `../README.md`.

## Bring-up

1. `cp .env.example .env`; fill it in.
2. On the host: create `DATA_DIR` and `VERSIONS_DIR`; forward 443.
3. `../versitygw/bin/cert`.
4. Commit `certs/ca.crt`; put `.env` and `certs/ca.key` in the password manager.
5. Writers: `../versitygw/README.md`, runbook "Add a writer", for `forgejo` and `zitadel`.

## When the address changes

`../versitygw/README.md`, runbook "Change the address": new `S3_ADDR`, `bin/cert`, `bin/site-secret` into
`apps/forgejo/hov1-s3.yaml` and `apps/zitadel/hov1-s3.yaml`, commit. The certificate and two plaintext Secrets change;
no writer key does.

## When the host is lost

The cluster keeps running; only the target is gone. `../versitygw/README.md`, runbook "Site host lost". Until the next
base backup completes there is no restorable copy.
