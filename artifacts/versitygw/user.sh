#!/bin/sh
# Mint one account and its buckets on the osl1 gateway and print, on stdout, the Kubernetes Secret the writer reads:
# pipe it through sops, never onto disk in clear. backup/versitygw/bin/user does the same on a compose site.
#   usage: artifacts/versitygw/user.sh <account> <namespace> <bucket>... [--rotate]
# The account gets the role "user", which sees only buckets it owns, and each bucket is created owned by it (or handed
# over when it already exists). --rotate deletes an existing account first and mints a new key pair: the writer fails
# from that moment until the new Secret is applied, so commit and push at once. Without --rotate an existing account
# is an error. Not part of the artifact.
#
# versitygw's own admin CLI does the work, inside the gateway's pod through `kubectl exec`: the root key pair is read
# from the environment the gateway was started with and never leaves the pod, the new account's secret arrives on
# stdin, and nothing secret is ever an argument. Needs kubectl and the admin context.
set -eu
context=${KUBE_CONTEXT:-dataverket-prod-admin}
region=us-east-1

rotate=
for arg do
  [ "$arg" = --rotate ] && rotate=1
done
[ $# -ge 3 ] || { echo "usage: user.sh <account> <namespace> <bucket>... [--rotate]" >&2; exit 2; }
account=$1; namespace=$2; shift 2

admin() {
  kubectl --context "$context" -n versitygw exec versitygw-0 -c versitygw -- sh -c \
    'exec versitygw admin -a "$ROOT_ACCESS_KEY" -s "$ROOT_SECRET_KEY" -r "$0" -er http://localhost:7071 "$@"' \
    "$region" "$@"
}

secret=$(head -c 30 /dev/urandom | base64 | tr -d '/+=' | head -c 40)
if [ -n "$rotate" ]; then admin delete-user -a "$account" >&2; fi
printf '%s\n' "$secret" | kubectl --context "$context" -n versitygw exec -i versitygw-0 -c versitygw -- sh -c \
  'read -r s; exec versitygw admin -a "$ROOT_ACCESS_KEY" -s "$ROOT_SECRET_KEY" -r "$0" -er http://localhost:7071 create-user -a "$1" -s "$s" -r user' \
  "$region" "$account" >&2

existing=$(admin list-buckets 2>/dev/null | awk 'NR>2 {print $1}')
for bucket do
  [ "$bucket" = --rotate ] && continue
  if printf '%s\n' "$existing" | grep -qx "$bucket"; then
    admin change-bucket-owner -b "$bucket" -o "$account" >&2
  else
    admin create-bucket --bucket "$bucket" -o "$account" >&2
  fi
done

cat <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: s3-$account
  namespace: $namespace
type: Opaque
stringData:
  ACCESS_KEY_ID: $account
  SECRET_ACCESS_KEY: $secret
YAML
echo "account $account minted on osl1; the secret key is in the manifest above, and in clear only in the gateway's IAM store" >&2
