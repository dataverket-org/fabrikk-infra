#!/bin/sh
# Puts the avatar policy on Zulip's osl1 buckets and runs the S3 proofs of docs/plans/2026-10-zulip.md, decision B,
# with awscli and curl. Run as the `zulip` account, the secret in the environment, never an argument:
#
#   AWS_ACCESS_KEY_ID=zulip \
#   AWS_SECRET_ACCESS_KEY="$(sops -d --extract '["stringData"]["SECRET_ACCESS_KEY"]' artifacts/zulip/s3-zulip.enc.yaml)" \
#   artifacts/zulip/s3.sh policy|prove [--big]
#
# `prove` writes only under proof/ and deletes it; --big adds one 2 GiB PUT in a single request, the S3 plan's step 4.
# awscli's botocore is not the boto3 1.43.74 Zulip pins; the checks are the plan's, the client is not Zulip's.
# Needs aws and curl. Not part of the artifact.
set -eu
endpoint=https://dataverket.s3.osl1.dvkt.no
uploads=zulip-uploads
avatars=zulip-avatars
prefix=proof/

for tool in aws curl; do
  command -v "$tool" >/dev/null || { echo "$tool not on PATH" >&2; exit 1; }
done
[ -n "${AWS_SECRET_ACCESS_KEY:-}" ] || { echo "AWS_SECRET_ACCESS_KEY is empty" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# Path-style, as Zulip is configured: awscli takes the addressing style only from a config file.
printf '[default]\nregion = us-east-1\ns3 =\n  addressing_style = path\n' > "$tmp/config"
export AWS_CONFIG_FILE="$tmp/config" AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_PAGER=

passed=0
failed=0

#
# Runs awscli against the osl1 endpoint.
#
s3() {
  aws --endpoint-url "$endpoint" "$@"
}

#
# Records one proof as PASS when its condition holds and prints it.
#
check() {
  name=$1; detail=$2; shift 2
  if "$@"; then
    passed=$((passed + 1)); echo "PASS $name: $detail"
  else
    failed=$((failed + 1)); echo "FAIL $name: $detail"
  fi
}

#
# Succeeds when the value matches the shell pattern.
#
matches() {
  # shellcheck disable=SC2254  # $1 is a pattern, matched as a glob on purpose
  case "$2" in $1) ;; *) return 1 ;; esac
}

#
# Prints the HTTP status of an unauthenticated GET, with an optional extra header.
#
status() {
  curl -s -o /dev/null -w '%{http_code}' ${2:+-H "$2"} "$1"
}

#
# Puts the world-readable policy on the avatar bucket and prints it back.
#
policy() {
  # versitygw v1.9.0 combines a policy with the ACL (#2495), so the owner's rights stay in the ACL.
  s3 s3api put-bucket-policy --bucket "$avatars" --policy '{"Version":"2012-10-17","Statement":[{
    "Effect":"Allow","Principal":{"AWS":"*"},"Action":["s3:GetObject"],
    "Resource":["arn:aws:s3:::'"$avatars"'/*"]}]}'
  s3 s3api get-bucket-policy --bucket "$avatars" --query Policy --output text
}

