# Runbook: move a database to a new Postgres minor, and CloudNativePG with it

Written 2026-11-22 from a run in a local kind cluster. Run on the cluster on 2026-11-24 for the operator, the
plugin and the forge's database, and on 2026-11-25 for Zulip's and Zitadel's databases: operator 1.30.0 to 1.30.2,
plugin 0.15.0 to 0.16.0, Postgres 18.4 to 18.7.

## Why

Postgres ships its security fixes in a minor release every quarter; 18.6 and 18.7 fixed 80 CVEs between them.
A minor needs no dump and restore, only a restart on the new image. The operator and its Barman Cloud plugin are
vendored manifests (decision 035) and are moved the same way. Each of the three restarts every database the
operator runs, so they are done in one sitting.

## What it touches

| What | Read or written | Needs |
|---|---|---|
| `share/vendor.sh`, `artifacts/cnpg/` | Written, on a branch | Nothing; GitHub must answer |
| `imageName` in `artifacts/<service>/postgres.yaml` and `backup/restore-test/` | Written, on the same branch | Nothing |
| `platform/cnpg-config`, `platform/<service>-config` in zot | Pushed | A YubiKey, two touches each |
| Every CNPG database: `forgejo-postgres`, `zitadel-db`, Zulip's | Restarted by the operator; a base backup taken before and after | `dataverket-prod-admin` (`task admin:start`) |
| The data, the archive on hov1, `*.enc.yaml`, `.sops.yaml` | Never touched | |

## What a restart costs

Measured in kind on 2026-11-22 on a database of one instance:

| Change | What the operator does | The database refuses connections for |
|---|---|---|
| The operator's own version | Restarts every instance, to replace the instance manager | 3 min 20 s with the forge connected |
| The plugin's version | Restarts every instance, to replace the sidecar | 40 s with the forge stopped |
| `imageName` | Restarts the instance on the new image | 25 s with the forge stopped |

The three minutes are Postgres waiting for its clients' idle connections to close, up to `smartShutdownTimeout`,
180 seconds. With the client stopped first there is nobody to wait for.

On the cluster the same wait cost each service differently:

| Service | Instances | Seen |
|---|---|---|
| The forge, 2026-11-24 | 1 | The operator and the plugin, pushed in one artifact, gave one restart, not two. The forge went on answering over its open connections during the wait and was away for about 25 seconds |
| Zulip, 2026-11-25 | 1 | A new `imageName` took Zulip away for 3 min 15 s. It answered 500 from the start of the wait, and its container stopped and started again by itself, once |
| Zitadel, 2026-11-25 | 3 | A new `imageName` restarted the two replicas in 15 seconds each, then the primary in place (`primaryUpdateMethod: restart`), which took a little over three minutes. Logins at `id.dataverket.org` failed for that time. Zitadel's pods failed their readiness probes and came back by themselves, with no restart; a kube context already minted kept working |

So the wait is not downtime for the forge, and it is downtime for Zulip and for logins. Three instances do not
shorten it while the primary is restarted in place.

## Steps

1. Read the notes: the "Migration" section of every Postgres minor between the running one and the new one, at
   `https://www.postgresql.org/docs/release/<version>/`, and the releases of
   `https://github.com/cloudnative-pg/cloudnative-pg` and `https://github.com/cloudnative-pg/plugin-barman-cloud`. A
   line that asks for a `REINDEX`, a setting or a new backup becomes part of step 7.

2. On a branch, the operator and the plugin: the two rows of `share/vendor.sh` and the two names in
   `artifacts/cnpg/kustomization.yaml`. The SHA-256 of a row is the pin, so it is computed from the release itself
   and read back:

   ```sh
   git mv artifacts/cnpg/cnpg-<old>.yaml artifacts/cnpg/cnpg-<new>.yaml
   git mv artifacts/cnpg/plugin-barman-cloud-v<old>.yaml artifacts/cnpg/plugin-barman-cloud-v<new>.yaml
   curl -fsSL <the row's new url> | shasum -a 256
   $EDITOR share/vendor.sh artifacts/cnpg/kustomization.yaml
   bin/vendor && bin/vendor --check
   ```

   Read the diff of each manifest with the CRDs left out; between 1.30.0 and 1.30.2 it was the image and one RBAC
   verb.

3. On the same branch, `imageName` in the database's `postgres.yaml` and in its file under `backup/restore-test/`.
   Zulip's image is built from the same tag by `artifacts/zulip/postgres-image.sh` (`artifacts/zulip/README.md`):
   set `tag=` and `base=` in the script, `base=` to
   `crane digest --platform linux/amd64 ghcr.io/cloudnative-pg/postgresql:<tag>`, and run it; it writes the new
   reference into `postgres.yaml`. A `tag=` without its `base=` builds the old Postgres under the new name.
   Commit, push, open the pull request, merge it with the forge's button.

4. `dataverket-prod-admin`. The five-minute check of `backup/cnpg-backups.md` must read healthy, and a base backup
   of each database is taken now ("Take a base backup now", the same file). Do not go on with archiving failing:
   a restart does not mend it, and WAL then fills the volume.

5. YubiKey, two touches. From a clean checkout of `main` at the merge, the operator and the plugin, and the wait
   for every database to be healthy again:

   ```sh
   git switch main && git pull --ff-only
   bin/artifact cnpg --push
   flux --context dataverket-prod-admin reconcile kustomization cnpg --with-source
   kubectl --context dataverket-prod-admin get cluster -A -w
   ```

   Every `STATUS` passes through `Primary instance is being restarted without a switchover` and returns to
   `Cluster in healthy state`. On the cluster on 2026-11-24 this happened once for both together.

