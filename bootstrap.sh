#!/bin/sh
# The complete bootstrap of dataverket-prod, and its recovery. Every step checks state and skips what is done, so
# this one script is the fresh-cluster path, the recovery path, and the documentation of both. It needs kubectl,
# kubectl-cnpg, flux, sops, git, yq and jq, and an operator's YubiKey; nothing else. Why each step is shaped as it
# is: docs/decisions/.
#
#   ./bootstrap.sh                   Flux reads git.dataverket.org, the source of record
#   ./bootstrap.sh --source github   Flux reads the GitHub mirror, read-only: a rebuild while Forgejo is gone (021)
set -eu
cd "$(dirname "$0")"

source=dataverket
while [ $# -gt 0 ]; do
  case "$1" in
    --source) source=${2:?--source needs dataverket or github}; shift 2 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) echo "bootstrap.sh: unrecognized argument $1" >&2; exit 1 ;;
  esac
done
case "$source" in
  dataverket) url=https://git.dataverket.org/dataverket/fabrikk-infra.git ;;
  github)     url=https://github.com/dataverket-org/fabrikk-infra.git ;;
  *) echo "bootstrap.sh: --source is dataverket or github, not $source" >&2; exit 1 ;;
esac

ctx=${KUBE_CONTEXT:-dataverket-prod-admin}
k() { kubectl --context "$ctx" "$@"; }
step() { printf '\n== %s\n' "$*"; }

for tool in kubectl kubectl-cnpg flux sops git yq jq; do
  command -v "$tool" >/dev/null || { echo "$tool not on PATH (Brewfile; fabrikk pins flux under _tools/bin)" >&2; exit 1; }
done

step "Recipients: every encrypted file matches its rule in .sops.yaml (decision 002)"
bin/check-recipients

step "Flux, reading $url (git.dataverket.org is the source of record, GitHub its push mirror)"
if k -n flux-system get kustomization flux-system >/dev/null 2>&1; then
  echo "flux-system exists; skipping. To rotate the forge token, rerun the flux bootstrap line by hand."
else
  # A fresh cluster restores every database from the archive git names, and must not archive back into it (021).
  # The check reads this checkout, so the checkout must be exactly what Flux will fetch from $url.
  if [ -n "$(git status --porcelain)" ]; then
    echo "The working tree has changes. Commit and push them to $url (main), then rerun." >&2
    exit 1
  fi
  served=$(git ls-remote "$url" refs/heads/main | cut -f1)
  if [ "$served" != "$(git rev-parse HEAD)" ]; then
    echo "$url serves main at ${served:-nothing}, this checkout is at $(git rev-parse HEAD)." >&2
    echo "Push this checkout to $url (main), or check out what it serves, then rerun." >&2
    exit 1
  fi
  if [ "$source" = dataverket ]; then
    cat <<'MSG'
git.dataverket.org is up, so the old cluster may be too. If the check below asks for a commit, it must not reach
main while the old cluster runs: its Flux would apply it and start writing to the archive the restore needs (021).
MSG
  fi
  bin/check-recovery-names "$url"
  if [ "$source" = dataverket ]; then
    flux --context "$ctx" bootstrap gitea \
      --hostname=https://git.dataverket.org --owner=dataverket --repository=fabrikk-infra \
      --branch main --path=./clusters/production --personal --token-auth
  else
    # Read-only: the mirror is public and gotk-sync.yaml has no secretRef. The check above has made sure it names
    # the mirror; a later commit points it back at git.dataverket.org once Forgejo is restored. Flux comes from the
    # repository's own gotk-components.yaml, not the CLI's version, so its first reconcile changes nothing.
    k apply --server-side -f clusters/production/flux-system/gotk-components.yaml >/dev/null
    k wait --for=condition=established --timeout=5m \
      crd/gitrepositories.source.toolkit.fluxcd.io crd/kustomizations.kustomize.toolkit.fluxcd.io >/dev/null
    k apply -f clusters/production/flux-system/gotk-sync.yaml
  fi
fi

step "The cluster's SOPS key: generated in-cluster, never leaves it (bootstrap/sops-age-keygen.yaml)"
k -n flux-system delete job sops-age-keygen --ignore-not-found >/dev/null
k apply -f bootstrap/sops-age-keygen.yaml >/dev/null
k -n flux-system wait --for=condition=complete --timeout=5m job/sops-age-keygen >/dev/null
recipient=$(k -n flux-system get configmap sops-age-recipient -o jsonpath='{.data.recipient}')
if ! grep -q "$recipient" .sops.yaml; then
  cat <<MSG
This cluster's recipient is not in .sops.yaml:   $recipient
Human step: put it there, run 'sops updatekeys' on every *.enc.yaml (YubiKey), commit, merge, rerun this script.
MSG
  exit 2
fi
echo "recipient $recipient is in .sops.yaml; Flux can decrypt"

