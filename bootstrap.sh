#!/bin/sh

# git.dataverket.org is the source of record (codeberg.org is a push mirror). Re-running this with --token-auth
# recreates the flux-system secret with a forge token and restores secretRef in gotk-sync.yaml.
flux bootstrap gitea \
  --hostname="https://git.dataverket.org" \
  --owner="dataverket" \
  --repository="flux-bootstrap" \
  --branch main \
  --path=./clusters/production \
  --personal \
  --token-auth
