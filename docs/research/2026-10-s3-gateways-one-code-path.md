# Research: one code path over versitygw and RadosGW

Written 2026-10-06, from a conversation about using the osl1 gateway as a swamp store with 12-hour access per person.
It settles three things for Objekt and for step 2 of `docs/plans/2026-10-s3-osl1.md`: what a versitygw account is
next to a RadosGW user, which parts of policy and STS behave the same on both gateways, and what an adapter has to
hide. Read against versitygw 1.8.0's wiki and the standalone IAM pages; nothing here was run on a gateway yet.

## A versitygw account next to a RadosGW user

A versitygw internal account is closest to a RadosGW user without a tenant: one identity, one key pair, owner of
some buckets in a namespace the whole gateway shares, isolated by ownership. Extra key pairs, a private bucket
namespace and hard isolation are tenant and account features in RadosGW and have no equivalent in versitygw, which
separates at a coarser grain instead: one gateway per org on one volume.

| Trait | RadosGW | versitygw, internal IAM (osl1 and hov1 today) | versitygw, standalone IAM (step 2) |
|---|---|---|---|
| Unit of identity | A user, optionally inside a tenant; since Squid, users grouped in an account that owns the buckets | One account: access key, secret, role, plus posix uid, gid and project id | An IAM user, with roles assumed on top |
| Extra key pairs | Several S3 keys per user; subusers with their own keys | One key pair per account; rotation is a second account or a secret change | Two access keys per user, so rotation without downtime |
| Buckets owned | By the user, or by the account in the new model | By the account; `change-bucket-owner` transfers and wipes the bucket's ACL and policy | Every bucket owned by root; a user's reach is its identity policy |
| Bucket namespace | Global unless tenants are used; per tenant as `tenant:bucket` | One global namespace per gateway | One global namespace per gateway |
| Isolation by default | Full between tenants; within one, by ownership and policy | By ownership: a `user` reaches only buckets it owns | By policy: no policy, no reach; `s3:ListAllMyBuckets` shows everything |
| Who may create buckets | Any user within quota | `admin` and `userplus`; a `user` gets buckets made and assigned | Whoever a policy grants `s3:CreateBucket` |
| Sharing across identities | Bucket policies, ACLs, cross-tenant policies | Bucket policies on `user` and `userplus` buckets; canned ACLs `private`, `public-read`, `public-read-write` | Identity and inline policies in AWS grammar, plus bucket policies |
| Temporary credentials | `AssumeRole`, `AssumeRoleWithWebIdentity`, `GetSessionToken` | None | `AssumeRoleWithWebIdentity` and `GetCallerIdentity` only, 900 to 43200 seconds |
| Quota | Per user and per bucket | None; the volume is the quota | None |
| Where identities live | RGW metadata pools | `users.json` in the IAM directory, or LDAP, Vault, FreeIPA, another S3 bucket | `iam.json` in the IAM service, holding keys and live sessions |

Two consequences for a swamp store on the osl1 gateway: the bucket name must be unique on the gateway, and with one
key per account a key rotation is a cutover until standalone IAM gives two keys and expiring sessions.

## Listing buckets is not a policy question

`s3:ListAllMyBuckets` has the resource `arn:aws:s3:::*` and no condition on the bucket name, so a policy grants the
whole listing or none of it; versitygw does not filter the result by what the caller may reach. Nothing that knows its
bucket needs it: `s3:ListBucket` on the bucket lists the objects. Objekt answers "which buckets does this tenant
have" from its own catalogue over NATS, and only Objekt's worker holds the global listing, for reconciliation against
the catalogue. The bucket names on a gateway are then visible to operator roles alone, which is the remaining
difference from a RadosGW tenant: names, not contents.

## Presigned URLs are a client act

A presigned URL is SigV4 in the query string, made by whoever holds a credential; the gateway only verifies it, and
both gateways do. The signer is the application that owns the bucket, Zulip or Forgejo, never Objekt. A URL signed
with an STS session carries the session token and dies with the session; one signed with a long-lived key lives up
to the 7-day cap, chosen per URL. For an application with fast user switching, the application is the one policy
enforcement point: one credential for its bucket, authorization in the application, a presigned URL of seconds per
object. Per-user STS sessions have a 900-second floor on both gateways and belong only where the gateway's own log
must name the human.

## One code path

Objekt's downstream port gets two adapters. The common subset is strict; nothing in the core may use what one side
lacks.

| Concern | Why it is the same on both |
|---|---|
| Data plane | SigV4, path-style, presigned URLs, conditional writes, bucket policies in AWS grammar |
| Default per-writer policy | `ListBucket`, `GetObject`, `PutObject`, `DeleteObject` on one bucket ARN and its `/*`; nothing on `*` |
| Human session | `AssumeRoleWithWebIdentity` from a Zitadel ID token, 900 to 43200 seconds, a role with trust and inline policy |
| Service identity | An IAM user with up to two access keys and an inline policy, rotated by create and delete key |
| Listing per tenant | Objekt's catalogue; `ListAllMyBuckets` is never asked of either gateway |

## Behind the adapter

| Concern | RadosGW | versitygw |
|---|---|---|
| Tenant boundary | A tenant, or an account, inside one gateway; `tenant:bucket` | A gateway per org with its own volume and IAM store; the adapter is told the org's endpoint |
| Service-to-role switching | `AssumeRole` with session tags | Absent; the application authorizes and signs short presigned URLs, which works on both |
| Trust policy condition keys | `<issuer>:app_id` for the audience; nested claims flattened to inner keys | `<issuer>:aud`, `<issuer>:sub`, any top-level flat claim; nested claims dropped |
| Provider registration | OIDC provider with a certificate thumbprint list | Issuer URL and client id list; JWKS fetched live |
| Bucket owner at creation | The tenant or account that created it | Root; access through policy only |
| Quota and lifecycle | Native | None; the catalogue carries quota, `docs/plans/2026-10-versitygw-lifecycle.md` does expiry |
| Admin surface | `radosgw-admin` and admin ops REST | The IAM API of the standalone service; the admin API only on internal-IAM gateways |

Zitadel's flat claim is shared, but each gateway reads different condition keys from it, so a role's trust policy is
a template with two renderings. The contract suite sentral names runs against the fake first, then a versitygw in the
lab, then an RGW when Ceph exists; the trust-policy and provider rows are where the two first disagree and belong in
the suite from the start.

## Still to prove on a gateway

- A presigned GET and PUT from outside through Envoy, and one signed with an STS session token once standalone IAM
  runs; the PreSignedURL wiki page did not load, so the expiry cap versitygw enforces is unverified.
- Whether `ListBuckets` on standalone IAM is filtered by policy after all, as MinIO does; a user with `ListBucket`
  on one bucket calling it answers in a minute.
- That `@swamp/s3-datastore`'s setup probe of conditional writes passes on the osl1 gateway, on a bucket without
  versioning or lock.
