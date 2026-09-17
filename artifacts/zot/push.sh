#!/bin/sh
# Pushes this directory, as it is, as zot's own config artifact, into zot. Flux pulls it (apps/zot/source.yaml).
# Before zot exists, or when it cannot serve, bootstrap/zot-from-git.yaml applies the same directory from git.
#
# Push credentials are the fabrikk-ci user, decrypted from zot-ci-credentials.enc.yaml with your YubiKey (one touch).
# Run from a clean checkout of the commit you want to ship; the artifact's revision annotation names that commit.
set -eu
cd "$(dirname "$0")"

for tool in flux sops git; do
  command -v "$tool" >/dev/null || { echo "$tool not on PATH (fabrikk pins flux under _tools/bin: PATH=\$HOME/kode/fabrikk/_tools/bin:\$PATH)" >&2; exit 1; }
done

repo=oci://registry.dataverket.org/platform/zot-config
rev=$(git rev-parse HEAD)
source=$(git remote get-url origin | sed 's#^ssh://git@#https://#')

if ! git diff --quiet HEAD -- . || [ -n "$(git ls-files --others --exclude-standard .)" ]; then
  echo "artifacts/zot has uncommitted changes; commit first so the revision annotation is true" >&2
  exit 1
fi

user=$(sops -d --extract '["stringData"]["username"]' zot-ci-credentials.enc.yaml)
password=$(sops -d --extract '["stringData"]["password"]' zot-ci-credentials.enc.yaml)

flux push artifact "$repo:$rev" \
  --creds "$user:$password" \
  --path . \
  --source "$source" \
  --revision "main@sha1:$rev" \
  --reproducible \
  --ignore-paths push.sh,README.md
flux tag artifact "$repo:$rev" --creds "$user:$password" --tag current
