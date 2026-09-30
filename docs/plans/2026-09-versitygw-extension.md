# Plan: a swamp extension that reads versitygw

Written 2026-09-30. All five steps done the same day (see Progress). Read-only first: every question an operator asks of a gateway, answered as
data, before any method changes one.

## Why

The hov1 site's gateway holds one account and one bucket per writer (`backup/versitygw`), minted by `bin/user`.
Nothing records what the gateway holds or checks that it still matches the rule "every bucket is owned by the
account of the same name". A second gateway (storage plan, step 5) doubles the question. The registry has nothing
for it: the S3 extensions there are AWS-only, one provider each, or object-level; `@thomas/garage` is the nearest
shape, for another server.

## Decisions already made

- **The admin API, not the CLI.** `versitygw admin` is a one-to-one wrapper over signed `PATCH` calls. It prints
  tables only and takes a new secret only as an argument. The API needs SigV4 and XML, both from pinned libraries.
- **Reached on the site host's loopback.** `127.0.0.1:7071` since 2026-09-30 (`ADMIN_LISTEN`, `ADMIN_PORT`).
- **Pinned to the gateway's version.** v1.8.0. Newer releases add an admin path prefix (#2410) and RDMA routes
  (#2365); the endpoint argument is a base URL so a prefix is a value, not a code change.
- **Source is the forge mirror.** `git.dataverket.org/dataverket/versitygw`, a public pull mirror of
  `github.com/versity/versitygw`. Every claim about the API is read from the tag the gateway runs.

## Scope: read-only, complete

With the root key pair, the admin API and the S3 API together see everything the gateway holds.

| Method | Source | Records |
|---|---|---|
| `health` | `GET /health` on the S3 port | Reachable, TLS chain against the site CA, latency |
| `accounts` | admin `list-users` | One record per account: access key, role, user, group and project IDs. **Never the secret** |
| `buckets` | admin `list-buckets` | One record per bucket: name, owner |
| `bucketSettings` | S3 API as root, per bucket | Versioning, policy, ACL, object lock, ownership controls, CORS, tags |
| `inventory` | all of the above, one execution | The factory method a workflow calls; one lock, all records |
| `check` | the records of one run | Findings: bucket owner missing or not same-named, account owning nothing, `admin` role on a writer, versioning enabled, a bucket policy granting anyone |

`check` reads only the records its own run wrote (`workflowRunId`), never older data.

Out of scope for this phase: `create-user`, `update-user`, `delete-user`, `create-bucket`, `change-bucket-owner`.
They come after the read side has run against hov1 for a while and `bin/user` has something to be compared to.

## Quality bar

- **The secret is dropped at parse time.** `list-users` returns every account's secret key in clear. The parser
  maps to a type with no secret field; a test feeds a fixture with a known secret and asserts it appears in no
  record, log line or error text.
- **Fixtures from the real gateway.** Responses recorded once from a throwaway v1.8.0 in podman (secrets replaced),
  not written by hand. Unit tests run against them through an injected `fetch`.
- **Signing tested on its own.** A fixed-time SigV4 vector, and one live call that must return 200 where an
  unsigned call returns 403.
- **Errors are S3 errors.** The S3 XML error body is parsed into code and message; a wrong region surfaces as
  `IncorrectRegion`, not a generic failure.
- **Two live runs before publish.** The throwaway gateway with seeded accounts and buckets, then hov1 read-only.
  `inventory` twice in a row must produce identical records.
- **Publish gate as usual.** Review report, README of 500+ characters with two fenced examples, `@dataverket`.

## Decided: the root key pair

Every admin call, reads included, signs with the root key pair; versitygw has no read-only admin role. Today it
lives only in `backup/hov1/.env` and the password manager, and "nothing unattended holds it". The definition must
name where it comes from, never carry it:

1. A key file the operator's session writes and removes (`readSecretFile`, as in `@dataverket/talosctl`).
2. Environment passed through, so `pass-cli run -- swamp ...` supplies it from Proton Pass.
3. A swamp vault key, which makes it something unattended runs can hold.

Options 1 and 2 keep the README's rule; 3 changes it and is the owner's call. **Decided 2026-09-30: 1 and 2.**
The type takes `rootKeyFile` (a file of `NAME=value` lines) or `rootKeyEnv: true`, exactly one, with the variable
names as arguments (default `ROOT_ACCESS_KEY`, `ROOT_SECRET_KEY`). No vault key.

## Steps

1. Read the admin routes, types and middlewares at tag v1.8.0 in the forge mirror; write the fixture list.
2. Throwaway gateway in podman, seeded; record fixtures.
3. `@dataverket/versitygw` in `~/kode/swamp-extensions/versitygw/`: transport (sign, fetch, parse), then the
   methods in the table, tests alongside.
4. Live run on the throwaway, then on hov1 with the key source chosen above; `check` must come back clean.
5. Publish, pull, pin; a model per gateway in `models/@dataverket/versitygw/`.

## Progress

In `~/kode/swamp-extensions/versitygw/` on `main`, pushed (`86ae2d1`, and `485a450` with the check fix below). Published as 2026.09.30.1 and pinned here.

- Step 1. Six admin routes at v1.8.0, all `PATCH`, SigV4 service `s3`, `x-amz-content-sha256` required, admin role
  only. `list-users` also returns `SessionToken`, `IsSession`, `Arn` and `RoleArn`, which the CLI table hides.
- Step 2. `smoke/gateway.sh` starts two throwaway gateways (plain, and TLS behind a CA made there) and seeds them;
  `smoke/record.sh` records 51 fixtures from the plain one.
- Step 3. `@dataverket/versitygw/gateway` with the six methods in the table. 76 unit tests, 45 of them the negative
  suite (`negative_test.ts`). Its first run failed 11 cases, six bugs: a 200 with an empty, truncated or foreign
  body recorded as zero accounts; a missing name recorded as empty; a bad id recorded as 0; an unknown versioning
  status recorded as `Off`; a non-S3 error body quoted into the message, account secrets included; a missing
  `caFile` reported without its name. The method tests found a seventh: `check` finding nothing when called
  without its defaults.
- Step 4, throwaway. `smoke/neg-a.sh` to `neg-e.sh`, 33 cases through swamp, all pass. They found two more: fetch
  keeps a TLS failure's reason in `cause`, so `health` could not tell a bad chain from a dead host; and `queryData`
  has no `modelId` field, which the unit fake had accepted. `inventory` twice gives identical records; no secret or
  root access key anywhere in `.swamp`. Quality 100%.
- Step 4, hov1, same day. The root key pair is now also in Proton Pass (vault Dataverket, item "hov1 versitygw
  root"), copied by the operator from `backup/hov1/.env`; `pass-cli run --env-file ~/.config/hov1-root.env`
  supplies it through `rootKeyEnv`. From a scratch repository loading the extension from source: `health` 200 over
  a chain verified against `certs/ca.crt`; two accounts and two buckets, `cnpg-forgejo` and `cnpg-zitadel`, each
  `user` and owning its namesake; versioning off, no policy, no object lock. Two inventories identical; `check`
  clean.
- Step 5, done. The adversarial review found three small things, fixed: no log line on entry, a replaced TLS
  client not closed, an address literal in the README. Validating the fabrikk-infra definition found one more: a
  pre-flight check sees the definition's arguments before the schema's defaults, so a definition without
  `accessKeyName` looked for a variable named "undefined"; the checks now apply the defaults, with two negative
  tests. `models/@dataverket/versitygw/gateway/hov1-s3.yaml` is written and validates under `pass-cli run`, and is
  committed with the pin. Without the key, `swamp model validate hov1-s3` fails
  the live check by design (`ROOT_ACCESS_KEY is not set in the environment`); `--label policy` skips it.
  Published by the operator with their review, pulled and pinned here. `hov1-s3` from this repository validates
  with and without the key (`--label policy` without), and its `inventory` and `check` on hov1 are clean.

Differences from the plan above:

- A wrong region is `AuthorizationHeaderMalformed` with a `<Region>` element, not a code of its own; the transport
  reports it as `IncorrectRegion` with both regions named.
- `check` finds its inventory by a tag `inventory` writes on every record, not by `workflowRunId`, so it works
  the same outside a workflow. Without `inventoryId` it takes the latest inventory.
- `check`'s rules and allowed roles are arguments, defaulting to this estate's layout, since the extension is
  published for others too. `account-role` covers `admin` and `userplus` alike.
- The root access key is not recorded either: `ownerIsRoot` on a bucket, `<root>` in an ACL or policy.
- An object-lock bucket has versioning `Enabled` whether or not anyone set it; `check` says so in the finding.
- v1.8.0 answers `500 InternalError`, not 404, on an admin path that does not exist.

The root key pair is also in `vaults/operator/hov1/root/` now (decision 016). Which copy `pass-cli run` reads is
step 5 of `docs/plans/2026-09-operator-vault.md`.

Next: the write methods listed as out of scope above, when `bin/user` has been compared against the read side for a
while.

