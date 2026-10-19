#!/bin/sh
# Brands the Dataverket organization in Zulip and opens it to readers who are not logged in. Run it once after the
# organization exists (README, "Set up the first organization"), and again after a rebuild with no database to
# restore. Running it twice changes nothing but the logos' version numbers.
#
#   organization.sh              apply: the brand, then every public channel opened to readers without an account
#   organization.sh --render DIR render the three images into DIR and stop; nothing touches the cluster
#
# The brand is dataverket/org's design/build at one commit (its README, "The logo"), pinned by sha256 below. The
# organization icon is the glyph, white on the theme's navy, which every square icon slot takes; the logo in the
# top-left corner is the wide mark in navy for the light theme and in white for the dark one. Zulip takes PNG, not
# SVG, so rsvg-convert renders them here. Zulip itself gives no further theming: colours and fonts are the user's
# light or dark theme, and the organization's name, description, icon and logos are what it shows of ours.
#
# Opening is three settings, in order: the server allows web-public channels (statefulset.yaml,
# WEB_PUBLIC_STREAMS_ENABLED, shipped first), the organization allows them (enable_spectator_access), and each
# public channel is made web-public. Private channels are left as they are, and so is who may make web-public
# channels later. The changes go through Zulip's own actions in the pod, as a management command would, so the
# audit log names the acting user: ZULIP_OWNER=<email>, or the organization's first owner.
#
# Needs curl, rsvg-convert and kubectl on PATH, and the admin context (task admin:start). Not part of the artifact.
set -eu
unset CDPATH
cd "$(dirname "$0")"

context=dataverket-prod-admin
namespace=zulip
pod=zulip-0
design=https://git.dataverket.org/dataverket/org/raw/commit/1e0bd858e2112cc7a07f1d2804e3b1e4dfe38957/design/build
wide_light_sha=52a32fbe78894c0a9bdc337d35dc73e6dda89ab8c1055173c2fd355f532f9f28
wide_dark_sha=aba4a41e299d434530f50042de6bac88b06f213c740632f6684d8c434718ca87
glyph_dark_sha=374d66c5ae8d0e053006a78cc2c6159404a78054e0364fb8e9b8614124025f12
# The theme's accent, designsystemet.config.json; the one hex value, since Zulip has no token to point at.
navy='#0a2a5e'
# The organization's description, under its name on the login page. The tagline of dataverket/org's docs/landing.md.
description='Kunnskap, åpen kildekode, suverenitet.'
owner=${ZULIP_OWNER:-}

render_only=
case "${1:-}" in
  --render) render_only=${2:?organization.sh --render DIR} ;;
  '') ;;
  *) echo "organization.sh: unrecognized option $1" >&2; exit 1 ;;
esac

for tool in curl rsvg-convert; do
  command -v "$tool" >/dev/null || { echo "$tool not on PATH (brew install librsvg)" >&2; exit 1; }
done
[ -n "$render_only" ] || command -v kubectl >/dev/null || { echo "kubectl not on PATH" >&2; exit 1; }

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
brand=${render_only:-$tmp/brand}
mkdir -p "$brand"
rsvg-convert -h 200 -o "$brand/logo.png" "$tmp/wide-light.svg"
rsvg-convert -h 200 -o "$brand/night_logo.png" "$tmp/wide-dark.svg"
rsvg-convert -w 512 -h 512 -b "$navy" -o "$brand/icon.png" "$tmp/glyph-dark.svg"
if [ -n "$render_only" ]; then
  echo "rendered logo.png, night_logo.png and icon.png into $render_only"
  exit 0
fi

# What runs in the pod, as the management commands do (README, "Run a management command"). Nothing below reads a
# secret, and the output names only the acting user and the channels.
cat > "$brand/organization.py" <<PY
from django.conf import settings
from zerver.actions.realm_icon import do_change_icon_source
from zerver.actions.realm_logo import do_change_logo_source
from zerver.actions.realm_settings import do_set_realm_property
from zerver.actions.streams import do_change_stream_permission
from zerver.lib.upload import upload_icon_image, upload_logo_image
from zerver.models import Realm, Stream, UserProfile
from zerver.models.realms import get_realm

assert settings.WEB_PUBLIC_STREAMS_ENABLED, "WEB_PUBLIC_STREAMS_ENABLED is off: ship statefulset.yaml first"
realm = get_realm("")
if "$owner":
    owner = UserProfile.objects.get(realm=realm, delivery_email__iexact="$owner", is_active=True)
else:
    owner = realm.get_human_owner_users().order_by("id").first()
assert owner is not None, "the organization has no owner"
print("acting as", owner.delivery_email)

brand = "/tmp/dataverket-brand"
with open(brand + "/icon.png", "rb") as f:
    upload_icon_image(f, owner, content_type="image/png")
do_change_icon_source(realm, Realm.ICON_UPLOADED, acting_user=owner)
for name, night in (("logo.png", False), ("night_logo.png", True)):
    with open(brand + "/" + name, "rb") as f:
        upload_logo_image(f, owner, night, content_type="image/png")
    do_change_logo_source(realm, Realm.LOGO_UPLOADED, night, acting_user=owner)
print("icon, logo and night logo uploaded")

if realm.description != "$description":
    do_set_realm_property(realm, "description", "$description", acting_user=owner)
    print("description set")
if not realm.enable_spectator_access:
    do_set_realm_property(realm, "enable_spectator_access", True, acting_user=owner)
    print("readers without an account allowed")

for stream in Stream.objects.filter(realm=realm, deactivated=False, invite_only=False).order_by("name"):
    if stream.is_web_public:
        print("open already:", stream.name)
        continue
    do_change_stream_permission(
        stream, invite_only=False, history_public_to_subscribers=True, is_web_public=True, acting_user=owner
    )
    print("opened:", stream.name)
print("readers without an account see the organization:", realm.has_web_public_streams())
PY

kube() { kubectl --context "$context" -n "$namespace" "$@"; }
kube cp "$brand" "$pod:/tmp/dataverket-brand" -c zulip
kube exec "$pod" -c zulip -- runuser -u zulip -- /home/zulip/deployments/current/manage.py shell \
  -c "exec(open('/tmp/dataverket-brand/organization.py').read())"
kube exec "$pod" -c zulip -- rm -rf /tmp/dataverket-brand

# From outside: an open organization answers its front page to a visitor with no session, a closed one redirects
# to the login page.
code=$(curl -s -o /dev/null -w '%{http_code}' https://forum.dataverket.org/)
case "$code" in
  200) echo "https://forum.dataverket.org/ answers $code to a visitor with no account" ;;
  *) echo "https://forum.dataverket.org/ answers $code to a visitor with no account; expected 200" >&2; exit 1 ;;
esac
