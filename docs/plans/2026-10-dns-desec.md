# Plan: a site's zone on deSEC, delegated from Nordhost

Written 2026-10-05. Nothing is applied. Every site gets a zone of its own, `<site>.dvkt.no`, hosted on deSEC and
delegated from `dvkt.no` at Nordhost, which stays the registrar. The first site is a future hov1 cluster,
`hov1.dvkt.no`, where nothing in production depends on the outcome; `osl1.dvkt.no`, the production cluster's zone,
moves second, by the same steps; `dataverket.org` moves last, as a whole zone.

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
`max_age`, `max_unused_period`, and `perm_manage_tokens`, so a bounded token is minted by a token, not by a person's
password. DNSSEC is automatic.

## Goals

1. **A site's cluster writes only its own zone**, with a token limited to that zone, to the site's egress address,
   and to a lifetime.
2. **Tokens are minted, not shared.** One management token, operator-only, mints each site's token; rotation is a
   workflow.
3. **The procedure is the same for every site**, proven on a site with nothing to lose before it touches
   production.
4. **The integrator retires** zone by zone; cert-manager and external-dns reach deSEC through maintained community
   webhooks.
5. **Mail stays where it is.** The apex of `dvkt.no`, its MX and DKIM, remain in DirectAdmin.

## Shape, per site

| Piece | Choice |
|---|---|
| Zone | `<site>.dvkt.no`, its own domain in deSEC. The parent `dvkt.no` at Nordhost holds NS records for `<site>` to deSEC's servers and the DS records deSEC prints |
| Account | One deSEC account for Dataverket; credentials in `vaults/operator/desec/` (decision 016) |
| Management token | `perm_manage_tokens`, no write policy of its own, operator-only, never in a cluster or the swamp vault |
| Site token | Default policy `perm_write: false`; one policy `domain: <site>.dvkt.no, perm_write: true`; `allowed_subnets`: the site's egress address, `/32`; `max_age: 90d`; `max_unused_period: 14d`. One sops-encrypted Secret in the site's `infrastructure/`, read by both webhooks |
| external-dns | `desec-community/external-dns-desec-webhook-rs` as the chart's webhook provider; `interval: 5m`, `triggerLoopOnEvent: true`, `policy: sync` |
| cert-manager | `pr0ton11/cert-manager-desec-webhook`; a solver on `letsencrypt-prod` selected by `dnsZones: [<site>.dvkt.no]`; the Nordhost solver stays for zones not yet moved |
| Limits designed around | deSEC: 2000 authenticated requests a day per account, 300 record writes a day per zone, minimum TTL 3600 s. One cluster at a 5-minute interval uses under 600 reads a day; the account's quota bounds how many sites share it |

## Sites, in order

| Site | Zone | Egress | What depends on it today |
|---|---|---|---|
| hov1, a future cluster at the hov1 site | `hov1.dvkt.no` | the site's public address | Nothing. The backup endpoint stays an address (decision 020); `s3.hov1.dvkt.no` is the first name the zone would carry, when the endpoint gets one |
| osl1, dataverket-prod | `osl1.dvkt.no` | `91.242.200.102`, the project router's SNAT address | `dataverket.s3.osl1.dvkt.no`, the wildcard certificate `*.s3.osl1.dvkt.no` |
| the organization's names | `dataverket.org`, the whole zone | as osl1 | `git`, `registry`, `zitadel`, `signal`; names at the zone's own level cannot be delegated, so the zone moves whole |

## Steps, for the first site

1. **Verify at Nordhost** that the domain panel accepts DS records for `dvkt.no`. Without DS the delegation works
   unsigned. Verify at deSEC that a subzone of a domain they do not register is accepted, and the account's domain
   limit.
2. **Account and zone.** The deSEC account, the management token, the zone `hov1.dvkt.no`. Operator credentials
   into `vaults/operator/desec/`.
3. **The site token**, minted with the management token under the policies above, encrypted into the hov1
   cluster's `infrastructure/desec/desec-token.enc.yaml`.
4. **The webhooks** in that cluster's `infrastructure/`: the external-dns provider and the cert-manager solver,
   both referencing the one Secret. Check: a throwaway certificate for a name under `hov1.dvkt.no` reaches
   `Ready` through the deSEC solver, and an `HTTPRoute` gets its `A` record at deSEC's servers.
5. **Delegate.** NS and DS for `hov1` in `dvkt.no` at Nordhost, from your session. Check: `dig +trace` for the
   name ends at deSEC's servers with the right address.
6. **Rotation as a workflow**: `desec-token-rotate`, run by an operator session with the management token, mints
   the next site token, writes the Secret, and deletes the previous one after Flux has applied. `admin:status`
   shows the token's `max_age`.
7. **Record it**: a decision that DNS credentials are minted and bounded per site, and this procedure in the
   site's docs.

## Then osl1

Steps 2 to 6 again for `osl1.dvkt.no`, on a quiet day: the zone created with `dataverket.s3.osl1.dvkt.no` copied in
before the delegation changes, the webhooks added beside the Nordhost ones, a forced renewal of the wildcard
certificate through the deSEC solver as the check, then the `dvkt.no` entry removed from `nordhost-config` and its
login key deleted at Nordhost. The integrator keeps serving `dataverket.org` until the last step.

## Then dataverket.org

The same, on the whole zone: records copied, NS and DS changed at Nordhost, the Nordhost solver and
`nordhost-config` removed, `nordhost-webhook` and its Secret deleted, `nordhost-integrator` archived.

## What is assumed and must be checked

- Nordhost exposes DS record entry for `.no` domains; Norid supports DNSSEC, registrars differ.
- The two webhooks handle a zone delegated below the apex as the zone and not as a name in `dvkt.no`; the Rust
  provider's `DESEC_DOMAIN_FILTER` and the solver's zone lookup are where to look.
- Both webhooks read the Secret once at start, so a rotation is a Secret change and two restarts.
- The hov1 cluster exists before step 3; until it does, steps 1 and 2 can run alone and the zone sits empty.

## Not in this plan

- DNS as a product for the offering. One deSEC account's request quota serves a few sites, not many; the
  offering's DNS plane is authoritative servers of Dataverket's own with RFC 2136 and TSIG per zone, delegated a
  zone per site from the same parents. deSEC is the bridge with the right credential model.
- The hov1 backup endpoint, which stays an address by decision 020 whatever the zone holds.
- Issues #1 to #3 on `nordhost-integrator`; they matter only while a zone is still at Nordhost.
