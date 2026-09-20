# backup/hov1: the home site

The backup target for dataverket-prod: an S3 endpoint at `213.128.185.82:443`, versitygw with the posix backend in
Docker at the hov1 home site, written to by the CNPG Barman Cloud plugin and by restic. It is the copy that lives in a
different building, on a different network, under a different provider's mistakes. This folder is the whole site:
`docker compose` here, on the home host, is how it runs.

## Layout

| Path | What |
|---|---|
| `compose.yaml` | versitygw (posix backend, TLS, the admin API on an unpublished listener), step-ca, and step-renew |
| `.env` | Root keys, directories, the public address, step-ca's password; copied from `.env.example`, ignored by git |
| `certs/` | `ca.crt`, step-ca's root, is committed and is what every client pins; the server certificate and key are not |
| `bin/cert` | First run brings step-ca up and exports the root; every run issues the gateway's certificate for the address |
| `bin/renew-hook.sh` | What step-renew runs after a renewal: restart versitygw over the Docker socket |
| `bin/user` | Mints one account for one bucket on the running gateway and hands it the bucket |

## The gateway

versitygw serves `${DATA_DIR}` as the gateway root: every top-level directory is a bucket, every file an object, and
the object's S3 metadata is xattrs, so the filesystem must carry them (ext4 and xfs do). Previous versions of objects
go to `${VERSIONS_DIR}`, which must lie outside the root. IAM (the accounts and their keys) is the internal directory
backend on the `iam` volume; the root key pair from `.env` is the account that mints users and nothing else.

Buckets are created with the root key once, and every writer gets its own account with the `user` role, which sees
only buckets handed to it (`change-bucket-owner`), so a leaked writer key reaches one bucket. The writers
the plan expects, one account each, named after the bucket:

| Bucket | Writer |
|---|---|
| `cnpg-forgejo` | Barman Cloud plugin, Forgejo's Postgres |
| `cnpg-zitadel` | Barman Cloud plugin, Zitadel's Postgres |
| `restic-forgejo` | restic, the Forgejo repositories |

Their credentials are authored in `apps/` as encrypted Secrets and copied to the `infra` vault (decision 005);
nothing in this folder records them.

## The address and the certificate

Clients reach the gateway by address, not by name: nothing in the backup path depends on DNS, a zone, or DirectAdmin.
The price is the certificate: no public CA issues a durable certificate for a bare address (Let's Encrypt's are
six-day and HTTP-01 only), so the site runs its own CA, step-ca, in the same compose file. It initialises itself on
first start; `bin/cert` widens its `admin` provisioner from 24-hour certificates to 30 days, exports the root as
`certs/ca.crt`, and issues the gateway's certificate with the address as its SAN. The root is committed here and
pinned by every client, the Barman `ObjectStore`'s `endpointCA` and restic's `RESTIC_CACERT`; the
password in `.env` encrypts the CA's keys and is never needed by a client. `step-renew` renews at two thirds of the
lifetime over mTLS with the current certificate and restarts versitygw, which reads its files at start only. The same
CA can later issue for anything else on the site, or for the cluster through cert-manager's step-issuer.

Requests are path-style (`https://213.128.185.82/cnpg-forgejo/...`); virtual-host addressing needs a name and is not
offered. If the address ever changes, every client's endpoint and the certificate change with it; a name
(`s3.hov1.dvkt.no`, set through DirectAdmin's DNS API for `dvkt.no`) is the day that stops being true, and is not needed
before.

## First start

```sh
cp .env.example .env    # fill it in; mkdir the two directories on an xattr filesystem; forward 443 to this host
bin/cert                # step-ca up, certs/ca.crt to commit, the gateway's certificate, the whole stack up
```

Then, with the root key and `--ca-bundle certs/ca.crt`, once per bucket:
`aws --endpoint-url https://213.128.185.82 s3 mb s3://cnpg-forgejo`,
`aws s3api put-bucket-versioning --bucket cnpg-forgejo --versioning-configuration Status=Enabled`, and
`bin/user cnpg-forgejo`, which mints the writer and makes it the bucket's owner. Versioning is what lets a deleted
archive come back; versitygw offers no lifecycle rule on this path, so retention is the writers' job (Barman's
`retentionPolicy`, restic's `forget`).

## What is not here

Backups of the gateway itself: it is the backup. If the disk under `${DATA_DIR}` dies, the cluster still runs and the
next base backup rebuilds the archive. A second copy elsewhere is a decision for the plan, not for this folder.
