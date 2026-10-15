# Plan: Zitadel as the identity provider of the osl1 S3 gateway

Written 2026-10-04 as step 2 of the osl1 S3 plan, split out 2026-10-15 when the gateway was done (decision 029).
Research only; nothing is applied. In the way the rest of the platform does it (decision 015), a person would reach
S3 with credentials that expire, from a browser login.

## What was found

Not applied, and not applied before the gateway has run for a while. This records what was found so the plan can be
written against it. The account model next to RadosGW's, why bucket listing is Objekt's and not a policy's, and
which parts of policy and STS one code path can serve on both gateways are in the `org` repository,
`docs/notater/2026-10-s3-gateways-one-code-path.md`. What that note leaves to this site:

- A swamp store on this gateway, `@swamp/s3-datastore` against a bucket without versioning or lock, needs its bucket
  name unique on the gateway, and its one account key rotates by cutover until standalone IAM gives two keys. The
  per-person 12-hour access the store wants is an STS session, which is this plan; until then the store's key is a
  tier 3 item under `sops exec-env`, proven on a scratch repository first, since setup's probe of conditional writes
  is the real test of this gateway.
- Presigned GET and PUT through Envoy, and one signed with an STS session token once standalone IAM runs.
- Whether `ListBuckets` under standalone IAM is filtered by policy after all, tested with a user holding
  `ListBucket` on one bucket.

### The mechanism versitygw offers

versitygw 1.8.0 has two unrelated identity models. The built-in backends (internal, LDAP, Vault, FreeIPA, S3) are
account directories with a role tier per account and no policy language. The **standalone IAM service**
(`versitygw iam`) is a separate process speaking the AWS IAM and STS Query API: IAM users with up to two access keys,
IAM roles with trust policies, inline identity policies, OpenID Connect providers, and `AssumeRoleWithWebIdentity`.
The gateway connects to it over a private endpoint (unix socket or mutual TLS; the chart can issue the
certificates through cert-manager), asks it to derive signing keys and evaluate policies, and holds no secret itself.
The two are mutually exclusive on one gateway and share no data: moving to standalone IAM recreates every account.

The federation flow:

1. An OIDC provider is registered once with its issuer URL and the client ids it accepts, here
   `https://zitadel.dataverket.org` and the client id of a Zitadel application made for S3. The service fetches
   the discovery document and JWKS from the issuer at assume time and caches keys five minutes.
2. A role carries a trust policy: `Principal.Federated` is the provider, the action is
   `sts:AssumeRoleWithWebIdentity`, and conditions scope `zitadel.dataverket.org:aud`, `zitadel.dataverket.org:sub`
   and any other top-level scalar or scalar-array claim of the token. Nested object claims are dropped, so Zitadel's
   default `urn:zitadel:iam:org:project:roles` claim, an object, is not usable as a condition. A Zitadel action that
   adds a flat `groups` array claim to the token makes `ForAnyValue:StringEquals` on it work.
3. A caller presents a Zitadel ID token and gets credentials that live 900 to 43200 seconds, capped by the role's
   `MaxSessionDuration`. The gateway resolves the session token through the private endpoint on every request;
   deleting a key or a role takes effect on the next request.
4. The role's inline policy says which buckets and actions, in AWS policy grammar: `s3:ListBucket`, `s3:GetObject`
   and so on against `arn:aws:s3:::<bucket>` and `arn:aws:s3:::<bucket>/*`.

### How that fits decision 001 and 015

- A person authenticates in the browser as themselves, through the device flow `task admin:zitadel-key` already
  drives, exchanges the ID token for S3 credentials that expire, and the AWS CLI reads them through a
  `credential_process` entry in `~/.aws/config` that names a profile and no credential. Tier 2 as 001 defines it, and
  the same pattern decision 015 gives Kubernetes.
- Automation is a Zitadel service user whose token is a JWT the project issues (the application set to JWT access
  tokens), assuming a role of its own, named per purpose, so both Zitadel's log and the gateway's access log say
  which one acted. An in-cluster writer such as Zulip has no OIDC client in it, so it keeps a long-term IAM user
  with one access key and an inline policy on its bucket, the tier 3 item it is today, rotated by `aws iam
  create-access-key` and `delete-access-key` without downtime, which the internal backend cannot do.
- Authorization moves into policy documents in git, applied by swamp, as 015 moves RBAC into ClusterRoleBindings.
  The one-account-one-bucket rule becomes an inline policy per user or role, which `check` evaluates from the IAM
  API instead of from the admin API's ownership listing.

### What changes, and what it costs

| Today, internal IAM | Under standalone IAM |
|---|---|
| Every bucket owned by its writer's account | Every bucket owned by root; a user's access is its identity policy. `ListBuckets` shows every bucket to anyone granted `s3:ListAllMyBuckets` |
| Accounts over the admin API; `accounts` and `check` in the extension read it | `create-user`, `list-users`, `change-bucket-owner` answer 501; the extension needs IAM-API methods, and `check`'s ownership rule is replaced by a policy rule |
| One process | Two processes, two root credentials or one shared, mutual TLS between them, and a second plaintext store, `iam.json`, holding every user's secret key and the live STS sessions |
| The gateway keeps serving if nothing else runs | The gateway fails closed when the IAM service is unreachable: `InternalError` on every request |
| `userplus` can create buckets | Only `s3:CreateBucket` in a policy does |

The file store coordinates writers inside one process, so the IAM service is one replica forever unless it is given
Vault as its store, which Dataverket does not run.

### What the plan must settle

1. **Whether the gain is worth two processes.** Humans reaching S3 with expiring credentials from a browser login
   is the gain. If the only human use is the operator's `inventory` and `check`, which root signs today, there is no
   human to federate yet, and the plan waits for one. Zulip's users never touch S3 directly.
2. **The claim.** A Zitadel action that writes a flat `groups` claim, or roles asserted per application in the
   token in a flat shape, verified against a throwaway Zitadel with the `@dataverket/zitadel` smoke setup, before
   any trust policy is written against it.
3. **Session lifetime**, the same question 015 leaves open for the refresh token: the ID token lives minutes, the
   STS credentials a role's `MaxSessionDuration`; the number is a decision.
4. **Where `iam.json` lives and how it is backed up**: a second volume or a `subPath` of the same one, 0600, in the
   same kopia snapshot; it is a key store.
5. **The migration**: every writer re-minted as an IAM user with a policy, in one window, with the hov1 pipeline
   writing the new Secrets, and the admin-API methods of the extension retired or kept for hov1 only, since hov1
   stays on internal IAM.
