# Runbook: serve `id.dataverket.org` from another site

Draft, written 2026-11-07 when Zitadel's move to its two names was done. Never run for real:
there is no second cluster to run it against yet, so the steps that need one are marked as such and the exact
commands for them come when it exists. The domain steps have each been run once, in the move of 2026-11-06.

## Why

People and clients bind to `id.dataverket.org`, and that name is the organization's, not the site's (decision
031): when the osl1 site is gone, Zitadel comes back somewhere else under the same name, and every passkey, every
client configuration and every session cookie made against it stays good. What is the site's is
`id.osl1.dvkt.no`, the alias and the primary instance domain, which dies with the site and is replaced by the new
site's own alias. The domain list is written only through the System API user the operators hold (decision 032), so
this job is the one that key exists for.

## What it touches

| | |
|---|---|
| Reads | The CNPG archive of `zitadel-db` at hov1 (`backup/hov1`, `docs/storage.md`), the chart values in `apps/zitadel/release.yaml`, `vaults/operator/osl1/zitadel-system.enc.json` |
| Writes | A new cluster's Zitadel namespace, its routes and listener; Zitadel's instance domain list; the `id.dataverket.org` A record at Nordhost, by hand |
| Keys | The operator's YubiKey for the sops store, once per `task admin:zitadel-domains` run; the cluster's Operator key for Flux and CNPG |
| Never touches | The masterkey (it travels in the sops store as it does today, a restore needs the same one); the passkeys, which are rows in the database; the clients, which never named a site |

## Steps

1. **The database, at the new site** (needs the second cluster). A CNPG `Cluster` bootstrapped from the hov1
   archive as `docs/storage.md` describes for a rebuild, with the same `serverName`; the recovered database is the
   instance, its domains included. Until it is up nothing below applies.
2. **The chart, unchanged in what matters.** `ExternalDomain: id.dataverket.org`, `ExternalSecure: true`,
   `ExternalPort: 443` as today; the same masterkey from the store; `SystemAPIUsers.operators` with the same
   public key. The login pod's `CUSTOM_REQUEST_HEADERS` stays `Host:${ZITADEL_EXTERNALDOMAIN}`. What changes is
   only what names the site: the listener and certificate for the new alias, say `id.<site>.dvkt.no`, in that
   site's `infrastructure/envoy/gateway.yaml`, and the route hostnames `id.dataverket.org` and the new alias.
3. **The record.** `id.dataverket.org` to the new site's address at Nordhost, by hand; external-dns is
   `upsert-only` and will not fight it. The wildcard certificate `*.dataverket.org` is issued by DNS-01 and comes
   up at the new site on its own.
4. **The alias, into the instance** (YubiKey). Typed into your session, each run followed by `domainList`:

   ```
   task admin:zitadel-domains -- domainAdd --arg domain=id.<site>.dvkt.no
   task admin:zitadel-domains -- domainSetPrimary --arg domain=id.<site>.dvkt.no
   task admin:zitadel-domains -- domainList
   ```

   `domainAdd` adds the name and its generated twin; `domainSetPrimary` makes it the primary, which is what
   Zitadel builds its own URLs from when no request host says otherwise (plan, fact 2). The task's `apiUrl` is
   `https://id.dataverket.org`, so it reaches the instance as soon as step 3 resolves.
5. **The old alias, out** (YubiKey). First with `dryRun`, then for real:

   ```
   task admin:zitadel-domains -- domainRemove --arg domain=id.osl1.dvkt.no --arg confirm=id.osl1.dvkt.no --arg dryRun=true
   task admin:zitadel-domains -- domainRemove --arg domain=id.osl1.dvkt.no --arg confirm=id.osl1.dvkt.no
   ```

   Its generated twin stays; Zitadel refuses to remove a generated domain and the method refuses it first.
6. **The definitions and checks.** `models/@dataverket/http/endpoint/zitadel-oidc-id-osl1.yaml` becomes the new
   alias's check and the health workflow follows; the swamp Zitadel definitions already name `id.dataverket.org`
   and need nothing. The Kubernetes issuer, when decision 015 is built, is the new alias: a person who reaches the
   new cluster needs a passkey registered at that alias, minted by the link workflow with the alias as its URL
   template.

## Proof

```
swamp workflow run health
task admin:zitadel-domains -- domainList
swamp behavior run zitadel-user authFactorList --arg user=<your login>
```

Health green with both Zitadel checks; `domainList` showing `id.dataverket.org`, the new alias as primary, and
the generated twins; your own passkey, made at `id.dataverket.org` before the move, listed and working for a login
there. A wrong result: a login page that redirects to the old alias, which is a primary domain not yet set, or a
passkey refused, which is a request reaching Zitadel under a host other than `id.dataverket.org`.

## Not part of this

- Making the second cluster, or the CNPG replica cluster that would make step 1 a promotion rather than a
  restore. Neither exists yet.
- Re-keying anything. The sops store and the System API user's key are the same before and after; a new
  operator is a human step with a YubiKey (operator rules).
- Moving `dataverket.org` itself to deSEC; `docs/plans/2026-10-dns-desec.md`.
