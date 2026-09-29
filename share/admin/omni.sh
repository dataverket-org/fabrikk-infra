# shellcheck shell=bash
#
# Omni: omnictl as you, your login key, service accounts, and the Reader key
# file.
#

#
# Prints the URL the named omniconfig context reaches; nothing when the file or
# the context is absent. This is where the estate answers, read from your own
# config rather than named by this repository, as the cloud's address is read
# from your clouds.yaml entry.
#
function omni_context_url()
{
	CTX="$omni_context" yq -r '.contexts[strenv(CTX)].url // ""' \
		"$omniconfig" 2>/dev/null
}

#
# Stops unless the omniconfig has the context we use, and remembers its URL for
# the service-account calls, which ignore the omniconfig and need the address in
# OMNI_ENDPOINT. Call it at top level: it assigns omni_url.
#
function require_omni_context()
{
	omni_url="$(omni_context_url)"

	case "$omni_url" in
		""|null)
			error "Omni context $omni_context is not in $omniconfig"
			error "Create it once with: omnictl config new --url <this estate's Omni>"
			error "The address is in this repository's README"
			return 1
			;;
	esac
}

#
# Runs omnictl as you, in the named context (browser login on first use).
#
function omni()
{
	run omnictl --omniconfig "$omniconfig" --context "$omni_context" "$@"
}

#
# Prints the path of the PGP key omnictl keeps for your login in the current
# context; the file may not exist yet.
#
function omni_login_key()
{
	local context identity

	context="$omni_context"
	identity="$(CTX="$omni_context" yq -r \
	            '.contexts[strenv(CTX)].auth.siderov1.identity // ""' \
	            "$omniconfig" 2>/dev/null)"
	echo -n "$HOME/.talos/keys/$context-$identity.pgp"
}

#
# Prints the epoch seconds at which your Omni login key expires, read out of
# the PGP key; nothing when gpg or the key is absent. Omni issues these for a
# few hours, which is the lifetime of tier 3.
#
function omni_login_expiry()
{
	local key

	command -v gpg >/dev/null || return
	key="$(omni_login_key)"
	[[ -f "$key" ]] || return

	gpg --show-keys --with-colons "$key" 2>/dev/null |
		awk -F: '$1 == "sec" && $7 != "" { print $7; exit }'
}

#
# Prints when your Omni login key expires, as local time; nothing if unknown.
#
function omni_login_expires()
{
	local epoch

	epoch="$(omni_login_expiry)"
	[[ -n "$epoch" ]] || return

	date -d "@$epoch" +%Y-%m-%dT%H:%M 2>/dev/null ||
	date -r "$epoch" +%Y-%m-%dT%H:%M 2>/dev/null
}

#
# Runs omnictl with the Reader key. With a service account key set, omnictl
# ignores the omniconfig and takes its address from OMNI_ENDPOINT.
#
function omni_as_reader()
{
	[[ -s "$reader_key_file" ]] || return 1

	OMNI_ENDPOINT="$omni_url" \
	OMNI_SERVICE_ACCOUNT_KEY="$(cat "$reader_key_file")" \
	run omnictl "$@"
}

#
# Prints the service account listing, a table whose NAME is the bare name and
# whose last column is the RFC 3339 expiration; fails when Omni cannot be
# asked, so that a failed listing is never read as "no accounts".
#
# It answers "which accounts have a live key", not "which accounts exist". An
# account whose keys have all expired drops out of it while its Identity stays
# (seen 2026-09-29: swamp-fabrikk-infra-reader, created 2026-09-28 with an 8h
# key, absent here, present in `omnictl get identities`, and refused as
# AlreadyExists on create). Only create_reader_account concludes anything about
# existence.
#
function service_accounts()
{
	omni serviceaccount list
}

