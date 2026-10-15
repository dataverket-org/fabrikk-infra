#!/bin/sh
# Renders the theme into rendered/: one file per ConfigMap, plus a kustomization.yaml that lists them. Run it after
# moving the pin in recipe/source.env or the forgejo chart in apps/forgejo/repo.yaml, and commit the result; the diff
# of rendered/ is the review. `--check` renders to a temporary directory and compares, which is what push.sh runs
# first, so what ships is what is in git, and a chart upgrade that would leave the locale behind fails it.
#
# The theme is the repository and commit recipe/source.env names; its public/assets are taken as committed. The
# locale is the en-US file Forgejo embeds, which is options/locale/locale_en-US.ini in Forgejo's source at the tag of
# the chart's appVersion, byte for byte (README.md), patched by the theme's own locale_from(). No Forgejo binary runs.
#
# Needs git, curl, helm, yq, python3 and kubectl (kustomize) on PATH; helm only reads the chart's metadata.
set -eu
cd "$(dirname "$0")"

for tool in git curl helm yq python3 kubectl; do
  command -v "$tool" >/dev/null || { echo "$tool not on PATH" >&2; exit 1; }
done

. recipe/source.env

chart=$(yq '.spec.url' ../../apps/forgejo/repo.yaml)
chart_version=$(yq '.spec.ref.tag' ../../apps/forgejo/repo.yaml)
forgejo=$(helm show chart "$chart" --version "$chart_version" 2>/dev/null | yq '.appVersion')
[ -n "$forgejo" ] && [ "$forgejo" != null ] || { echo "no appVersion for $chart $chart_version" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

git clone --quiet --no-checkout "$THEME_REPO" "$tmp/theme"
git -C "$tmp/theme" -c advice.detachedHead=false checkout --quiet "$THEME_COMMIT"

curl -fsSL -o "$tmp/locale_en-US.ini" \
  "https://codeberg.org/forgejo/forgejo/raw/tag/v$forgejo/options/locale/locale_en-US.ini"
python3 -I - "$tmp/theme/make-theme.py" "$tmp/locale_en-US.ini" <<'PY' >/dev/null
import importlib.util, sys
spec = importlib.util.spec_from_file_location('make_theme', sys.argv[1])
theme = importlib.util.module_from_spec(spec)
spec.loader.exec_module(theme)
theme.locale_from(sys.argv[2])
PY

cp recipe/kustomization.yaml "$tmp/theme/kustomization.yaml"
mkdir "$tmp/out"
kubectl kustomize "$tmp/theme" -o "$tmp/out"

if grep -L '^kind: ConfigMap$' "$tmp/out"/*.yaml | grep .; then
  echo "the recipe renders something other than a ConfigMap" >&2
  exit 1
fi
for f in "$tmp/out"/*.yaml; do
  grep -q '^  namespace: forgejo$' "$f" || { echo "not in namespace forgejo: ${f##*/}" >&2; exit 1; }
done

{
  echo "# Written by render.sh; do not edit. The theme at $THEME_COMMIT, the locale of Forgejo $forgejo."
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
      echo "rendered/ is true to recipe/ and Forgejo $forgejo ($count ConfigMaps)"
    else
      echo "rendered/ differs from what recipe/ renders for Forgejo $forgejo; run render.sh and commit" >&2
      diff -rq "$tmp/out" rendered >&2 || true
      exit 1
    fi
    ;;
  "")
    rm -rf rendered
    mkdir rendered
    cp "$tmp/out"/*.yaml rendered/
    echo "rendered $count ConfigMaps into rendered/, the theme at $THEME_COMMIT, the locale of Forgejo $forgejo"
    ;;
  *)
    echo "usage: render.sh [--check]" >&2
    exit 1
    ;;
esac
