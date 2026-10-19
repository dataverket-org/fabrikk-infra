#!/bin/sh
# Renders the brand into brand/: the three PNGs the organization Job uploads as the icon and the two logos
# (organization/apply.py), from dataverket/org's design/build at one commit (its README, "The logo"), pinned by sha256
# below. The icon is the glyph, white on the theme's navy, which every square icon slot takes; the logo in the
# top-left corner is the wide mark in navy for the light theme and in white for the dark one. Zulip takes PNG, not
# SVG, so they are rendered here, in the factory, and committed. A new mark is a new commit and three new hashes here,
# then a run of this script.
#
# librsvg's output can differ between versions, so a rerun on another machine may change the bytes without changing
# the picture. Review the diff as a picture, not as bytes.
#
# Needs curl and rsvg-convert on PATH. Not part of the artifact; brand/ is.
set -eu
unset CDPATH
cd "$(dirname "$0")"

design=https://git.dataverket.org/dataverket/org/raw/commit/1e0bd858e2112cc7a07f1d2804e3b1e4dfe38957/design/build
wide_light_sha=52a32fbe78894c0a9bdc337d35dc73e6dda89ab8c1055173c2fd355f532f9f28
wide_dark_sha=aba4a41e299d434530f50042de6bac88b06f213c740632f6684d8c434718ca87
glyph_dark_sha=374d66c5ae8d0e053006a78cc2c6159404a78054e0364fb8e9b8614124025f12
# The theme's accent, designsystemet.config.json; the one hex value, since Zulip has no token to point at.
navy='#0a2a5e'

for tool in curl rsvg-convert; do
  command -v "$tool" >/dev/null || { echo "$tool not on PATH (brew install librsvg)" >&2; exit 1; }
done

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

#
# Downloads a URL to a path and fails unless its sha256 is the pinned one.
#
fetch() {
  curl -fsSL -o "$2" "$1"
  sum=$(shasum -a 256 "$2" | cut -d' ' -f1)
  [ "$sum" = "$3" ] || { echo "$1: sha256 $sum, pinned $3" >&2; exit 1; }
}

fetch "$design/wide-light.svg" "$tmp/wide-light.svg" "$wide_light_sha"
fetch "$design/wide-dark.svg" "$tmp/wide-dark.svg" "$wide_dark_sha"
fetch "$design/glyph-dark.svg" "$tmp/glyph-dark.svg" "$glyph_dark_sha"

# Zulip keeps the logos within 800 x 100 and the icon at 100 x 100 (zerver/lib/thumbnail.py), scaling down only,
# so each is rendered larger than that. The glyph carries its own margins, so the plate needs none.
mkdir -p brand
rsvg-convert -h 200 -o brand/logo.png "$tmp/wide-light.svg"
rsvg-convert -h 200 -o brand/night_logo.png "$tmp/wide-dark.svg"
rsvg-convert -w 512 -h 512 -b "$navy" -o brand/icon.png "$tmp/glyph-dark.svg"
echo "rendered brand/logo.png, brand/night_logo.png and brand/icon.png; review the diff and commit"
