#!/bin/sh
# Pushes this directory, as it is, as the versitygw artifact, into zot. Flux pulls it (apps/versitygw/source.yaml).
# After a rebuild zot comes back empty (docs/storage.md, "Rebuild from git"): run this again from the checkout, and
# Flux applies it; there is no from-git fallback, since nothing here is needed to bring zot back.
#
# Push credentials are the fabrikk-ci user, decrypted from artifacts/zot/zot-ci-credentials.enc.yaml with your YubiKey (one touch).
# Run from a clean checkout of the commit you want to ship; the artifact's revision annotation names that commit.
set -eu
cd "$(dirname "$0")"

for tool in flux sops git; do
  command -v "$tool" >/dev/null || { echo "$tool not on PATH (fabrikk pins flux under _tools/bin: PATH=\$HOME/kode/fabrikk/_tools/bin:\$PATH)" >&2; exit 1; }
done

repo=oci://registry.dataverket.org/platform/versitygw-config
rev=$(git rev-parse HEAD)
source=$(git remote get-url origin | sed 's#^ssh://git@#https://#')

if ! git diff --quiet HEAD -- . || [ -n "$(git ls-files --others --exclude-standard .)" ]; then
  echo "artifacts/versitygw has uncommitted changes; commit first so the revision annotation is true" >&2
  exit 1
fi

user=$(sops -d --extract '["stringData"]["username"]' ../zot/zot-ci-credentials.enc.yaml)
password=$(sops -d --extract '["stringData"]["password"]' ../zot/zot-ci-credentials.enc.yaml)

flux push artifact "$repo:$rev" \
  --creds "$user:$password" \
  --path . \
  --source "$source" \
  --revision "main@sha1:$rev" \
  --reproducible \
  --ignore-paths push.sh,README.md
flux tag artifact "$repo:$rev" --creds "$user:$password" --tag current
