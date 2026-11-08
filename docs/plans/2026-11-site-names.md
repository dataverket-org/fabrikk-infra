# Plan: the site's names, and the site's own identity

Written 2026-11-07 under decision 034. Three goals: two small ones that follow directly from the decision, one
structural one that waits for extension work. Each is one branch, unsigned, that ends with a stop for the operator's
signed merge; Flux reads `main`. Audit lines go under the heading at the end.

## What is already as 034 wants it

`dataverket.s3.osl1.dvkt.no` (029); `git`, `forum`, `www`, `registry` and `id` on the upstream's zone; Flux fetching
every configuration artifact through `zot.zot.svc.cluster.local:5000` (013); the swamp Zitadel definitions, the
operator login and `ExternalDomain` on `id.dataverket.org`.

## R1: the site-local registry name

`registry.osl1.dvkt.no` is the same zot by a second name; at the upstream's own site there is nothing to mirror. It
is the site's mirror endpoint: Talos sends pulls of `registry.dataverket.org` to it. A tenant's manifests keep naming
`registry.dataverket.org`, so they are true at any site (034).

| Change | Where |
|---|---|
| Listener `https-registry-osl1`, hostname `registry.osl1.dvkt.no`, certificate `registry-osl1-dvkt-no-tls` from the Gateway's cert-manager annotation, the shape of `https-id-osl1` | `infrastructure/envoy/gateway.yaml` |
| The hostname on zot's route, with its own parentRef | `artifacts/zot/httproute.yaml`, pushed as the artifact |
| The machines' registry mirror: `registry.dataverket.org` → `https://registry.osl1.dvkt.no`, no path override, beside the `docker.io` mirror the mirror plan describes | Talos machine configuration through Omni, outside this repository; the operator's |
| `registry-api-osl1` endpoint check beside `registry-api`; the health workflow carries both | `models/@dataverket/http/endpoint/`, `workflows/workflow-health.yaml` |
| The mirror plan names the site name as what Talos and containerd ask | `docs/plans/2026-10-registry-mirror.md` |

Done when: the listener is Programmed and the certificate Ready; `crane digest` through the `registry` definition
answers for the nats mirror by the new name; health green with both registry checks; and, once the machines carry the
mirror entry, a pull of a `registry.dataverket.org` image is served by the site's name. Rollback: revert; the old name
never stopped answering.

## R3: tenant-first repository paths

Dataverket's images move under `dataverket/`: `platform/www-site` → `dataverket/www-site`,
`sites/offentlig-data` → `dataverket/offentlig-data`, `platform/postgresql-zulip` → `dataverket/postgresql-zulip`.
The platform's `mirror/` and the `platform/*-config` deployment artifacts stay. The build scripts (`artifacts/www/site.sh`,
`artifacts/zulip/postgres-image.sh`) push to the new paths, the offentlig-data image is copied once by digest to its
new path (its builder lives in another repository and follows), the references carry
`registry.dataverket.org/dataverket/…`, the tenant's registry of record. zot's `**` policy already
lets `fabrikk-ci` create there. The old repositories are deleted when the pods run from the new.

## R4: the site's own identity

Today `id.dataverket.org` and `id.osl1.dvkt.no` are one Zitadel instance, the upstream's, which also stands in for
the site. 034 wants a site instance: the site's machines, and the tenants its services see as organizations. It is
one Zitadel deployment hosting two instances, resolved by the request's `Host`; the login pod and the System API
user already serve every instance.

| Step | What | Done when |
|---|---|---|
| 1 | `@dataverket/zitadel/system` learns instances: `instanceList`, `instanceCreate` (first organization and a first admin), and the domain methods take `instanceId`; published and pulled | the smoke suite's throwaway runs two instances and lists both |
| 2 | The site instance, created through `task admin:zitadel-domains`'s pattern with the System API key: organization `osl1`, you as its first admin; SMTP only if it ever mails anyone | `instanceList` shows two |
| 3 | On the upstream's instance `domainSetPrimary id.dataverket.org`, then `domainRemove id.osl1.dvkt.no`; on the site's `domainAdd id.osl1.dvkt.no`, primary. The HTTPRoute is unchanged: both names already reach the same pods | `domainList` per instance shows one name each plus generated twins; `zitadel-oidc-id-osl1` answers the site instance's issuer |
| 4 | Organization `dataverket` in the site instance with the service users site services need (Zulip's S3 access, when the S3 plan lands); the operator's passkey at `id.osl1.dvkt.no` by the link workflow with the alias as URL template; the Kubernetes issuer of 015 is the site instance | the S3 plan and 015 build on it |

Rollback at each step is the reverse domain operation; nothing people bind to changes until step 3, and step 3
changes only which instance answers on the site alias, which no person uses yet.

## Not in this plan

- The overlay repository (`miljo`), which is where `cluster-vars` and every per-site value go when it exists.
- A registry mirror at a second site; the mirror plan.
- Federation from the site instance to a tenant's instance for a tenant's people; built when a person needs it.

## Audit

### 2026-11-08, R1 and R3

**Status:** Done, in two commits merged by you (`18539c2`, then the correction `0aa6f19`) and four artifact pushes.

| Finding | Where | Assessment |
|---------|-------|------------|
| The site name | listener `https-registry-osl1` Programmed, certificate `registry-osl1-dvkt-no-tls` issued by DNS-01 in about two minutes; the hostname on zot's route, the A record made by external-dns once the zot artifact applied | `https://registry.osl1.dvkt.no/v2/` 200 with the site's certificate; the nats mirror manifest and `dataverket/www-site` answer 200 by the site name |
| A correction on the way | the first commit put `registry.${SITE}.dvkt.no` into the tenants' manifests through a Flux-substituted ConfigMap; you pointed out that offentlig-data and Zulip are Dataverket's services and must name Dataverket's registry of record | reverted the same morning: tenant manifests name `registry.dataverket.org/dataverket/…`; the site's name is the machines' mirror endpoint, to be set in the Talos registry mirror configuration through Omni, outside this repository, by you. 034's consequence rewritten to say so |
| Tenant-first paths | `dataverket/offentlig-data` copied once by digest with the ci credential (two sequential `sops` reads: two at once garble the YubiKey's answer); `dataverket/www-site` and `dataverket/postgresql-zulip` pushed by their own scripts, same digests as before | offentlig-data runs `registry.dataverket.org/dataverket/offentlig-data:latest`; www rolled 09:29 UTC on its new site reference; Zulip's Postgres restarted 09:32 UTC on the renamed image. The old `sites/offentlig-data`, `platform/www-site` and `platform/postgresql-zulip` repositories still exist and are deleted when nothing names them; the offentlig-data builder in its own repository still pushes to `sites/` and follows |
| GitHub in the way | `infrastructure` failed its build for an hour: `github.com/cloudnative-pg/plugin-barman-cloud/releases/download/…` answered 504, and every app Kustomization depends on `infrastructure` | nothing running changed, the four artifacts waited; the remote manifests of `cnpg-operator` and `cnpg-barman-plugin` are to be vendored, the next goal |
| Health | run `555c096e` green with `registry-api` and `registry-api-osl1` | done |

Left of R1: the Talos mirror entry (`registry.dataverket.org` → `https://registry.osl1.dvkt.no`), yours through Omni;
until then the kubelet pulls from the registry of record directly, which at this site is the same zot.

**Action Required:** The Talos mirror entry; delete the three old repositories when the offentlig-data builder has moved.
