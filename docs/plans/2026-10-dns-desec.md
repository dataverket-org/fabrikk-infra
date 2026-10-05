# Plan: DNS for the cluster's zones on deSEC, delegated from Nordhost

Written 2026-10-05. Nothing is applied. Nordhost stays the registrar; DNS for the cluster's names moves to deSEC,
one delegated subzone first.

## Why

DNS for `dataverket.org` and `dvkt.no` is DirectAdmin at Nordhost, reached through `nordhost-integrator`, with a login
key per zone in the hand-made Secret `cert-manager/nordhost-config`. DirectAdmin's login keys do not fit more than one
cluster:

- A key is scoped per command, never per zone, record or action. `CMD_API_DNS_CONTROL` lists, adds and deletes on
  one key; there is no read-only form.
- Creating a key needs the account password, so neither a cluster nor a workflow can mint or rotate one.
- Deletes select a record by its own `name=...&value=...` string; the API has no conditional write, so writers
  race on a shared zone, and the integrator lists every zone every minute to see state.

deSEC tokens have what is missing: policies per domain, subname and type with `perm_write`, `allowed_subnets`,
`max_age`, `max_unused_period`, and `perm_manage_tokens` so a bounded token can be minted by a token, not a person's
password. DNSSEC is automatic.

## Goals

1. **A cluster writes only its own zone**, with a token limited to that zone, to its egress address, and to a
   lifetime.
2. **Tokens are minted, not shared.** One management token, operator-only, mints each cluster's token; rotation is
   a workflow, not a calendar entry.
3. **The integrator retires** for the zones that move; cert-manager and external-dns reach deSEC through maintained
   community webhooks.
4. **Mail stays where it is.** The apex of `dvkt.no`, its MX and DKIM, remain in DirectAdmin.

## Shape

| Piece | Choice |
|---|---|
| What moves first | `osl1.dvkt.no` as its own zone in deSEC. The parent `dvkt.no` at Nordhost gets NS records for `osl1` to deSEC's servers and the DS records deSEC prints |
| What moves later | `dataverket.org` as a whole zone, since `git`, `registry` and `zitadel` are names at the zone's own level. Until then the cluster runs both DNS paths |
| Account | One deSEC account for Dataverket; credentials in `vaults/operator/` (decision 016) |
| Management token | `perm_manage_tokens`, no write policy of its own, operator-only, never in the cluster or the swamp vault |
| Cluster token | Default policy `perm_write: false`, one policy `domain: osl1.dvkt.no, perm_write: true`; `allowed_subnets: 91.242.200.102/32`, the project router's SNAT address; `max_age: 90d`; `max_unused_period: 14d`. One sops-encrypted Secret in `infrastructure/`, read by both webhooks |
| external-dns | `desec-community/external-dns-desec-webhook-rs` as the chart's webhook provider; `interval: 5m`, `triggerLoopOnEvent: true`, `policy: sync` |
| cert-manager | `pr0ton11/cert-manager-desec-webhook`; a second solver on `letsencrypt-prod` selected by `dnsZones: [osl1.dvkt.no]`, the Nordhost solver kept for the rest |
| Limits designed around | deSEC: 2000 authenticated requests a day per account, 300 record writes a day per zone, minimum TTL 3600 s. One cluster at a 5-minute interval uses under 600 reads a day |

## Steps

1. **Verify at Nordhost** that the domain panel accepts DS records for `dvkt.no`. Without DS the delegation works
   unsigned. Verify at deSEC that a subzone of a domain they do not register is accepted, and the account's domain
   limit.
2. **Account and zone.** The deSEC account, the management token, the zone `osl1.dvkt.no` with the one `A` record it
   holds today, `dataverket.s3.osl1.dvkt.no`, copied in. Operator credentials into `vaults/operator/desec/`.
3. **The cluster token**, minted with the management token under the policies above, encrypted into
   `infrastructure/desec/desec-token.enc.yaml`.
4. **The webhooks** in `infrastructure/`: the external-dns provider swapped, the second cert-manager solver added, both
   referencing the one Secret. Check: `kubectl describe challenge` on a throwaway certificate for a name under
   `osl1.dvkt.no` shows the deSEC solver, and external-dns logs one reconcile per five minutes.
5. **Delegate.** NS and DS for `osl1` in `dvkt.no` at Nordhost, from your session. Check: `dig +trace
   dataverket.s3.osl1.dvkt.no` ends at deSEC's servers with the right address; the wildcard certificate renews
   through the new solver (force one renewal).
6. **Retire** the `dvkt.no` entry from `nordhost-config` and the login key at Nordhost. The integrator keeps
   serving `dataverket.org` until step 7.
7. **`dataverket.org`**, the same steps on the whole zone: records copied, NS and DS changed at Nordhost, the
   Nordhost solver and `nordhost-config` removed, `nordhost-webhook` and its Secret deleted.
8. **Rotation as a workflow**: `desec-token-rotate`, run by an operator session with the management token, mints
   the next cluster token, writes the Secret, and deletes the previous token after Flux has applied. `admin:status`
   shows the cluster token's `max_age`. A decision records that DNS credentials are minted and bounded.

## What is assumed and must be checked

- Nordhost exposes DS record entry for `.no` domains; Norid supports DNSSEC, registrars differ.
- The two webhooks handle a zone delegated below the apex, `osl1.dvkt.no`, as the zone and not as a name in
  `dvkt.no`; the Rust provider's `DESEC_DOMAIN_FILTER` and the solver's zone lookup are where to look.
- `max_age` on a token in use by two webhooks: both read the Secret once at start, so a rotation is a Secret
  change and two restarts, as today.

## Not in this plan

- DNS as a product for the offering. One deSEC account's request quota serves a few clusters, not many; the
  offering's DNS plane is authoritative servers of Dataverket's own with RFC 2136 and TSIG per zone, delegated a
  subzone per cluster from the same parents. deSEC is the bridge with the right credential model.
- The hov1 site's endpoint name, `s3.hov1.dvkt.no`, which stays an address by decision 020.
- Issues #1 to #3 on `nordhost-integrator`; they matter only until step 7.
