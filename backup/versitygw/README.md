# The versitygw stack

An S3 endpoint from one directory: versitygw with the posix backend, a step-ca beside it for TLS, and a renewer, as
one compose stack that names no site. A site is a sibling directory with a five-line `compose.yaml` that includes this
stack, an `.env`, and `certs/ca.crt` once the CA exists. `../hov1/` is the first site. Everything here is run **from
the site directory**: `../versitygw/bin/cert`, never `bin/cert`.

## Contents

- [Components](#components)
- [Design decisions](#design-decisions)
- [Prerequisites](#prerequisites)
- [Runbooks](#runbooks): new site, add a writer, rotate a writer key, reissue the certificate, change the address, site host lost
- [Scripts](#scripts)
- [Where state lives](#where-state-lives)
- [Security model](#security-model)
- [Failure modes](#failure-modes)
- [Configuration reference](#configuration-reference)

## Components

| Service | Image | Listens | Role |
|---|---|---|---|
| `versitygw` | `versity/versitygw:v1.8.0` | `${LISTEN}:${PORT}` (default `0.0.0.0:443`) to 7070 inside, TLS; admin API on 7071, never published | The gateway. `${DATA_DIR}` is the root: every top-level directory a bucket, every file an object, S3 metadata in xattrs. Accounts in the internal IAM directory on the `iam` volume. `/health` for the healthcheck |
| `step-ca` | `smallstep/step-ca:0.30.2` | 9000, compose network only | The site's CA. Initialises itself on first start: root, intermediate, one JWK provisioner `admin`. Never touches `certs/` |
| `step-renew` | `smallstep/step-cli:0.30.6` | Nothing | Renews the gateway's certificate at two thirds of its lifetime over mTLS, then sends versitygw SIGHUP, which reloads certificate and key. Shares versitygw's pid namespace for that signal and holds no Docker socket |

Certificate lifetime is 30 days (provisioner maximum 90); renewal runs at about day 20.

## Design decisions

| Decision | Why |
|---|---|
| Clients reach the gateway by address (`S3_ADDR`), a name is optional | No DNS, zone or DNS provider in the backup path. A name works the same way; set `S3_ADDR` to it |
| Own CA (step-ca), root pinned by every client | No public CA issues a durable certificate for a bare address; Let's Encrypt's are six-day and HTTP-01 only. The clients are all ours |
| One account per writer, role `user`, owner of one bucket | A leaked writer key reaches one bucket. versitygw's `user` role sees only buckets it owns |
| Bucket versioning off | versitygw 1.8 has no lifecycle rules, so versioning keeps every deleted object forever; a bucket's owner can suspend it anyway. Retention is the writers' job; protection against a bad key is a second copy, or object lock later |
| Root key pair only in `.env` and the operator's shell | Nothing unattended ever holds it |
| Reload by SIGHUP, no Docker socket | versitygw 1.8 reloads TLS on SIGHUP; a socket in a long-running container is host root |
| Writer secrets leave the site only sops-encrypted | Flux decrypts them with the cluster key; no plaintext file in the repository or on an operator disk |

## Prerequisites

- A host with Docker and **Docker Compose 2.24 or newer** (`include`, inline `configs`).
- `DATA_DIR` and `VERSIONS_DIR` on a filesystem with xattrs (ext4, xfs); `VERSIONS_DIR` outside `DATA_DIR`.
- Port `PORT` reachable from the cluster at `S3_ADDR` (forwarded, if the host is behind NAT).
- On the operator's machine: `sops` with the repository's `.sops.yaml` recipients (a YubiKey), GNU `base64`.

## Runbooks

### New site

1. Create `../<site>/` with `compose.yaml` copied from `../hov1/compose.yaml` and `name:` changed, and `.env` from
   `../hov1/.env.example`, filled in. Values: letters, digits, punctuation other than `# $ ' "` and spaces, unquoted.
   Keep `.env` in the operator's password manager too; it is never committed.
2. On the host, `mkdir -p "$DATA_DIR" "$VERSIONS_DIR"`; forward `PORT`.
3. From the site directory: `../versitygw/bin/cert`. Brings the CA up, widens its provisioner to 30-day certificates,
   writes `certs/ca.crt`, issues the gateway's certificate, starts everything, prints the certificate.
4. Verify: `docker compose ps` shows all three healthy or running; from elsewhere,
   `curl --cacert certs/ca.crt https://$S3_ADDR/health` returns 200.
5. Commit `certs/ca.crt` and the site directory.
6. For each namespace that will write: [Add a writer](#add-a-writer).

### Add a writer

Run from the **repository root**. The site Secret carries the root, endpoint and region; the writer Secret carries the
key pair and goes through sops without touching a disk in clear.

```sh
site=hov1; ns=forgejo; bucket=cnpg-forgejo
(cd backup/$site && ../versitygw/bin/site-secret $ns) > apps/$ns/$site-s3.yaml
(cd backup/$site && ../versitygw/bin/user $bucket $ns) \
  | sops --encrypt --filename-override apps/$ns/s3-$bucket.enc.yaml /dev/stdin \
  > apps/$ns/s3-$bucket.enc.yaml
```

Then add both files to `apps/<namespace>/kustomization.yaml` (it lists resources by name), commit, and point the writer
at them: the CNPG `ObjectStore` reads `s3Credentials` from `s3-<bucket>` and `endpointCA` from `<site>-s3`; restic's
environment reads both. `--filename-override`, resolved from the repository root, is what makes sops pick the
cluster-files rule; run from anywhere else and no rule matches.

`bin/user` creates the bucket owned by the new account, or hands over an existing one. The bucket must not belong to
another writer.

### Rotate a writer key

Same pipeline as [Add a writer](#add-a-writer) with `--rotate` after the namespace, into the same file, then commit at
once. The old key stops working the moment the new one is minted; WAL archiving and restic retry, so the gap is the
time until Flux applies the new Secret.

### Reissue the certificate

Needed when renewal has failed past expiry (mTLS renewal is refused after expiry) or after a change of `S3_ADDR`.
From the site directory: `../versitygw/bin/cert`. Uses the CA password step-ca keeps in its own secrets directory;
`STEP_CA_PASSWORD` in `.env` is that password. Ends with SIGHUP to versitygw, no restart.

### Change the address

1. Set `S3_ADDR` in `.env`; move the port forward.
2. [Reissue the certificate](#reissue-the-certificate).
3. For each writing namespace: `bin/site-secret` again into `apps/<namespace>/<site>-s3.yaml`, commit. A plaintext
   diff; no sops edit, since writer Secrets carry no endpoint.
4. Verify the writers: the next WAL archive and the next restic run succeed.

### Site host lost

The cluster is unaffected throughout; only the target is gone.

1. New host, same `.env` (from the password manager), the two directories.
2. [New site](#new-site) from step 3: a new CA, so a new root. `bin/site-secret` per namespace and commit.
3. [Add a writer](#add-a-writer) for every writer: new accounts, new keys, sops, commit.
4. The next base backup refills the buckets; until then there is no restorable copy. If `DATA_DIR` survived, the
   buckets are still there and only the account ownership is re-established by `bin/user`.

## Scripts

All run from the site directory; each refuses to run without `.env` there.

| Script | Arguments | Does | Prints |
|---|---|---|---|
| `bin/cert` | none | CA up; provisioner widened to 30-day certificates (first run); root to `certs/ca.crt`; one-time token; certificate for `S3_ADDR` written by the renewer's image as root; stack up; SIGHUP to versitygw | The certificate's subject and expiry |
| `bin/user` | `<bucket> <namespace> [--rotate]` | Creates account `<bucket>` (role `user`) and the bucket owned by it, or hands over an existing bucket; `--rotate` deletes the account first | The writer Secret `s3-<bucket>` on stdout: `BUCKET`, `ACCESS_KEY_ID`, `SECRET_ACCESS_KEY`. Progress on stderr |
| `bin/site-secret` | `<namespace>` | Reads `certs/ca.crt` and `.env` | The site Secret `<site>-s3` on stdout: `ENDPOINT`, `REGION`, `ca.crt`. Nothing secret; committed as it is |

## Where state lives

| State | Location | Durability | Rebuilt by |
|---|---|---|---|
| Buckets and objects | `${DATA_DIR}` on the host | The host's disk | The writers' next base backup |
| Accounts and their keys | Docker volume `<site>_iam`, plaintext `users.json` | Docker's data root on the host | `bin/user` per writer, new keys |
| The CA | Docker volume `<site>_step` | Docker's data root on the host | `bin/cert`, a new root, `bin/site-secret` per namespace |
| Gateway certificate and key | `certs/tls.crt`, `certs/tls.key` in the site directory, ignored by git | The host | `bin/cert` |
| CA root | `certs/ca.crt`, committed | The repository | Never; a new CA means a new file |
| Root key pair, CA password | `.env`, ignored by git, and the operator's password manager | The password manager | Cannot be; choose new ones and run [Site host lost](#site-host-lost) |

## Security model

| Credential | Held by | Reaches | In clear where |
|---|---|---|---|
| Root key pair | `.env`, the operator running `bin/user` | Mints accounts and buckets over the admin API; nothing unattended | `.env`; the shell's argv while `bin/user` runs |
| Writer key pair (`user` role) | The writer's Secret in the cluster | Its own bucket, nothing else | The gateway's IAM store; the shell for the seconds the pipeline runs; the cluster's etcd |
| CA password | `.env`, step-ca's secrets directory | Encrypts the CA keys, authorises the `admin` provisioner | `.env`; the step-ca container's environment |
| Site root certificate | `certs/ca.crt`, the `<site>-s3` Secrets | Trust anchor for every client | Everywhere; public |

Every client signs with `REGION`; the gateway rejects any other region on the data path and on the admin API.
`step-renew` runs as root inside its container to signal versitygw and write `certs/`; it has no socket and no
network exposure.

## Failure modes

| Symptom | Likely cause | Action |
|---|---|---|
| Cluster alert: WAL archiving failing, restic snapshots stale | Site unreachable: host down, uplink down, port forward lost, address changed | On the host `docker compose ps`; from outside `curl --cacert certs/ca.crt https://$S3_ADDR/health`. Headroom is about a day of WAL |
| Cluster alert: certificate expires within 7 days | `step-renew` failing: step-ca down, clock skew, renewer stopped | `docker compose logs step-renew step-ca`; `docker compose up -d`; if expired, [Reissue the certificate](#reissue-the-certificate) |
| Writers get `403` / `MalformedAuth.IncorrectRegion` | Client region differs from `REGION` | Set the writer's region from the `<site>-s3` Secret |
| Writer gets `NoSuchBucket` after a host rebuild | `DATA_DIR` lost; buckets are directories in it | [Site host lost](#site-host-lost) step 3 recreates them |
| `bin/user` fails with an auth error | Wrong root key in `.env`, or `REGION` changed since the gateway started | Check `.env`; `docker compose up -d` recreates versitygw with the new region |
| `bin/user` says the account exists | A previous run, or a rotation intended | `--rotate`, then commit the new Secret at once |
| `sops: no matching creation rules` | Pipeline not run from the repository root | Run from the root; the override path must start with `apps/` |
| Disk under `DATA_DIR` filling | A writer's retention not deleting, or versioning turned on by mistake | Check `retentionPolicy` and `forget`; `aws s3api get-bucket-versioning` must show nothing enabled |

## Configuration reference

`.env` in the site directory. Read by compose and by the scripts.

| Variable | Required | Meaning |
|---|---|---|
| `SITE` | yes | Names the containers, the CA and the `<site>-s3` Secret; equal to the directory name |
| `ROOT_ACCESS_KEY`, `ROOT_SECRET_KEY` | yes | The root account; long and random |
| `DATA_DIR` | yes | Gateway root on the host; buckets are its top-level directories; xattr filesystem |
| `VERSIONS_DIR` | yes | Where previous object versions would go; outside `DATA_DIR`; unused while versioning is off |
| `S3_ADDR` | yes | `host:port` clients use; the certificate's SAN is the host part, IP or name |
| `REGION` | yes | What every client signs with; `us-east-1` unless there is a reason |
| `STEP_CA_PASSWORD` | yes | Encrypts the CA keys; the `admin` provisioner's password; set once |
| `PORT` | no, 443 | Published port |
| `LISTEN` | no, `0.0.0.0` | Published address on the host |
