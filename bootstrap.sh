#!/bin/sh

flux bootstrap gitea \
  --hostname="https://codeberg.org" \
  --owner="dataverket" \
  --repository="flux-bootstrap" \
  --branch main \
  --path=./clusters/production \
  --personal
