# Makes the organization match organization.json: creates it when the database holds none, then sets its name,
# description, icon, logos, who may read without an account, and which channels are web-public. Run by the Job in
# organization-job.yaml, in a pod of Zulip's own image, through manage.py shell, so every change goes through Zulip's
# actions and lands in the organization's audit log under the owner. Running it again changes nothing but the icon
# and logo version numbers, which Zulip bumps on every upload.
#
# Refuses to create when the database already holds an organization this file does not name, so a wrong file on an
# empty database fails instead of making a second organization; and refuses an existing organization whose owner
# the file names is not an active owner, so a wrong email fails instead of making a stray account.
#
# organization.json:
#   subdomain        "" for the root domain
#   name, description
#   owner            email and name; created with the organization, checked afterwards. Logs in through Zitadel
#   spectatorAccess  true: readers without an account may read the web-public channels
#   publicChannels   "web-public": every public channel is made web-public; "unchanged": only the ones listed
#   channels         [{name, description, webPublic}], each made to exist with that flag

import json
import sys

from django.conf import settings

from zerver.actions.create_realm import do_create_realm
from zerver.actions.create_user import do_create_user
from zerver.actions.realm_icon import do_change_icon_source
from zerver.actions.realm_logo import do_change_logo_source
from zerver.actions.realm_settings import do_set_realm_property
from zerver.actions.streams import do_change_stream_permission
from zerver.lib.streams import ensure_stream
from zerver.lib.upload import upload_icon_image, upload_logo_image
from zerver.models import Realm, Stream, UserProfile

ORGANIZATION = "/organization/organization.json"
BRAND = "/brand"


def say(*words):
    print("organization:", *words, flush=True)


def fail(*words):
    print("organization: error:", *words, file=sys.stderr, flush=True)
    sys.exit(1)


def find_realm(subdomain):
    """The organization the file names, or None; fails on a database that holds other organizations."""
    realm = Realm.objects.filter(string_id=subdomain, deactivated=False).first()
    others = (
        Realm.objects.filter(deactivated=False)
        .exclude(string_id=subdomain)
        .exclude(string_id=settings.SYSTEM_BOT_REALM)
    )
    if realm is None and others.exists():
        fail(
            "the database holds organizations this file does not name:",
            ", ".join(repr(r.string_id) for r in others),
        )
    return realm


def create(desired):
    """Creates the organization and its owner."""
    realm = do_create_realm(
        string_id=desired["subdomain"],
        name=desired["name"],
        description=desired["description"],
        enable_spectator_access=desired["spectatorAccess"],
    )
    owner = do_create_user(
        desired["owner"]["email"],
        None,
        realm,
        desired["owner"]["name"],
        role=UserProfile.ROLE_REALM_OWNER,
        realm_creation=True,
        acting_user=None,
    )
    say("created", repr(realm.string_id), "with owner", owner.delivery_email)
    return realm, owner


def find_owner(realm, email):
    """The active owner the file names; fails when there is none, so a wrong email never makes an account."""
    owner = UserProfile.objects.filter(
        realm=realm, delivery_email__iexact=email, is_active=True, role=UserProfile.ROLE_REALM_OWNER
    ).first()
    if owner is None:
        fail("no active owner", email, "in", repr(realm.string_id))
    return owner


def ensure_property(realm, owner, name, value):
    if getattr(realm, name) == value:
        return
    do_set_realm_property(realm, name, value, acting_user=owner)
    say("set", name)


def ensure_brand(realm, owner):
    """Uploads the icon and the two logos; Zulip resizes on upload, so every run uploads."""
    with open(f"{BRAND}/icon.png", "rb") as f:
        upload_icon_image(f, owner, content_type="image/png")
    do_change_icon_source(realm, Realm.ICON_UPLOADED, acting_user=owner)
    for name, night in (("logo.png", False), ("night_logo.png", True)):
        with open(f"{BRAND}/{name}", "rb") as f:
            upload_logo_image(f, owner, night, content_type="image/png")
        do_change_logo_source(realm, Realm.LOGO_UPLOADED, night, acting_user=owner)
    say("uploaded the icon, the logo and the night logo")


def ensure_web_public(stream, owner, web_public):
    if stream.is_web_public == web_public:
        return
    do_change_stream_permission(
        stream,
        invite_only=False,
        history_public_to_subscribers=True,
        is_web_public=web_public,
        acting_user=owner,
    )
    say("made", repr(stream.name), "web-public" if web_public else "public only")


def ensure_channels(realm, owner, desired):
    for channel in desired["channels"]:
        stream = ensure_stream(
            realm, channel["name"], stream_description=channel.get("description", ""), acting_user=owner
        )
        ensure_web_public(stream, owner, channel.get("webPublic", False))
    if desired["publicChannels"] == "web-public":
        for stream in Stream.objects.filter(realm=realm, deactivated=False, invite_only=False).order_by("name"):
            ensure_web_public(stream, owner, True)
    elif desired["publicChannels"] != "unchanged":
        fail("publicChannels must be web-public or unchanged, not", repr(desired["publicChannels"]))


with open(ORGANIZATION) as f:
    desired = json.load(f)

if desired["spectatorAccess"] and not settings.WEB_PUBLIC_STREAMS_ENABLED:
    fail("spectatorAccess is on, but the server has WEB_PUBLIC_STREAMS_ENABLED off (statefulset.yaml)")

realm = find_realm(desired["subdomain"])
if realm is None:
    realm, owner = create(desired)
else:
    owner = find_owner(realm, desired["owner"]["email"])

ensure_property(realm, owner, "name", desired["name"])
ensure_property(realm, owner, "description", desired["description"])
ensure_property(realm, owner, "enable_spectator_access", desired["spectatorAccess"])
ensure_brand(realm, owner)
ensure_channels(realm, owner, desired)
say(
    repr(realm.string_id),
    "is as organization.json says; readers without an account see it:",
    realm.has_web_public_streams(),
)
