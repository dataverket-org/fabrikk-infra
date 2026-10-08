#!/bin/sh
# Renders recipe/ into rendered/: one file per object, named by kind and name, plus a kustomization.yaml that lists
# them. Run it after changing the recipe and commit the result; the diff of rendered/ is the review. `--check`
# renders to a temporary directory and compares, which is what push.sh runs first, so what ships is what is in git.
#
# Needs kubectl (kustomize) and helm on PATH; helm only inflates the charts, it never touches a cluster. The charts
# are pulled into recipe/charts/, which is ignored by git.
set -eu
cd "$(dirname "$0")"

for tool in kubectl helm; do
  command -v "$tool" >/dev/null || { echo "$tool not on PATH" >&2; exit 1; }
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

kubectl kustomize --enable-helm recipe -o "$tmp"

# A rendered Secret would be a value in git in clear, and a Job is a Helm hook that cannot be re-run once applied.
if grep -l '^kind: Secret$' "$tmp"/*.yaml; then
  echo "the recipe renders a Secret; secrets travel encrypted next to rendered/, never through it" >&2
  exit 1
fi
if grep -l '^kind: Job$' "$tmp"/*.yaml; then
  echo "the recipe renders a Job; disable the hook or carry it as a plain manifest on purpose" >&2
  exit 1
fi

# Every namespaced object must say its namespace: there is no namespace transformer, on purpose, because one object
# of this recipe lives in kube-system and a transformer would move it (2026-10-06).
missing=0
for f in "$tmp"/*.yaml; do
  kind=$(grep -m1 '^kind:' "$f" | cut -d' ' -f2)
  case "$kind" in
    CustomResourceDefinition|ClusterRole|ClusterRoleBinding|ClusterIssuer|Namespace|APIService| \
    MutatingWebhookConfiguration|ValidatingWebhookConfiguration|PriorityClass|StorageClass) ;;
    *)
      grep -q '^  namespace:' "$f" || { echo "no namespace: ${f##*/}" >&2; missing=1; }
      ;;
  esac
done
[ "$missing" -eq 0 ] || exit 1

{
  echo "# Written by render.sh; do not edit. One file per object, in the order kustomize emitted them."
  echo "apiVersion: kustomize.config.k8s.io/v1beta1"
  echo "kind: Kustomization"
  echo "resources:"
  for f in "$tmp"/*.yaml; do
    case "${f##*/}" in
      kustomization.yaml) ;;
      *) echo "  - ${f##*/}" ;;
    esac
  done
} > "$tmp/kustomization.yaml"

count=$(ls "$tmp"/*.yaml | grep -vc '/kustomization.yaml$')

case "${1:-}" in
  --check)
    if diff -r "$tmp" rendered >/dev/null; then
      echo "rendered/ is true to recipe/ ($count objects)"
    else
      echo "rendered/ differs from what recipe/ renders; run render.sh and commit" >&2
      diff -r "$tmp" rendered >&2 || true
      exit 1
    fi
    ;;
  "")
    rm -rf rendered
    mkdir rendered
    cp "$tmp"/*.yaml rendered/
    echo "rendered $count objects into rendered/"
    ;;
  *)
    echo "usage: render.sh [--check]" >&2
    exit 1
    ;;
esac
