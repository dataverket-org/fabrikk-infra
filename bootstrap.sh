#!/bin/sh
# The complete bootstrap of dataverket-prod, and its recovery. Every step checks state and skips what is done, so
# this one script is the fresh-cluster path, the recovery path, and the documentation of both. It needs kubectl,
# flux, sops, git, and an attester's YubiKey; nothing else. Why each step is shaped as it is: docs/decisions/.
set -eu
cd "$(dirname "$0")"

ctx=${KUBE_CONTEXT:-dataverket-prod-admin}
k() { kubectl --context "$ctx" "$@"; }
step() { printf '\n== %s\n' "$*"; }

for tool in kubectl flux sops git; do
  command -v "$tool" >/dev/null || { echo "$tool not on PATH (fabrikk pins flux under _tools/bin)" >&2; exit 1; }
done

step "Flux, reading git.dataverket.org (codeberg.org is a push mirror)"
if k -n flux-system get kustomization flux-system >/dev/null 2>&1; then
  echo "flux-system exists; skipping. To rotate the forge token, rerun the flux bootstrap line by hand."
else
  flux --context "$ctx" bootstrap gitea \
    --hostname=https://git.dataverket.org --owner=dataverket --repository=fabrikk-infra \
    --branch main --path=./clusters/production --personal --token-auth
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
  zitadel/zitadel-masterkey
  cert-manager/nordhost-config                                  config.json: DirectAdmin credentials per zone (nordhost-integrator); dataverket.org today, dvkt.no next
  forgejo-runners/org-dataverket-runner-secret                  runner registration token
MSG