6. YubiKey, two touches for each service. The image:

   ```sh
   bin/artifact forgejo --push
   flux --context dataverket-prod-admin reconcile kustomization forgejo --with-source
   kubectl --context dataverket-prod-admin -n forgejo get cluster forgejo-postgres -w
   ```

   To make the operator's and the plugin's restarts short for the forge, stop it around step 5. Flux puts the
   replica back on its next apply, so it is told to wait:

   ```sh
   flux --context dataverket-prod-admin suspend kustomization forgejo
   kubectl --context dataverket-prod-admin -n forgejo scale deployment/forgejo --replicas=0
   # step 5, then: bin/artifact forgejo --push
   flux --context dataverket-prod-admin resume kustomization forgejo
   ```

   The resume applies the new image and the forge's replica in one apply, so the forge starts while its database
   restarts a third time and waits for it; whether that restart is the short or the long one was not measured. The
   scale to zero and each restart were tested in kind; the suspend and the resume were not, since kind ran no Flux,
   and they were not used on the cluster either.

   Zulip's image is pushed by `bin/artifact zulip --push` itself, before the manifests. Its Kustomization may first
   report `dependency 'flux-system/cnpg' is not ready`; on 2026-11-25 it applied by itself 20 seconds later.

7. What the notes of step 1 asked for. 18.7 asks for a `REINDEX` of GIN indexes, of btree indexes on a `bpchar`
   column with no length, and of `gist_trgm_ops` indexes. What a database has of each:

   ```sh
   kubectl cnpg psql forgejo-postgres -n forgejo --context dataverket-prod-admin -- -d forgejo -At \
     -c "select am.amname, count(*) from pg_index i join pg_class c on c.oid = i.indexrelid join pg_am am on am.oid = c.relam join pg_namespace n on n.oid = c.relnamespace where n.nspname not in ('pg_catalog', 'pg_toast', 'information_schema') group by 1" \
     -c "select c.relname from pg_index i join pg_attribute a on a.attrelid = i.indrelid and a.attnum = any(i.indkey) join pg_class c on c.oid = i.indexrelid where a.atttypid = 'bpchar'::regtype and a.atttypmod = -1" \
     -c "select c.relname from pg_index i join pg_opclass o on o.oid = any(i.indclass) join pg_class c on c.oid = i.indexrelid where o.opcname = 'gist_trgm_ops'"
   ```

   Zulip's database, asked on 2026-11-25 with `zulip-postgres -n zulip` and `-d zulip`, had 531 btree indexes and
   one GIN index, `zulip.zerver_message_search_tsvector`, 16 kB, rebuilt in under a second.

   Zitadel's database, asked the same day with `zitadel-db -n zitadel` and `-d zitadel`, had 259 btree indexes and
   two GIN indexes, `queue.river_job_args_index` and `queue.river_job_metadata_index`, 24 kB each.

   A database Forgejo 15.0.11 made from nothing has 528 btree indexes and none of the three kinds, so nothing to
   rebuild; the forge's own database is older and is asked itself. An index the queries name is rebuilt with
   `REINDEX INDEX CONCURRENTLY <name>`. Then a base backup of each database, as in step 4, so the newest backup is
   of the new minor.

## Proof

```sh
kubectl --context dataverket-prod-admin get cluster -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,IMAGE:.status.image,STATUS:.status.phase,ARCHIVING:.status.conditions[?(@.type=="ContinuousArchiving")].reason'
kubectl --context dataverket-prod-admin -n cnpg-system get deployment -o custom-columns='NAME:.metadata.name,IMAGE:.spec.template.spec.containers[0].image'
kubectl cnpg psql forgejo-postgres -n forgejo --context dataverket-prod-admin -- -At -c "show server_version" -c "select archived_count, failed_count, last_archived_time from pg_stat_archiver"
```

Every cluster on the new image, healthy and `ContinuousArchivingSuccess`; both deployments on the new versions;
`last_archived_time` within the last minutes and `archived_count` growing when the third command is run twice. Then
the newest `Backup` of each database is `completed`, and a push to the forge works. In kind, after all three
changes, WAL went on arriving in the bucket and a base backup completed on plugin 0.16.0.

| Seen | Means |
|---|---|
| A cluster stays in `being restarted` for three minutes | Postgres is waiting for its clients. It ends by itself at 180 seconds |
| `ContinuousArchivingFailing` after the plugin's restart | The sidecar cannot reach hov1 or was refused; `backup/cnpg-backups.md`, "Logs". Mend it before the volume fills (`docs/storage.md`) |
| `failed_count` grew by a few during a restart and then stopped | The archiver tried while the sidecar was starting. Six such in kind; harmless |
| `bin/vendor --check` refuses a file | The SHA-256 in `share/vendor.sh` is not that of the file; compute it again from the URL, never from the file on disk |
| The forge answers 500 after the restart | It has not reconnected; it did by itself in kind. Restart its pod if it has not after a minute |

## Not part of this

A new Postgres major, which is a migration with a test of its own and which Renovate never proposes. A change of
`serverName` or of the archive (`docs/storage.md`). The restore test, which is quarterly and has its own procedure
(`backup/README.md`). An image scan cannot stand in for step 1: grype does not match Postgres's own CVEs against the
server package (`image-scan.md`).
