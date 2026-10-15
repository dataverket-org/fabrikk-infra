#!/bin/sh
# Builds the Postgres image Zulip's CNPG cluster runs: the CNPG image plus one layer with the three files Zulip's
# full-text search reads from tsearch_data, en_us.dict, en_us.affix and zulip_english.stop. Every input is pinned by
# sha256 below; the layer is root-owned 0644 with mtime 0, so the same inputs give the same digest on every machine.
#
#   postgres-image.sh            build, and write the reference into postgres.yaml when it exists; commit the result
#   postgres-image.sh --check    build, and fail if postgres.yaml names another digest
#   postgres-image.sh --push     --check, then copy the image into zot; push.sh runs this with $user and $password set
#
# en_us.dict and en_us.affix are Debian trixie's hunspell-en-us en_US.dic and en_US.aff as they are: Debian's
# pg_updatedicts only re-encodes them to UTF-8, and both are UTF-8 already (SET UTF-8). The build runs in crane's
# in-memory registry and needs no credential. Needs crane, curl and bsdtar on PATH. Not part of the artifact.
set -eu
unset CDPATH
cd "$(dirname "$0")"

for tool in crane curl bsdtar; do
  command -v "$tool" >/dev/null || { echo "$tool not on PATH" >&2; exit 1; }
done

repo=registry.dataverket.org/platform/postgresql-zulip
# CNPG reads the Postgres version from the tag and refuses a reference by digest alone.
tag=18.4-system-trixie
# ghcr.io/cloudnative-pg/postgresql:18.4-system-trixie, its linux/amd64 manifest; the major is in tsearch below.
base=ghcr.io/cloudnative-pg/postgresql@sha256:e6e1f467b52112f7e08aa380de81473106ff54b1834d90bcb4265a2a018e1921
tsearch=usr/share/postgresql/18/tsearch_data
deb_url=https://deb.debian.org/debian/pool/main/s/scowl/hunspell-en-us_2020.12.07-4_all.deb
deb_sha=962d774fd74f94ea8e781291319706fc5172d7d02c806e4c3a0c6af3ec9ccdc7
stop_url=https://raw.githubusercontent.com/zulip/zulip/12.3/puppet/zulip/files/postgresql/zulip_english.stop
stop_sha=1770a60919243d444df54a3b28817191a8d226c893610835c2e6ca085dbe6c0b

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

#
# Downloads a URL to a path and fails unless its sha256 is the pinned one.
#
fetch() {
  curl -fsSL -o "$2" "$1"
  sum=$(shasum -a 256 "$2" | cut -d' ' -f1)
  [ "$sum" = "$3" ] || { echo "$1: sha256 $sum, pinned $3" >&2; exit 1; }
}

fetch "$deb_url" "$tmp/hunspell-en-us.deb" "$deb_sha"
fetch "$stop_url" "$tmp/zulip_english.stop" "$stop_sha"
bsdtar -xOf "$tmp/hunspell-en-us.deb" 'data.tar.xz' | bsdtar -xf - -C "$tmp" \
  ./usr/share/hunspell/en_US.dic ./usr/share/hunspell/en_US.aff

# An mtree spec fixes owner, mode and mtime per entry, so the tar does not carry this machine's.
cat > "$tmp/spec.mtree" <<MTREE
#mtree
./$tsearch/en_us.dict type=file uid=0 gid=0 uname=root gname=root mode=0644 time=0 contents=$tmp/usr/share/hunspell/en_US.dic
./$tsearch/en_us.affix type=file uid=0 gid=0 uname=root gname=root mode=0644 time=0 contents=$tmp/usr/share/hunspell/en_US.aff
./$tsearch/zulip_english.stop type=file uid=0 gid=0 uname=root gname=root mode=0644 time=0 contents=$tmp/zulip_english.stop
MTREE
bsdtar --format=pax -cf "$tmp/layer.tar" "@$tmp/spec.mtree"

crane registry serve --address 127.0.0.1:0 > "$tmp/registry.log" 2>&1 &
reg_pid=$!
port=
for _ in 1 2 3 4 5 6 7 8 9 10; do
  port=$(sed -n 's/.*serving on port \([0-9]*\).*/\1/p' "$tmp/registry.log")
  [ -z "$port" ] || break
  sleep 0.2
done
[ -n "$port" ] || { echo "crane's local registry did not start" >&2; cat "$tmp/registry.log" >&2; exit 1; }
local_repo=127.0.0.1:$port/postgresql-zulip

built=$(crane append -b "$base" -f "$tmp/layer.tar" -t "$local_repo:build" 2>/dev/null)
digest=${built#*@}
ref=$repo:$tag@$digest

committed=
[ -f postgres.yaml ] && committed=$(sed -n "s#^ *imageName: \($repo:$tag@sha256:[0-9a-f]*\)\$#\1#p" postgres.yaml)

case "${1:-}" in
  "")
    if [ ! -f postgres.yaml ]; then
      echo "built $ref; no postgres.yaml yet to write it into"
    elif [ "$committed" = "$ref" ]; then
      echo "postgres.yaml already names $ref"
    else
      sed -i.bak "s#^\( *imageName: \)$repo:$tag@sha256:[0-9a-f]*\$#\1$ref#" postgres.yaml
      rm -f postgres.yaml.bak
      grep -q "imageName: $ref\$" postgres.yaml || { echo "no imageName for $repo in postgres.yaml" >&2; exit 1; }
      echo "postgres.yaml now names $ref; commit it"
    fi
    ;;
  --check|--push)
    if [ "$committed" != "$ref" ]; then
      echo "the image builds to $digest, postgres.yaml names ${committed:-nothing}; run postgres-image.sh and commit" >&2
      exit 1
    fi
    echo "the image is true to postgres.yaml ($digest)"
    if [ "$1" = --push ]; then
      : "${user:?push.sh sets user}" "${password:?push.sh sets password}"
      # crane reads credentials only from a Docker config; this one lives in $tmp and goes with it.
      DOCKER_CONFIG=$tmp/docker
      export DOCKER_CONFIG
      printf '%s' "$password" | crane auth login registry.dataverket.org -u "$user" --password-stdin >/dev/null
      crane copy "$local_repo@$digest" "$repo:$(git rev-parse HEAD)"
      crane tag "$repo@$digest" "$tag"
      echo "pushed $ref"
    fi
    ;;
  *)
    echo "usage: postgres-image.sh [--check | --push]" >&2
    exit 1
    ;;
esac