#
# Prints the listing's lines for one account. The listing's NAME column is the
# bare name; Omni's errors use the qualified form
# (<name>@serviceaccount.omni.sidero.dev), so the match drops any @domain and
# accepts either. The last column is EXPIRATION, which is what the caller below
# reads.
#
function service_account_lines()
{
	local name="$1"
	local listing

	listing="$(service_accounts)" || return $?
	printf '%s\n' "$listing" |
		awk -v n="$name" '{ split($1, a, "@"); if (a[1] == n) print }'
}

#
# Checks whether a service account is listed, expired or not.
#
function service_account_listed()
{
	local name="$1"
	local lines

	lines="$(service_account_lines "$name")" || return $?
	[[ -n "$lines" ]]
}

#
# Prints the seconds until a service account expires; 0 when there is none,
# and 0 when the listing's last column is not a timestamp, so that an
# unreadable expiry counts as due rather than as time left.
# An account with several keys counts by the one that lives longest.
#
function service_account_seconds_left()
{
	local name="$1"
	local lines expiration epoch

	lines="$(service_account_lines "$name")" || { echo -n 0; return 1; }
	expiration="$(printf '%s\n' "$lines" | awk 'NF { print $NF }' |
	              sort | tail -1)"
	epoch="$(epoch_of "$expiration")"

	if [[ -z "$expiration" || -z "$epoch" ]]; then
		echo -n 0
	else
		echo -n $(( epoch - now ))
	fi
}

#
# Writes the key out of omnictl's create output to the key file. It prints
# OMNI_ENDPOINT= and OMNI_SERVICE_ACCOUNT_KEY=<key> once, on stdout, and
# everything else on stderr.
#
function write_reader_key()
{
	local output="$1"
	local key

	key="$(printf '%s\n' "$output" | sed -n 's/^OMNI_SERVICE_ACCOUNT_KEY=//p')"

	if [[ -z "$key" ]]; then
		error "Could not find the key in omnictl's output"
		return 1
	fi

	mkdir -p "${reader_key_file%/*}" || return $?
	printf '%s' "$key" >"$reader_key_file.tmp" || return $?
	mv "$reader_key_file.tmp" "$reader_key_file" || return $?
	log "Wrote $reader_key_file"
}

#
# Creates the Reader service account and writes its key file. Omni refuses a
# name it already holds even when `serviceaccount list` does not show it, which
# is what an account with only expired keys looks like, so the refusal is taken
# as "recreate it" rather than as a failure. `retried` stops that at one
# destroy, so a name Omni keeps refusing fails loudly instead of looping.
#
function create_reader_account()
{
	local name="$1"
	local retried="${2:-0}"
	local output

	if output="$(omni serviceaccount create "$name" \
	             --use-user-role=false --role Reader --ttl "$tier2_ttl" 2>&1)"
	then
		write_reader_key "$output" || return $?
		return
	fi

	case "$output" in
		*AlreadyExists*|*"already exists"*)
			if (( retried )); then
				error "$output"
				return 1
			fi
			warn "$name exists in Omni but the listing does not show it"
			warn "Destroying and recreating it under the same name ..."
			omni serviceaccount destroy "$name" >/dev/null || return $?
			create_reader_account "$name" 1 || return $?
			;;
		*)
			error "$output"
			return 1
			;;
	esac
}

#
# Renews the Reader service account by destroying and recreating it, and
# writes its new key file. Not `omnictl serviceaccount renew`: that ignores
# --ttl and registers a one-year key (seen 2026-09-28), and Omni cannot drop
# a single key, so a destroy is the only way to keep one short-lived key.
# If the create fails after the destroy, the account is gone and the key file
# is dead; the next run takes the create path and converges.
#
function renew_reader_account()
{
	local name="$1"

	omni serviceaccount destroy "$name" >/dev/null || return $?
	create_reader_account "$name" 1 || return $?
}

#
# Checks that the Reader key file authenticates.
#
function reader_key_works()
{
	omni_as_reader get clusters >/dev/null 2>&1
}
