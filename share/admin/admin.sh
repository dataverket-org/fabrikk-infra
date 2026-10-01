# shellcheck shell=bash
#
# Shared by bin/*: names, the one lifetime, and the helpers every action uses.
# Sourced, never run.
#
# Tier 1 (docs/plans/2026-09-credential-tiers.md) runs as the operator with
# the operator's own identities, the Omni browser login, the OpenStack login
# and the Zitadel browser login, and writes only tier 2 files: kube and talos
# contexts, an Omni Reader key file, a clouds.yaml cloud, a Zitadel reader key
# file. It never reads or writes the swamp vault and
# does not need swamp on PATH; what swamp keeps in tier 3 is put there by hand.
#
# Every tier 2 item has the same lifetime, a working day, and `task admin:renew`
# renews all of them in one session as soon as one is due, so the operator logs
# in once at the start of the day instead of once per item.
#
# The two logins behind tier 1, Omni and OpenStack, are web credentials kept
# in Proton Pass. Omni's is used in the browser, where the extension fills it.
# OpenStack's reaches the scripts as OS_PASSWORD, typed once per run, or
# resolved by `pass-cli run` from a pass:// reference for that one run (see
# Taskfile.yml). Never a personal access token: that would let tier 1 run
# unattended, which is the one thing it must not do.
#
# Everything is an environment variable, because the entry points are task
# names and not command lines. They fall in two groups, and the difference is
# what the group below the values explains.
#
# What this repository administers, set in taskfiles/admin.yml and required
# unless a default is named below.
# Every one of them is a name, never an address: the two logins are named the
# way `kubectl` names a context, and each CLI's own config file says where that
# name points. Nothing here holds a URL.
#
#	SWAMP_REPO	This repository's name, which every provider name is built from
#	CLUSTER		The cluster
#	OMNI_CONTEXT	The context in your omniconfig that reaches our Omni
#	OS_CLOUD	The clouds.yaml entry you log in to our cloud with
#	ZITADEL_CONTEXT	The context in your Zitadel config that reaches our Zitadel
#	ZITADEL_PROJECTS	The Zitadel projects the operator key owns, space separated
#	ZITADEL_ORG	The name of the organization the operators are in
#	ZITADEL_NAMESPACE	The namespace Zitadel runs in, for the bootstrap
#	SWAMP_CLOUD	The clouds.yaml entry we write (default the repo name)
#
# Settings for one run, yours to set:
#
#	RENEW		1 renews every item of ours now, not only when due
#	DEBUG		1 prints every external command before it runs
#	TIER2_TTL	The one lifetime, whole hours (default 8h)
#	OPERATOR	You, in the names providers record (default $USER)
#	OS_ROLES	Roles for a new application credential, space separated
#	OS_PASSWORD	Your OpenStack password, else asked for once per run
#	OS_PASSWORD_REF	pass:// reference to it, resolved per run
#

admin_dir="${BASH_SOURCE[0]%/*}"
repo_dir="$(cd "$admin_dir/../.." && pwd)"

source "$admin_dir/../logging.sh"

enable_debug="${DEBUG:-0}"

#
# Stops unless every named variable is set. What this repository administers
# comes from the environment and never from a default here, because a default
# would be a guess at somebody else's cluster or endpoint.
#
function require_settings()
{
	local name

	for name in "$@"; do
		if [[ -z "${!name}" ]]; then
			fail "$name is not set: run through task, which sets it in" \
			     "taskfiles/admin.yml, or set it yourself"
		fi
	done
}

# What this repository administers: its name in a provider, its cluster, and
# the two names its logins go by. taskfiles/admin.yml sets these, because the
# Taskfile is the driver and this is the whole of what a second repository
# would change while reusing bin/ and share/admin/ unchanged. None of the four
# required here is defaulted, so there is no guess at somebody else's cluster
# or endpoint to go wrong.
#
# Both logins are named, not addressed. `omnictl --context <name>` and
# `openstack --os-cloud <name>` each read the address, and the identity behind
# it, out of the operator's own config file, exactly as `kubectl --context`
# does. Where these services actually answer is therefore stated once in the
# README, for a person setting their own config up, and never passed to a CLI
# by these scripts.
require_settings SWAMP_REPO CLUSTER OMNI_CONTEXT OS_CLOUD ZITADEL_CONTEXT

repo="$SWAMP_REPO"
id="$repo"                          # what a definition names: shared, in git

