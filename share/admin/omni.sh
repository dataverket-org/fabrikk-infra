# shellcheck shell=bash
#
# Omni: omnictl as you, your login key, service accounts, and the Reader key
# file.
#

#
# Prints the URL the named omniconfig context reaches; nothing when the file or
# the context is absent. This is where our Omni answers, read from your own
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
			error "Create it once with: omnictl config new --url <our Omni>"
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
# few hours, which is the lifetime of tier 1.
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
# Runs omnictl with a service account key file. With a service account key set,
# omnictl ignores the omniconfig and takes its address from OMNI_ENDPOINT.
#
function omni_as_service_account()
{
	local file="$1"
	shift

	[[ -s "$file" ]] || return 1

	OMNI_ENDPOINT="$omni_url" \
	OMNI_SERVICE_ACCOUNT_KEY="$(cat "$file")" \
	run omnictl "$@"
}

#
# Prints the service account listing, a table whose NAME is the bare name and
# whose last column is the RFC 3339 expiration; fails when Omni cannot be
# asked, so that a failed listing is never read as "no accounts".
#
# It answers "which accounts have a live key", not "which accounts exist". An
# account whose keys have all expired drops out of it while its Identity stays
# (seen 2026-09-29: swamp-fabrikk-infra-reader, the name in use then, created
# 2026-09-28 with an 8h key, absent here, present in `omnictl get identities`,
# and refused as AlreadyExists on create). Only create_reader_account concludes anything about
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
# Writes the key out of omnictl's create output to a key file. It prints
# OMNI_ENDPOINT= and OMNI_SERVICE_ACCOUNT_KEY=<key> once, on stdout, and
# everything else on stderr.
#
function write_key_file()
{
	local output="$1"
	local file="$2"
	local key

	key="$(printf '%s\n' "$output" | sed -n 's/^OMNI_SERVICE_ACCOUNT_KEY=//p')"

	if [[ -z "$key" ]]; then
		error "Could not find the key in omnictl's output"
		return 1
	fi

	mkdir -p "${file%/*}" || return $?
	printf '%s' "$key" >"$file.tmp" || return $?
	mv "$file.tmp" "$file" || return $?
	log "Wrote $file"
}

#
# Creates the Reader service account and writes its key file. Omni refuses a
# name it already holds even when `serviceaccount list` does not show it, which
# is what an account with only expired keys looks like, so the refusal is taken
# as "recreate it" rather than as a failure. `retried` stops that at one
# destroy, so a name Omni keeps refusing fails loudly instead of looping.
#
function create_service_account()
{
	local name="$1"
	local role="$2"
	local file="$3"
	local retried="${4:-0}"
	local output

	if output="$(omni serviceaccount create "$name" \
	             --use-user-role=false --role "$role" --ttl "$tier2_ttl" 2>&1)"
	then
		write_key_file "$output" "$file" || return $?
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
			create_service_account "$name" "$role" "$file" 1 || return $?
			;;
		*)
			error "$output"
			return 1
			;;
	esac
}

#
# Renews a service account by destroying and recreating it, and writes its new
# key file. Not `omnictl serviceaccount renew`: that ignores
# --ttl and registers a one-year key (seen 2026-09-28), and Omni cannot drop
# a single key, so a destroy is the only way to keep one short-lived key.
# If the create fails after the destroy, the account is gone and the key file
# is dead; the next run takes the create path and converges.
#
function renew_service_account()
{
	local name="$1"
	local role="$2"
	local file="$3"

	omni serviceaccount destroy "$name" >/dev/null || return $?
	create_service_account "$name" "$role" "$file" 1 || return $?
}

#
# Destroys the accounts this repository made for a role under names it used
# before, once the one it uses now answers. Only exact former names are
# destroyed, never a pattern: an Omni account list is one list for every
# operator, and a pattern would reach another operator's account. An account
# whose keys have all expired is not listed, so it is left to Omni.
#
function destroy_superseded_service_accounts()
{
	local keep="$1"
	local name

	# The word the account ends in, "reader" or "operator", which is what the
	# former names ended in too. Not the Omni role, which is capitalised and
	# appears in no name.
	local word="${keep##*-}"
	local stale="${reader_key_file%/*}/swamp-$id-$word.key"

	for name in "swamp-$id-$word" "swamp-$id-$operator-$word"; do
		[[ "$name" != "$keep" ]]       || continue
		service_account_listed "$name" || continue

		omni serviceaccount destroy "$name" >/dev/null || return $?
		log "Destroyed the superseded account $name"
	done

	# The key file those accounts were written to, which no definition names
	# any more. It authenticates nothing once the account is gone, and tier 2
	# leaves nothing on disk that nothing selects.
	if [[ -f "$stale" ]]; then
		rm -f "$stale" || return $?
		log "Removed the superseded key file $stale"
	fi
}

#
# Brings a service account and its key file to current: created when Omni does
# not list it, renewed when it is due or when the key file no longer
# authenticates, left alone otherwise. Safe to call at any time.
#
function ensure_service_account()
{
	local name="$1"
	local role="$2"
	local file="$3"

	local left reason

	log "Omni service account $name, role $role, $tier2_ttl ..."

	if ! service_account_listed "$name"; then
		log "Creating $name ..."
		create_service_account "$name" "$role" "$file" || return $?
	else
		left="$(service_account_seconds_left "$name")"

		if reason="$(renew_now "$left")"; then
			log "$name $reason; renewing ..."
			renew_service_account "$name" "$role" "$file" || return $?
		elif ! service_account_works "$file"; then
			log "$file is missing or does not authenticate; renewing ..."
			renew_service_account "$name" "$role" "$file" || return $?
		else
			log "$name has $(humanize "$left") left and its key file answers"
		fi
	fi

	service_account_works "$file" || return $?
	destroy_superseded_service_accounts "$name"
}

#
# Checks that a service account key file authenticates.
#
function service_account_works()
{
	local file="$1"

	omni_as_service_account "$file" get clusters >/dev/null 2>&1
}
