# The versitygw stack

An S3 endpoint from one directory: versitygw with the posix backend, behind a certificate from the site's own private
CA. The CA is four files made once by a script; the only thing that runs is the gateway. The stack names no site: a
site is a sibling directory with a five-line `compose.yaml` that includes this one, an `.env`, and `certs/`. `../hov1/`
is the first site. Everything here is run **from the site directory**: `../versitygw/bin/cert`, never `bin/cert`.

## Contents

- [Components](#components)
- [Design decisions](#design-decisions)
- [Prerequisites](#prerequisites), including rootless Podman
- [Runbooks](#runbooks): new site, add a writer, rotate a writer key, reissue the certificate, change the address, site host lost
- [Scripts](#scripts)
- [Where state lives](#where-state-lives)
- [Security model](#security-model)
- [Failure modes](#failure-modes)
- [Configuration reference](#configuration-reference)

## Components

| What | Image | Listens | Role |
|---|---|---|---|
| `versitygw` | `versity/versitygw:v1.8.0` | `${LISTEN}:${PORT}` (default `0.0.0.0:443`) to 7070 inside, TLS; admin API on 7071, never published | The gateway. `${DATA_DIR}` is the root: every top-level directory a bucket, every file an object, S3 metadata in xattrs. Accounts in the internal IAM directory on the `iam` volume. `/health` for the healthcheck. Runs under an init, since it does not reap children |
| `certs/` | `smallstep/step-cli:0.30.6`, once, in a throwaway container | Nothing | `ca.crt` and `ca.key`, a private root valid three years; `tls.crt` and `tls.key`, the gateway's certificate for `S3_ADDR`, valid three years. versitygw reloads them on SIGHUP |

## Design decisions

| Decision | Why |
|---|---|
| Clients reach the gateway by address (`S3_ADDR`); a name is optional | No DNS, zone or DNS provider in the backup path. A name works the same way: set `S3_ADDR` to it |
| Own private CA, made offline with `step`, no CA server | No public CA issues a durable certificate for a bare address (Let's Encrypt's are six-day and HTTP-01 only). One gateway needs one certificate; a running CA and a renewer were more moving parts than the problem |
| Root and certificate valid three years | Long enough that renewal is an event, not a process; short enough to be a calendar entry. Reissue is one script, watched by an expiry alert from the cluster |
| One account per writer, role `user`, owner of one bucket | A leaked writer key reaches one bucket. versitygw's `user` role sees only buckets it owns |
| Bucket versioning off | versitygw 1.8 has no lifecycle rules, so versioning keeps every deleted object forever; a bucket's owner can suspend it anyway. Retention is the writers' job; protection against a bad key is a second copy, or object lock later |
| Root key pair only in `.env` and the operator's shell | Nothing unattended ever holds it |
| Writer secrets leave the site only sops-encrypted | Flux decrypts them with the cluster key; no plaintext file in the repository or on an operator disk |

## Prerequisites

- A host with Docker, or rootless Podman 4.9 or newer, and **Docker Compose 2.24 or newer** (`include`). Nothing in
  the stack needs root: container root maps to the host user, who owns `DATA_DIR` and `certs/`.
- `DATA_DIR` and `VERSIONS_DIR` on a filesystem with xattrs (ext4, xfs); `VERSIONS_DIR` outside `DATA_DIR`.
- Port `PORT` reachable from the cluster at `S3_ADDR` (forwarded, if the host is behind NAT).
- On the operator's machine: `sops` with the repository's `.sops.yaml` recipients (a YubiKey), GNU `base64`.

### Rootless Podman, once per host

hov1 runs this way. The distro `docker-compose` is usually v1 and cannot read this stack; install the Compose v2
binary as the user and tell Podman to use it.

```sh
loginctl enable-linger $USER                                  # containers outlive the login
systemctl --user enable --now podman.socket podman-restart.service
install -m 0755 docker-compose-linux-x86_64 ~/.local/bin/docker-compose   # the release binary, checksum checked
```

In `~/.config/containers/containers.conf`, inside the one `[engine]` table (a second `[engine]` table is invalid
TOML and stops every podman command):

```toml
compose_providers = ["/home/<user>/.local/bin/docker-compose"]
compose_warning_logs = false
```

After that `docker compose` and `podman compose` run the v2 binary against the user's socket, which is what the
scripts call. To publish 443 rootless, either forward 443 to `PORT=8443` at the router, or
`sysctl net.ipv4.ip_unprivileged_port_start=443` in `/etc/sysctl.d/`, which opens 443 and up to every user.

## Runbooks

### New site

1. Create `../<site>/` with `compose.yaml` copied from `../hov1/compose.yaml` and `name:` changed, and `.env` from
   `../hov1/.env.example`, filled in. Values: letters, digits, punctuation other than `# $ ' "` and spaces, unquoted.
2. On the host, `mkdir -p "$DATA_DIR" "$VERSIONS_DIR"`; forward `PORT`.
3. From the site directory: `../versitygw/bin/cert`. Makes the CA and the certificate, starts the gateway, prints
   both certificates.
4. Verify: `docker compose ps` shows the gateway healthy; from elsewhere,
   `curl --cacert certs/ca.crt https://$S3_ADDR/health` returns 200.
5. Put `.env` and `certs/ca.key` in the operator's password manager; commit `certs/ca.crt` and the site directory.
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

Before the three years are up (the cluster alerts 30 days ahead), or after a change of `S3_ADDR`: from the site
directory, `../versitygw/bin/cert`. Same root, new certificate, SIGHUP to the gateway; no client changes. For a new
root (compromise, or the root itself expiring): `rm certs/ca.crt certs/ca.key`, `bin/cert`, then
`bin/site-secret` per writing namespace, commit, and the writers pick up the new root when Flux applies it.

### Change the address

1. Set `S3_ADDR` in `.env`; move the port forward.
2. [Reissue the certificate](#reissue-the-certificate).
3. For each writing namespace: `bin/site-secret` again into `apps/<namespace>/<site>-s3.yaml`, commit. A plaintext
   diff; no sops edit, since writer Secrets carry no endpoint.
4. Verify the writers: the next WAL archive and the next restic run succeed.

### Site host lost

The cluster is unaffected throughout; only the target is gone.

1. New host, same `.env` and `certs/ca.key` from the password manager, `certs/ca.crt` from git, the two directories.
2. [New site](#new-site) from step 3. Same root, so no site Secret changes.
3. [Add a writer](#add-a-writer) for every writer: new accounts, new keys, sops, commit.
4. The next base backup refills the buckets; until then there is no restorable copy. If `DATA_DIR` survived, the
   buckets are still there and `bin/user` only re-establishes ownership.

Without `ca.key`: `bin/cert` makes a new root; add `bin/site-secret` per namespace and a commit to step 2.

## Operating a site through swamp

Not yet. The registry's `@smith/docker-compose` (up, down, ps, logs, restart, pull) writes a data item named `latest`,
which current swamp reserves, so every method fails; it declares no repository to report the bug to and no license
to fork it under. Until a `@dataverket` compose model exists, the lifecycle is `docker compose` from the site
directory. Note for that model: it must run from the site directory and pass it as an absolute
`--project-directory`, since the site's `compose.yaml` resolves `.env` and `./certs` against it.

## Scripts

All run from the site directory; each refuses to run without `.env` there.

| Script | Arguments | Does | Prints |
|---|---|---|---|
| `bin/cert` | none | CA root if absent (three years, `CERT_YEARS`); certificate for `S3_ADDR` (three years); `docker compose up -d`; SIGHUP to versitygw | Both certificates' subjects and expiries |
| `bin/user` | `<bucket> <namespace> [--rotate]` | Creates account `<bucket>` (role `user`) and the bucket owned by it, or hands over an existing bucket; `--rotate` deletes the account first | The writer Secret `s3-<bucket>` on stdout: `BUCKET`, `ACCESS_KEY_ID`, `SECRET_ACCESS_KEY`. Progress on stderr |
| `bin/site-secret` | `<namespace>` | Reads `certs/ca.crt` and `.env` | The site Secret `<site>-s3` on stdout: `ENDPOINT`, `REGION`, `ca.crt`. Nothing secret; committed as it is |

## Where state lives

| State | Location | Durability | Rebuilt by |
|---|---|---|---|
| Buckets and objects | `${DATA_DIR}` on the host | The host's disk | The writers' next base backup |
| Accounts and their keys | Docker volume `<site>_iam`, plaintext `users.json` | Docker's data root on the host | `bin/user` per writer, new keys |
| CA root | `certs/ca.crt`, committed | The repository | Never; a new root is a new file and new site Secrets |
| CA key | `certs/ca.key`, ignored by git, and the password manager | The password manager | Cannot be; without it a new root |
| Gateway certificate and key | `certs/tls.crt`, `certs/tls.key`, ignored by git | The host | `bin/cert` |
| Root key pair | `.env`, ignored by git, and the password manager | The password manager | Cannot be; choose new ones, recreate the gateway, re-mint every writer |

## Security model

| Credential | Held by | Reaches | In clear where |
|---|---|---|---|
| Root key pair | `.env`, the operator running `bin/user` | Mints accounts and buckets over the admin API; nothing unattended | `.env`; the shell's argv while `bin/user` runs |
| Writer key pair (`user` role) | The writer's Secret in the cluster | Its own bucket, nothing else | The gateway's IAM store; the shell for the seconds the pipeline runs; the cluster's etcd |
| CA key | `certs/ca.key` (0600), the password manager | Signs the gateway's certificate, which every writer trusts for `S3_ADDR` | On the host, unencrypted; whoever holds it can impersonate the endpoint to the writers, and nothing else |
| CA root | `certs/ca.crt`, the `<site>-s3` Secrets | Trust anchor for every client | Everywhere; public |

Every client signs with `REGION`; the gateway rejects any other region on the data path and on the admin API.

## Failure modes

| Symptom | Likely cause | Action |
|---|---|---|
| Cluster alert: WAL archiving failing, restic snapshots stale | Site unreachable: host down, uplink down, port forward lost, address changed | On the host `docker compose ps`; from outside `curl --cacert certs/ca.crt https://$S3_ADDR/health`. Headroom is about a day of WAL |
| Cluster alert: certificate expires within 30 days | Three years are up, or the root is | [Reissue the certificate](#reissue-the-certificate) |
| Writers get `403` / `MalformedAuth.IncorrectRegion` | Client region differs from `REGION` | Set the writer's region from the `<site>-s3` Secret |
| Writer gets `NoSuchBucket` after a host rebuild | `DATA_DIR` lost; buckets are directories in it | [Site host lost](#site-host-lost) step 3 recreates them |
| `bin/user` fails with an auth error | Wrong root key in `.env`, or `REGION` changed since the gateway started | Check `.env`; `docker compose up -d` recreates the gateway with the new region |
| `bin/user` says the account exists | A previous run, or a rotation intended | `--rotate`, then commit the new Secret at once |
| `sops: no matching creation rules` | Pipeline not run from the repository root | Run from the root; the override path must start with `apps/` |
| Disk under `DATA_DIR` filling | A writer's retention not deleting, or versioning turned on by mistake | Check `retentionPolicy` and `forget`; `aws s3api get-bucket-versioning` must show nothing enabled |
| Gateway not running after the host rebooted | Rootless: linger or `podman-restart.service` off | The Podman section above |

## Configuration reference

`.env` in the site directory. Read by compose and by the scripts.

| Variable | Required | Meaning |
|---|---|---|
| `SITE` | yes | Names the container, the CA and the `<site>-s3` Secret; equal to the directory name |
| `ROOT_ACCESS_KEY`, `ROOT_SECRET_KEY` | yes | The root account; long and random |
| `DATA_DIR` | yes | Gateway root on the host; buckets are its top-level directories; xattr filesystem |
| `VERSIONS_DIR` | yes | Where previous object versions would go; outside `DATA_DIR`; unused while versioning is off |
| `S3_ADDR` | yes | `host:port` clients use; the certificate's SAN is the host part, IP or name |
| `REGION` | yes | What every client signs with; `us-east-1` unless there is a reason |
| `PORT` | no, 443 | Published port |
| `LISTEN` | no, `0.0.0.0` | Published address on the host |
| `CERT_YEARS` | no, 3 | Lifetime of the CA root and of the certificate `bin/cert` makes |