# Who is running this. A provider-side name carries it, so that two operators
# never share an account and a provider's own log can tell them apart. What a
# definition names does not, because a definition is committed and shared: the
# key file keeps one path for everyone and is already per-person by living in
# $HOME, and the kube and cloud entries keep one name each.
operator="${OPERATOR:-$USER}"
[[ -n "$operator" ]] || fail "neither OPERATOR nor USER is set; name yourself"
me="$id-$operator"                  # what a provider records: one per operator

# The names this repository went by in a provider before, newest first. Every
# provider-side name is built from one of these, so a credential under a former
# name is recognised as ours, replaced, and what it left behind removed, rather
# than reported as hand-made and left for good. This list is the whole of what
# a rename leaves behind: kube, Omni and OpenStack all read it, and none of
# them writes the rule down a second time. Delete a line once no host carries a
# credential under it.
#
#	swamp-fabrikk-infra	until 2026-09-29, when tier 2 stopped saying swamp
former_ids=("swamp-$repo")

# shellcheck disable=SC2153  # from the environment, not a misspelt local
cluster="$CLUSTER"
# shellcheck disable=SC2153
omni_context="$OMNI_CONTEXT"
# shellcheck disable=SC2153
human_cloud="$OS_CLOUD"             # the entry you log in with, as you
# shellcheck disable=SC2153
zitadel_context="$ZITADEL_CONTEXT"
zitadel_projects="${ZITADEL_PROJECTS:-}"
zitadel_org="${ZITADEL_ORG:-}"
zitadel_namespace="${ZITADEL_NAMESPACE:-}"

# The application the tasks log in through, in the first of the projects, and
# the machine user the chart makes at install, whose Secret carries its name.
zitadel_login_app="cli"
zitadel_install_user="iam-admin"
os_cloud="${SWAMP_CLOUD:-$repo}"    # the cloud the openstack models name

# Read from the named omniconfig context by require_omni_context, for the calls
# that authenticate with a service account key: those ignore the omniconfig and
# take the address from OMNI_ENDPOINT instead.
omni_url=""
os_role="${OS_ROLE:-member}"
readers_group="fabrikk-readers"

# Where your OpenStack password lives in Proton Pass, as a pass:// reference
# (pass://SHARE_ID/ITEM_ID/password). A reference, not a secret. The openstack
# action hands it to `pass-cli run` for the length of its own run.
os_password_ref="${OS_PASSWORD_REF:-}"

omniconfig="${OMNICONFIG:-$HOME/.talos/omni/config}"
reader_key_file="$HOME/.talos/omni/$id-reader.key"

# The Operator key is tier 2 like the reader key and under the same lifetime,
# but it is minted deliberately, by admin:omni-operator-key and never by
# admin:renew, and removed at logout: an ordinary session holds no key that can
# change a cluster. Only the mutating omni model names this file.
operator_key_file="$HOME/.talos/omni/$id-operator.key"
clouds="$HOME/.config/openstack/clouds.yaml"

# Zitadel has no CLI, so this config is ours to read: a context by name, with
# the address and the client to log in through, and no secret (zitadel.sh).
# Both are read from it by zitadel_context_present. The login's token is kept
# in this process, in zitadel_token, and in no file.
zitadelconfig="${ZITADELCONFIG:-$HOME/.config/zitadel/config.yaml}"
zitadel_url=""
zitadel_client_id=""
zitadel_login_url=""
zitadel_token=""

# The two Zitadel key files, as with Omni: the reader in every session, the
# operator minted deliberately and removed at logout. The zitadel models name
# the first; only a definition that writes names the second.
zitadel_reader_key_file="$HOME/.config/zitadel/$id-reader.json"
zitadel_operator_key_file="$HOME/.config/zitadel/$id-operator.json"

# The one kubeconfig and the one talosconfig, for us and for the CLIs alike:
# omnictl writes to KUBECONFIG when set, kubectl reads every path in it, and
# talosctl honours TALOSCONFIG, so all three must mean the same single file.
kubeconfig="${KUBECONFIG:-$HOME/.kube/config}"
talosconfig="${TALOSCONFIG:-$HOME/.talos/config}"

case "$kubeconfig:$talosconfig" in
	*:*:*)
		fail "KUBECONFIG and TALOSCONFIG must each name one file, not a list"
		;;
esac

export KUBECONFIG="$kubeconfig" TALOSCONFIG="$talosconfig"

tier2_ttl="${TIER2_TTL:-8h}"        # one lifetime for every item, whole hours