#
# Runs the proofs and deletes what they wrote.
#
prove() {
  big=$1

  # versitygw #2398.
  printf 'zulip proof\n' > "$tmp/plain.txt"
  s3 s3api put-object --bucket "$uploads" --key "${prefix}plain.txt" --body "$tmp/plain.txt" \
    --content-type text/plain >/dev/null
  encoding=$(s3 s3api head-object --bucket "$uploads" --key "${prefix}plain.txt" --query ContentEncoding \
    --output text)
  check "put without aws-chunked" "Content-Encoding=$encoding" [ "$encoding" != aws-chunked ]

  head -c 6291456 /dev/urandom > "$tmp/six.bin"
  s3 s3api put-object --bucket "$uploads" --key "${prefix}six.bin" --body "$tmp/six.bin" >/dev/null
  url=$(s3 s3 presign "s3://$uploads/${prefix}six.bin" --expires-in 300)
  code=$(status "$url")
  check "presigned get" "$code" [ "$code" = 200 ]
  code=$(status "$url" "Range: bytes=0-5242879")
  check "presigned range" "$code" [ "$code" = 206 ]

  printf 'PNG proof' > "$tmp/avatar.png"
  s3 s3api put-object --bucket "$avatars" --key "${prefix}avatar.png" --body "$tmp/avatar.png" \
    --content-type image/png >/dev/null
  code=$(status "$endpoint/$avatars/${prefix}avatar.png")
  check "anonymous get on avatars" "$code" [ "$code" = 200 ]
  code=$(status "$endpoint/$uploads/${prefix}plain.txt")
  check "anonymous get on uploads refused" "$code" [ "$code" = 403 ]
  for bucket in "$uploads" "$avatars"; do
    count=$(s3 s3api list-objects-v2 --bucket "$bucket" --prefix "$prefix" --query KeyCount --output text)
    check "owner lists $bucket" "$count keys" [ "$count" -gt 0 ]
  done

  # Zulip's tusd hook rewrites headers this way (zerver/views/tusd.py).
  s3 s3api copy-object --bucket "$uploads" --key "${prefix}plain.txt" \
    --copy-source "$uploads/${prefix}plain.txt" --metadata-directive REPLACE \
    --content-type text/markdown --content-disposition 'inline; filename="plain.md"' >/dev/null
  headers=$(s3 s3api head-object --bucket "$uploads" --key "${prefix}plain.txt" \
    --query '[ContentType,ContentDisposition]' --output text)
  check "copy onto itself" "$headers" matches 'text/markdown*plain.md*' "$headers"

  # awscli switches to multipart above 8 MiB.
  head -c 20971520 /dev/urandom > "$tmp/twenty.bin"
  s3 s3 cp --only-show-errors "$tmp/twenty.bin" "s3://$uploads/${prefix}twenty.bin"
  etag=$(s3 s3api head-object --bucket "$uploads" --key "${prefix}twenty.bin" --query ETag --output text)
  check "multipart upload" "$etag" matches '*-*' "$etag"

  for n in 0 1 2 3 4; do
    s3 s3api put-object --bucket "$uploads" --key "${prefix}page/$n" --body "$tmp/plain.txt" >/dev/null
  done
  pages=0; token=
  while :; do
    pages=$((pages + 1))
    token=$(s3 s3api list-objects-v2 --bucket "$uploads" --prefix "${prefix}page/" --max-keys 2 \
      --no-paginate ${token:+--continuation-token "$token"} --query NextContinuationToken --output text)
    [ "$token" = None ] && break
  done
  check "list pages" "$pages pages" [ "$pages" = 3 ]

  # The S3 plan's step 4: s3api sends one request through Envoy, which a route request timeout would cut.
  if [ "$big" = --big ]; then
    dd if=/dev/zero of="$tmp/big.bin" bs=1048576 count=2048 2>/dev/null
    s3 s3api put-object --bucket "$uploads" --key "${prefix}big.bin" --body "$tmp/big.bin" >/dev/null
    length=$(s3 s3api head-object --bucket "$uploads" --key "${prefix}big.bin" --query ContentLength --output text)
    check "2 GiB in one PUT" "$length" [ "$length" = 2147483648 ]
    rm -f "$tmp/big.bin"
  fi

  for bucket in "$uploads" "$avatars"; do
    # awscli's text output separates the keys with tabs.
    keys=$(s3 s3api list-objects-v2 --bucket "$bucket" --prefix "$prefix" --query 'Contents[].Key' --output text \
      | tr '\t' '\n')
    [ -n "$keys" ] && [ "$keys" != None ] || continue
    total=$(printf '%s\n' "$keys" | wc -l | tr -d ' ')
    objects=$(printf '%s\n' "$keys" | sed 's/.*/{"Key":"&"}/' | paste -sd, -)
    deleted=$(s3 s3api delete-objects --bucket "$bucket" --delete "{\"Objects\":[$objects]}" \
      --query 'length(Deleted)' --output text)
    check "delete_objects in $bucket" "$deleted of $total" [ "$deleted" = "$total" ]
  done

  echo "$passed of $((passed + failed)) passed"
  [ "$failed" = 0 ]
}

case "${1:-}" in
  policy) policy ;;
  prove)  prove "${2:-}" ;;
  *)      echo "usage: s3.sh policy|prove [--big]" >&2; exit 2 ;;
esac
