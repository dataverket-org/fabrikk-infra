#!/bin/sh
# Mints an account and its buckets on the osl1 gateway and prints the writer's Secret on stdout, for sops --encrypt;
# never onto disk in clear. The hov1 counterpart is backup/versitygw/bin/user.
#   usage: artifacts/versitygw/user.sh <account> <namespace> <bucket>... [--rotate]
# Role "user" sees only the buckets it owns; an existing bucket is handed over. --rotate deletes the account first,
# and the writer fails until the new Secret is applied. Without --rotate an existing account is an error.
# Needs kubectl and the admin context. Not part of the artifact.
set -eu
context=${KUBE_CONTEXT:-dataverket-prod-admin}
region=us-east-1

rotate=
for arg do
  [ "$arg" = --rotate ] && rotate=1
done
[ $# -ge 3 ] || { echo "usage: user.sh <account> <namespace> <bucket>... [--rotate]" >&2; exit 2; }
account=$1; namespace=$2; shift 2

#
# Runs versitygw's admin CLI in the gateway's pod, signed with the root key pair from the pod's environment.
#
admin() {
  kubectl --context "$context" -n versitygw exec versitygw-0 -c versitygw -- sh -c \
    'exec versitygw admin -a "$ROOT_ACCESS_KEY" -s "$ROOT_SECRET_KEY" -r "$0" -er http://localhost:7071 "$@"' \
    "$region" "$@"
}

# The new secret goes in on stdin, never as an argument on this host.
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