if [[ ! "$tier2_ttl" =~ ^[1-9][0-9]*h$ ]]; then
	fail "TIER2_TTL must be whole hours with an h, like 8h; got '$tier2_ttl'"
fi

ttl_hours=${tier2_ttl%h}
ttl_seconds=$(( ttl_hours * 3600 ))
renew_before=$(( ttl_seconds / 4 )) # due when less than a quarter is left
clock_slack=300                     # servers and this host disagree a little

now="$(date +%s)"

# RENEW=1 is what `task admin:renew` sets once it has found an item due, so
# that the whole session is renewed together.
case "${RENEW:-0}" in
	1|true|yes)	force_renew=1 ;;
	*)		force_renew=0 ;;
esac

umask 077

# A service account key in the environment would silently replace your own
# identity in omnictl; tier 1 runs as you.
unset OMNI_SERVICE_ACCOUNT_KEY

source "$admin_dir/omni.sh"
source "$admin_dir/kube.sh"
source "$admin_dir/talos.sh"
source "$admin_dir/openstack.sh"
source "$admin_dir/zitadel.sh"

#
# Prints the files an action reads and the files it may write, before it
# starts, so a reviewer knows what is at stake from the first two lines.
#
function announce_files()
{
	local reads="$1"
	local writes="$2"

	log "Reads:  $reads"
	log "Writes: ${writes:-nothing}"
}

#
# Checks that every named tool is on PATH.
#
function require_tools()
{
	local tool

	for tool in "$@"; do
		if ! command -v "$tool" >/dev/null; then
			error "$tool is not on PATH"
			error "brew bundle installs it, from the Brewfile in this repository"
			return 1
		fi
	done
}

#
# Decides whether an item of ours is renewed now, from the seconds it has
# left: yes when RENEW is set, when it is due, or when it would outlive the
# lifetime by more than clock slack (made by hand or under an older rule).
# Prints the reason.
#
function renew_now()
{
	local left="$1"

	if (( force_renew )); then
		echo -n "renewing with the rest"
	elif (( left <= renew_before )); then
		echo -n "has $(humanize "$left") left; due"
	elif (( left > ttl_seconds + clock_slack )); then
		echo -n "outlives the $tier2_ttl lifetime"
	else
		return 1
	fi
}

#
# Re-executes the calling script under `pass-cli run` so that OS_PASSWORD is
# resolved from Proton Pass for that one run, when a reference is configured,
# no password is in the environment yet, Proton Pass has a session, and this
# is not already the re-executed copy.
#
function with_proton_pass()
{
	[[ -z "$OS_PASSWORD" && -n "$os_password_ref" ]] || return 0
	[[ -z "$ADMIN_PASS_RUN" ]] || return 0
	command -v pass-cli >/dev/null || return 0
	pass-cli info >/dev/null 2>&1 || return 0

	log "OS_PASSWORD comes from Proton Pass for this run only"
	ADMIN_PASS_RUN=1 OS_PASSWORD="$os_password_ref" exec pass-cli run -- "$0"
}

#
# Prints the epoch seconds of an RFC 3339 or ISO 8601 timestamp, on GNU and
# BSD date alike. Fractional seconds and a trailing Z are dropped first.
#
function epoch_of()
{
	local timestamp="$1"

	timestamp="${timestamp%%.*}"
	timestamp="${timestamp%Z}"

	date -u -d "$timestamp" +%s 2>/dev/null ||
	date -j -u -f "%Y-%m-%dT%H:%M:%S" "$timestamp" +%s 2>/dev/null
}

#
# Prints an ISO 8601 timestamp a number of hours from now, in UTC.
#
function hours_from_now()
{
	local hours="$1"

	date -u -d "+$hours hours" +%Y-%m-%dT%H:%M:%S 2>/dev/null ||
	date -u -v+"$hours"H +%Y-%m-%dT%H:%M:%S 2>/dev/null
}

#
# Decodes base64 from stdin, on GNU and BSD base64 alike. The input is read
# once so the second attempt sees it too.
#
function base64_decode()
{
	local data

	data="$(cat)"
	printf '%s' "$data" | base64 -d 2>/dev/null ||
	printf '%s' "$data" | base64 -D 2>/dev/null
}

#
# Prints a number of seconds as whole hours or days, for log lines.
#
function humanize()
{
	local seconds="$1"

	if (( seconds >= 2 * 86400 )); then
		echo -n "$(( seconds / 86400 )) d"
	else
		echo -n "$(( seconds / 3600 )) h"
	fi
}
