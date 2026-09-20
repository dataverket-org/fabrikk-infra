# backup/versitygw: an S3 endpoint from one directory

versitygw with the posix backend, a step-ca beside it for TLS, and a renewer, as one compose stack that names no
site. A site is a directory next to this one with three things: a `compose.yaml` that includes this stack, an `.env`,
and `certs/ca.crt` once the CA exists. `hov1/` is the first; a second site is a second directory. Everything here is
run from the site directory, so `../versitygw/bin/cert` and not `bin/cert`.

## What runs

| Service | Image | Role |
|---|---|---|
| `versitygw` | `versity/versitygw` | The gateway: `${DATA_DIR}` is the root, every top-level directory a bucket, S3 metadata in xattrs (ext4, xfs); accounts in the internal IAM directory on the `iam` volume; the admin API on a listener that is never published; `/health` for the healthcheck |
| `step-ca` | `smallstep/step-ca` | The site's CA, self-initialised on first start, reachable only inside the compose network; its root is what every client pins |
| `step-renew` | `smallstep/step-cli` | Renews the gateway's certificate at two thirds of its lifetime over mTLS and sends versitygw SIGHUP, which reloads it; it shares versitygw's pid namespace for that and holds no Docker socket |

Why an own CA: clients reach the gateway by address, and no public CA issues a durable certificate for a bare address
(Let's Encrypt's are six-day and HTTP-01 only). A site with a name works the same way, `S3_ADDR` then being that name,
and the CA is still the simpler choice when the clients are all yours. Needs Docker Compose 2.24 or newer on the site
host, and GNU `base64` for `bin/site-secret`.

Where the state is: `DATA_DIR` holds the buckets, `iam` (a named volume under Docker's data root) the accounts, `step`
(likewise) the CA. `.env` holds the root key pair and the CA password and is kept off the host too, in the operator's
password manager. If the host is lost, the runbook is: a new host, the same `.env`, `bin/cert` (a new CA, so a new
root: `bin/site-secret` and a commit), then `bin/user` for every writer (new keys: sops and a commit each). The
cluster is unaffected throughout, and the next base backup refills the buckets. What versioning would have added
is deliberately not there: versitygw 1.8 has no lifecycle rules, so versioning keeps every deleted object forever,
and an account that owns a bucket can suspend it anyway; retention is the writers' job (Barman's `retentionPolicy`,
restic's `forget`), and protection against a bad writer is a second copy, or object lock the day it is wanted.

## Scripts, all run from the site directory

| Script | Does |
|---|---|
| `bin/cert` | First run: CA up, `admin` provisioner widened from 24-hour certificates to 30 days, root exported to `certs/ca.crt`. Every run: a one-time token from the CA, the gateway's certificate for `S3_ADDR` written by the renewer's image, the stack up, SIGHUP to versitygw |
| `bin/user <bucket> <namespace> [--rotate]` | Mints the bucket's account (role `user`) and the bucket, owned by it and by nothing else, and prints the Secret the writer reads, on stdout, for `sops` to encrypt. `--rotate` replaces an existing account's key pair; the writer fails until the new Secret is applied |
| `bin/site-secret <namespace>` | Prints the site's public facts as a plain Secret `<site>-s3`: the root, the endpoint, the region. Committed as it is |

## Accounts and how the cluster gets them

The root key pair in `.env` mints accounts and buckets, and nothing that runs unattended ever holds it. Each writer
has its own account with the `user` role, which in versitygw's built-in IAM sees only buckets it owns, so a leaked
writer key reaches one bucket. Every client signs with `REGION`, the gateway rejects any other, so the region travels
with the endpoint in the site Secret.

The key pair leaves the site once, encrypted; in clear it exists in the gateway's IAM store and, for the seconds
the pipeline runs, in the shell. From the repository root:

```sh
(cd backup/hov1 && ../versitygw/bin/site-secret forgejo) > apps/forgejo/hov1-s3.yaml
(cd backup/hov1 && ../versitygw/bin/user cnpg-forgejo forgejo) \
  | sops --encrypt --filename-override apps/forgejo/s3-cnpg-forgejo.enc.yaml /dev/stdin \
  > apps/forgejo/s3-cnpg-forgejo.enc.yaml
```

`--filename-override`, resolved from the repository root, makes sops pick the cluster-files rule from `.sops.yaml`
(`data`/`stringData` encrypted, to the cluster key and the operators' YubiKeys), so Flux decrypts it like every
other `*.enc.yaml`. Both files go into `apps/<namespace>/kustomization.yaml`, which lists its resources by name. In
the cluster the `ObjectStore` reads `s3Credentials` from `s3-<bucket>` and `endpointCA` from `<site>-s3`, and
restic's environment reads both; nothing is copied into the swamp vault until a workflow needs it (decision 005).
Rotation is `bin/user ... --rotate` piped into the same file, then a commit at once. An address change is a new
`bin/cert`, a new `bin/site-secret` per namespace, and no sops edit.
