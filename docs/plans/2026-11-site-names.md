# Plan: the site's names, and the site's own identity

Written 2026-11-07 under decision 034. Three goals: two small ones that follow directly from the decision, one
structural one that waits for extension work. Each is one branch, unsigned, that ends with a stop for the operator's
signed merge; Flux reads `main`. Audit lines go under the heading at the end.

## What is already as 034 wants it

`dataverket.s3.osl1.dvkt.no` (029); `git`, `forum`, `www`, `registry` and `id` on the upstream's zone; Flux fetching
every configuration artifact through `zot.zot.svc.cluster.local:5000` (013); the swamp Zitadel definitions, the
operator login and `ExternalDomain` on `id.dataverket.org`.

## R1: the site-local registry name

`registry.osl1.dvkt.no` is the same zot by a second name; at the upstream's own site there is nothing to mirror.

| Change | Where |
|---|---|
| Listener `https-registry-osl1`, hostname `registry.osl1.dvkt.no`, certificate `registry-osl1-dvkt-no-tls` from the Gateway's cert-manager annotation, the shape of `https-id-osl1` | `infrastructure/envoy/gateway.yaml` |
| The hostname on zot's route, with its own parentRef | `artifacts/zot/httproute.yaml`, pushed as the artifact |
| `ConfigMap cluster-vars` in `flux-system` with `SITE: osl1`; `postBuild.substituteFrom` on the three Kustomizations that apply artifacts carrying image references (`www`, `offentlig-data`, `zulip`) and on no other: `apps/zitadel/release.yaml` holds `${ZITADEL_EXTERNALDOMAIN}` for Zitadel itself | `clusters/production/cluster-vars.yaml`, `apps/{www,offentlig-data,zulip}/source.yaml` |
| `${SIGNAL_GROUP_LINK}` in www's nginx config escaped as `$${SIGNAL_GROUP_LINK}`, so Flux hands it on untouched | `artifacts/www/nginx-conf.yaml` |
| The kubelet's pulls on `registry.${SITE}.dvkt.no`: www's site image, offentlig-data's image, Zulip's Postgres image | the three artifacts |
| `registry-api-osl1` endpoint check beside `registry-api`; the health workflow carries both | `models/@dataverket/http/endpoint/`, `workflows/workflow-health.yaml` |
| The mirror plan names the site name as what Talos and containerd ask | `docs/plans/2026-10-registry-mirror.md` |

Done when: the listener is Programmed and the certificate Ready; `crane digest` through the `registry` definition
answers for the nats mirror by the new name; each moved image runs from it; health green with both registry checks.
Rollback: revert and push the artifacts again; the old name never stopped answering.

## R3: tenant-first repository paths

Dataverket's images move under `dataverket/`: `platform/www-site` → `dataverket/www-site`,
`sites/offentlig-data` → `dataverket/offentlig-data`, `platform/postgresql-zulip` → `dataverket/postgresql-zulip`.
The platform's `mirror/` and the `platform/*-config` deployment artifacts stay. Done with R1 in one round of pushes,
so the pods roll once: the build scripts (`artifacts/www/site.sh`, `artifacts/zulip/postgres-image.sh`) push to the
new paths, the offentlig-data image is copied once by digest to its new path (its builder lives in another
repository and follows), the references carry `registry.${SITE}.dvkt.no/dataverket/…`. zot's `**` policy already
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
