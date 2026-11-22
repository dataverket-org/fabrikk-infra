#!/bin/sh
# Renders Renovate into rendered/, one file per object and a kustomization.yaml listing them. `--check` renders to a
# temporary directory and compares; bin/artifact renovate --push runs it first.
#
# Inputs: kube/ of the renovate repository at the commit recipe/source.env names, and recipe/kustomization.yaml, the
# cluster's patch of its CronJob. The guard runs in the image the CronJob names, so there is one image to pin.
#
# Needs git, yq and kubectl on PATH.
set -eu
# The order of the list in rendered/kustomization.yaml is the glob's, which follows the locale.
LC_ALL=C; export LC_ALL
cd "$(dirname "$0")"

for tool in git yq kubectl; do
  command -v "$tool" >/dev/null || { echo "$tool not on PATH" >&2; exit 1; }
done

. recipe/source.env

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

git clone --quiet --no-checkout "$RENOVATE_REPO" "$tmp/renovate"
git -C "$tmp/renovate" -c advice.detachedHead=false checkout --quiet "$RENOVATE_COMMIT"

cp recipe/kustomization.yaml "$tmp/renovate/kustomization.yaml"
mkdir "$tmp/out"
kubectl kustomize "$tmp/renovate" -o "$tmp/out"

cronjob="$tmp/out/batch_v1_cronjob_renovate.yaml"
[ -f "$cronjob" ] || { echo "the recipe renders no CronJob named renovate" >&2; exit 1; }
yq -i '.spec.jobTemplate.spec.template.spec |=
  (.initContainers[0].image = .containers[0].image)' "$cronjob"
image=$(yq '.spec.jobTemplate.spec.template.spec.containers[0].image' "$cronjob")

for f in "$tmp/out"/*.yaml; do
  kind=$(yq '.kind' "$f")
  case "$kind" in
    Namespace) ;;
    CronJob|ConfigMap)
      [ "$(yq '.metadata.namespace' "$f")" = renovate ] || { echo "not in namespace renovate: ${f##*/}" >&2; exit 1; }
      ;;
    *) echo "the recipe renders a $kind, which Renovate's kube/ is not expected to hold: ${f##*/}" >&2; exit 1 ;;
  esac
done

{
  echo "# Written by render.sh; do not edit. The renovate repository at $RENOVATE_COMMIT, image $image."
  echo "apiVersion: kustomize.config.k8s.io/v1beta1"
  echo "kind: Kustomization"
  echo "resources:"
  for f in "$tmp/out"/*.yaml; do
    case "${f##*/}" in
      kustomization.yaml) ;;
      *) echo "  - ${f##*/}" ;;
    esac
  done
} > "$tmp/out/kustomization.yaml"

count=$(ls "$tmp/out"/*.yaml | grep -vc '/kustomization.yaml$')

case "${1:-}" in
  --check)
    if diff -r "$tmp/out" rendered >/dev/null; then
      echo "rendered/ is true to recipe/ and the renovate repository at $RENOVATE_COMMIT ($count objects)"
    else
      echo "rendered/ differs from what recipe/ renders; run render.sh and commit" >&2
      diff -rq "$tmp/out" rendered >&2 || true
      exit 1
    fi
    ;;
  "")
    rm -rf rendered
    mkdir rendered
    cp "$tmp/out"/*.yaml rendered/
    echo "rendered $count objects into rendered/, the renovate repository at $RENOVATE_COMMIT, image $image"
    ;;
  *)
    echo "usage: render.sh [--check]" >&2
    exit 1
    ;;
esac
