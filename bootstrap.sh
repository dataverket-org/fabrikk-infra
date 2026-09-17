#!/bin/sh

set -eu

# git.dataverket.org is the source of record (codeberg.org is a push mirror). Re-running this with --token-auth
# recreates the flux-system secret with a forge token and restores secretRef in gotk-sync.yaml.
flux bootstrap gitea \
  --hostname="https://git.dataverket.org" \
  --owner="dataverket" \
  --repository="flux-bootstrap" \
  --branch main \
  --path=./clusters/production \
  --personal \
  --token-auth

# The cluster's SOPS key, generated in-cluster (bootstrap/sops-age-keygen.yaml). The private key never leaves the
# cluster. On a new cluster the recipient printed here is new: put it in .sops.yaml, `sops updatekeys` every
# *.enc.yaml, commit, and only then continue.
kubectl apply -f bootstrap/sops-age-keygen.yaml
kubectl -n flux-system wait --for=condition=complete --timeout=5m job/sops-age-keygen
printf 'sops recipient for this cluster: %s\n' "$(kubectl -n flux-system get configmap sops-age-recipient -o jsonpath='{.data.recipient}')"

# zot from git until zot can host its own config (bootstrap/zot-from-git.yaml). Then: artifacts/zot/push.sh, wait
# for kustomization/zot, and delete kustomization/zot-bootstrap.
kubectl apply -f bootstrap/zot-from-git.yaml
kubectl -n flux-system wait --for=condition=ready --timeout=10m kustomization/zot-bootstrap