step "zot from git until it serves its own config (bootstrap/zot-from-git.yaml)"
if [ "$(k -n flux-system get kustomization zot -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)" = True ]; then
  echo "kustomization/zot is Ready from the registry; skipping the git path"
else
  k apply -f bootstrap/zot-from-git.yaml >/dev/null
  k -n flux-system wait --for=condition=ready --timeout=10m kustomization/zot-bootstrap >/dev/null
  echo "zot is up from git"

  step "First artifact into zot (artifacts/zot/push.sh, YubiKey)"
  artifacts/zot/push.sh
  until k -n flux-system get ocirepository zot-config >/dev/null 2>&1; do sleep 10; done
  flux --context "$ctx" reconcile source oci zot-config -n flux-system >/dev/null
  k -n flux-system wait --for=condition=ready --timeout=10m kustomization/zot >/dev/null
  echo "kustomization/zot is Ready from the registry"
fi
if k -n flux-system get kustomization zot-bootstrap >/dev/null 2>&1; then
  k -n flux-system delete kustomization zot-bootstrap >/dev/null
  echo "removed the git path; zot serves its own config (no prune, zot stays)"
fi

step "Still created by hand until migrated to *.enc.yaml"
cat <<'MSG'
  kube-system/cloud-config                                      apply-secret.sh from cloud.conf
  forgejo/forgejo-admin, forgejo-mailer, forgejo-zitadel-oauth-secret   see apps/forgejo/*.example.yaml
  cert-manager/nordhost-config                                  config.json: DirectAdmin credentials per zone (nordhost-integrator); dataverket.org today, dvkt.no next
  forgejo-runners/org-dataverket-runner-secret                  runner registration token
MSG

# A restored cluster's ScheduledBackup may fire during recovery and fail, and the -first Backups in git were taken
# for the old clusters (021), so every CNPG cluster git names gets a base backup here unless it has a completed one
# since it was created. The list comes from git, since on a fresh cluster Flux may not have made the Clusters yet.
# Rerunning skips what is done.
step "A first base backup of every CNPG cluster that has none since it was created"
clusters=$(find apps -name '*.yaml' ! -name '*.enc.yaml' -exec yq -r \
  'select(.kind == "Cluster" and (.apiVersion // "" | test("^postgresql.cnpg.io/"))) |
   .metadata.namespace + " " + .metadata.name' {} + | grep -v '^---$' | sort -u)
[ -n "$clusters" ] || echo "git names no CNPG cluster under apps/"
while read -r ns name; do
  [ -n "$name" ] || continue
  created=$(k -n "$ns" get "cluster.postgresql.cnpg.io/$name" -o jsonpath='{.metadata.creationTimestamp}' \
    2>/dev/null </dev/null || true)
  if [ -z "$created" ]; then
    echo "$ns/$name does not exist yet: Flux has not applied apps/, or it waits on a Secret above. Rerun later."
    continue
  fi
  done_count=$(k -n "$ns" get backups.postgresql.cnpg.io -o json </dev/null |
    jq -r --arg c "$name" --arg t "$created" \
      '[.items[] | select(.spec.cluster.name == $c and .status.phase == "completed" and .metadata.creationTimestamp >= $t)] | length' ||
    true)
  if [ "${done_count:-0}" -gt 0 ] 2>/dev/null; then
    echo "$ns/$name has a completed backup since it was created"
    continue
  fi
  if ! k -n "$ns" wait --for=condition=Ready --timeout=15m "cluster.postgresql.cnpg.io/$name" >/dev/null 2>&1 </dev/null; then
    echo "$ns/$name is not ready yet; once it is, rerun this script or run:"
    echo "  kubectl cnpg backup $name -n $ns --method plugin --plugin-name barman-cloud.cloudnative-pg.io"
    continue
  fi
  backup="$name-bootstrap-$(date -u +%Y%m%d%H%M)"
  # kubectl takes no flags before a plugin name, so the context goes last.
  kubectl cnpg backup "$name" -n "$ns" --method plugin --plugin-name barman-cloud.cloudnative-pg.io \
    --backup-name "$backup" --context "$ctx" </dev/null
  # Wait for completed or failed, so a failed backup stops here and does not hold the script for the timeout.
  phase=
  tries=0
  while [ "$phase" != completed ] && [ "$phase" != failed ] && [ "$tries" -lt 180 ]; do
    sleep 10
    phase=$(k -n "$ns" get "backup.postgresql.cnpg.io/$backup" -o jsonpath='{.status.phase}' </dev/null || true)
    tries=$((tries + 1))
  done
  if [ "$phase" != completed ]; then
    echo "$ns/$name: $backup is ${phase:-still running} after $((tries * 10)) s; see kubectl cnpg status $name -n $ns" >&2
    exit 1
  fi
  echo "$ns/$name: $backup completed"
done <<EOF
$clusters
EOF
