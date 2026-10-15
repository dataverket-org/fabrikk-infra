# The versitygw artifact

The S3 service at the osl1 site, `dataverket.s3.osl1.dvkt.no`: one versitygw with the posix backend on one Cinder
volume, delivered the way zot is. Git holds the pointer, `apps/versitygw/source.yaml`; this directory is the artifact,
pushed as it is by `push.sh` into zot as `platform/versitygw-config`, and Flux applies whatever the `current` tag
holds, decrypting the Secret with the cluster key. Why it is shaped so is decision 029; its backup, deferred, is
`docs/plans/2026-10-s3-osl1-backup.md`; what it holds is read by the model `osl1-s3`, below.

## Contents

| File | What |
|---|---|
| `namespace.yaml` | Namespace `versitygw` |
| `statefulset.yaml` | The gateway, image pinned by digest, one 20 GB `csi-cinder-standard-retain` claim with `/data`, `/versioning` and `/iam` as subPaths |
| `service.yaml` | `versitygw:7070`, the S3 API for in-cluster writers and the route; `versitygw-admin:7071`, the admin API, never routed |
| `httproute.yaml` | `dataverket.s3.osl1.dvkt.no` on the Gateway's `https-s3-osl1` listener, request timeout off; the `http` redirect |
| `versitygw-root.enc.yaml` | The root key pair, source of record, sops-encrypted to the cluster key and the two operators |
| `push.sh` | Pushes this directory into zot; not part of the artifact |
| `user.sh` | Mints an account and its buckets through `kubectl exec`, prints the writer's Secret; not part of the artifact |

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
- **Accounts and buckets**: one account per writer, role `user`, owner of its buckets, as on the hov1 site
  (`backup/versitygw/README.md`, "Security model"). `user.sh` makes them with versitygw's own admin CLI inside the
  pod, where the root key pair already is, and prints the Secret for `sops --encrypt`:

  ```sh
  artifacts/versitygw/user.sh <account> <namespace> <bucket>... \
    | sops --encrypt --filename-override artifacts/<name>/s3-<account>.enc.yaml /dev/stdin \
    > artifacts/<name>/s3-<account>.enc.yaml
  ```

  The gateway's IAM store holds the secret in clear; nothing else does. A bucket that wants object lock, which `user.sh`
  does not set, is created with lock, which turns versioning on for it; versitygw has no lifecycle rules, so non-current
  versions stay until a client deletes them by version id.
- **The root key pair** lives here and, by a person's copy, in `vaults/operator/osl1/root.enc.json`. Rotate here first:
  new values in the Secret, push, then the copy.

## Read it

The model `osl1-s3` (`@dataverket/versitygw/gateway`) reads the admin API through a port-forward, signed with the root
key pair from `vaults/operator/osl1/root.enc.json`, one YubiKey touch:

```sh
kubectl --context dataverket-prod-admin -n versitygw port-forward svc/versitygw-admin 7071:7071   # its own terminal
sops exec-env vaults/operator/osl1/root.enc.json 'swamp behavior run osl1-s3 inventory && swamp behavior run osl1-s3 check'
```

`inventory` records accounts without their secret, buckets and every bucket's settings. `check` with the default rules
expects three findings and no more: `bucket-owner-not-same-named` for `zulip-uploads` and `zulip-avatars`, both owned
by the account `zulip`, and `bucket-public` for `zulip-avatars`, whose policy lets anyone `s3:GetObject`.

## What the gateway does

Read from the wiki and the source at v1.8.0 on 2026-10-04 and at v1.9.0 on 2026-10-15, and proven where it says so.

| Fact | Consequence |
|---|---|
| Object lock works on the posix backend; lock state, retention and legal hold are xattrs on the bucket directory and the object | A backup must carry xattrs, or a restore re-puts the lock configuration |
| A bucket created with `ObjectLockEnabledForBucket` gets versioning at once, given `--versioning-dir`; v1.9.0 stores a bucket's default retention on each new object (discussion #2521) | The gateway runs with `/versioning`; no bucket uses lock yet (decision 029) |
| `COMPLIANCE` retention cannot be shortened by anyone, root included; `GOVERNANCE` can be bypassed with the header by root or a user granted `s3:BypassGovernanceRetention` | Governance is the default a writer gets; compliance is a commitment on a volume no one can trim |
| Lifecycle configuration answers `NotImplemented` | A versioned bucket keeps every non-current version until a client deletes it by version id |
| Internal IAM keeps accounts, secrets in clear, in `/iam/users.json`; accounts are made over the admin API, signed by root | `user.sh` makes them in the pod; the admin port is never routed |
| Startup tests xattr support on `/data` and refuses to start without it | It starts on the Cinder volume's ext4, which is the proof |
| `aws:SourceIp` in a policy is the connection's peer, never `X-Forwarded-For` | Behind Envoy every client is Envoy; no IP conditions in policies |
| v1.8.0 stored `Content-Encoding: aws-chunked` on objects written with a trailing checksum (#2398), and with a bucket policy it let the owner do only what the policy granted (#2495) | Fixed in v1.9.0, which osl1 runs; hov1 stays on v1.8.0 for now |
| Presigned get with `ResponseContentDisposition`, ranges, copy onto itself with new headers, multipart, batch delete, list pages with `KeyCount`, and one 2 GiB PUT through Envoy | Proven 2026-10-15 with `artifacts/zulip/s3proof` on tusd's AWS SDK, 13 of 13 |
| A standalone IAM service (`versitygw iam`) speaks IAM and STS, with OIDC providers and `AssumeRoleWithWebIdentity` | The mechanism of `docs/plans/2026-10-s3-zitadel.md` |

## After a rebuild

zot comes back empty (`docs/storage.md`, "Rebuild from git"), so Flux cannot fetch this artifact until `push.sh` has
run again from the checkout. The gateway's volume is retained, so the data comes back with the claim; the root key
pair and the accounts are on it.
