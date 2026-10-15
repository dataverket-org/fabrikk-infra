#!/bin/sh
# Builds site/ into an image the www pods mount as a volume (deployment.yaml, volume "site"): one uncompressed-then-
# gzipped layer, every file root-owned 0644 with mtime 0, platform linux/amd64. The same site/ gives the same digest on
# every machine with the same crane, which is what lets git carry the digest before anything is pushed.
#
#   site.sh            build, and write the digest into deployment.yaml; commit the result
#   site.sh --check    build, and fail if deployment.yaml names another digest
#   site.sh --push     --check, then copy the image into zot; push.sh runs this with $user and $password set
#
# The build runs in crane's in-memory registry on a free local port, so it needs no credential and leaves nothing
# behind. Needs crane and bsdtar on PATH; macOS ships bsdtar, Linux has it in libarchive-tools.
set -eu
# A CDPATH in the caller's shell makes the plain "cd site" below fail, and the build then yields an empty image.
unset CDPATH
cd "$(dirname "$0")"

for tool in crane bsdtar; do
  command -v "$tool" >/dev/null || { echo "$tool not on PATH" >&2; exit 1; }
done

repo=registry.dataverket.org/platform/www-site

tmp=$(mktemp -d)
reg_pid=
cleanup() {
  if [ -n "$reg_pid" ]; then
    kill "$reg_pid" 2>/dev/null || true
    wait "$reg_pid" 2>/dev/null || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT

# An mtree spec fixes owner, mode and mtime per entry, so the tar does not carry the checkout's.
{
  echo '#mtree'
  (cd site && find . -type d ! -name . | LC_ALL=C sort) | while read -r d; do
    echo "$d type=dir uid=0 gid=0 uname=root gname=root mode=0755 time=0"
  done
  (cd site && find . -type f | LC_ALL=C sort) | while read -r f; do
    echo "$f type=file uid=0 gid=0 uname=root gname=root mode=0644 time=0 contents=site/${f#./}"
  done
} > "$tmp/spec.mtree"
bsdtar --format=pax -cf "$tmp/site.tar" "@$tmp/spec.mtree"

crane registry serve --address 127.0.0.1:0 > "$tmp/registry.log" 2>&1 &
reg_pid=$!
port=
for _ in 1 2 3 4 5 6 7 8 9 10; do
  port=$(sed -n 's/.*serving on port \([0-9]*\).*/\1/p' "$tmp/registry.log")
  [ -z "$port" ] || break
  sleep 0.2
done
[ -n "$port" ] || { echo "crane's local registry did not start" >&2; cat "$tmp/registry.log" >&2; exit 1; }
local_repo=127.0.0.1:$port/www-site

crane append --oci-empty-base -f "$tmp/site.tar" -t "$local_repo:build" >/dev/null 2>&1
built=$(crane mutate --set-platform linux/amd64 -t "$local_repo:site" "$local_repo:build" 2>/dev/null)
digest=${built#*@}
ref=$repo@$digest

committed=$(sed -n "s#^ *reference: \($repo@sha256:[0-9a-f]*\)\$#\1#p" deployment.yaml)

case "${1:-}" in
  "")
    if [ "$committed" = "$ref" ]; then
      echo "deployment.yaml already names $ref"
    else
      sed -i.bak "s#^\( *reference: \)$repo@sha256:[0-9a-f]*\$#\1$ref#" deployment.yaml
      rm -f deployment.yaml.bak
      grep -q "reference: $ref\$" deployment.yaml || { echo "no site reference in deployment.yaml to update" >&2; exit 1; }
      echo "deployment.yaml now names $ref; commit it"
    fi
    ;;
  --check|--push)
    if [ "$committed" != "$ref" ]; then
      echo "site/ builds to $digest, deployment.yaml names ${committed:-nothing}; run site.sh and commit" >&2
      exit 1
    fi
    echo "site/ is true to deployment.yaml ($digest)"
    if [ "$1" = --push ]; then
      : "${user:?push.sh sets user}" "${password:?push.sh sets password}"
      # crane reads credentials only from a Docker config; this one lives in $tmp and goes with it.
      DOCKER_CONFIG=$tmp/docker
      export DOCKER_CONFIG
      printf '%s' "$password" | crane auth login registry.dataverket.org -u "$user" --password-stdin >/dev/null
      crane copy "$local_repo@$digest" "$repo:$(git rev-parse HEAD)"
      echo "pushed $ref"
    fi
    ;;
  *)
    echo "usage: site.sh [--check | --push]" >&2
    exit 1
    ;;
esac
