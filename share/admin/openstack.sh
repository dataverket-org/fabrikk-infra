# shellcheck shell=bash
#
# OpenStack: an application credential as a named cloud in clouds.yaml.
#

#
# Stops unless the entry you log in with is in clouds.yaml and is a person's:
# not the entry this repository writes, and not an application credential,
# which is a machine's. Prints where it reaches, so the address is visible in
# the run even though no script here ever passes one.
#
function require_human_cloud()
{
	local url type

	[[ -f "$clouds" ]] || { error "$clouds does not exist!"; return 1; }

	if [[ "$human_cloud" == "$os_cloud" ]]; then
		error "Cloud entry $human_cloud is the one this repository writes"
		error "Tier 1 logs in as you; set OS_CLOUD to your own entry"
		return 1
	fi

	url="$(yq -r ".clouds.\"$human_cloud\".auth.auth_url // \"\"" "$clouds" \
	       2>/dev/null)"

	case "$url" in
		""|null)
			error "Cloud entry $human_cloud is not in $clouds"
			error "Add your own login there; the address is in the README"
			return 1
			;;
	esac

	type="$(yq -r ".clouds.\"$human_cloud\".auth_type // \"password\"" \
	        "$clouds" 2>/dev/null)"

	if [[ "$type" == "v3applicationcredential" ]]; then
		error "Cloud entry $human_cloud is an application credential"
		error "That is a machine's credential; tier 1 logs in as you"
		return 1
	fi

	debug "Cloud entry $human_cloud reaches $url"
}

#
# Prints the application credential id the cloud entry uses; nothing if none.
#
function current_credential_id()
{
	local credential

	credential="$(yq -r ".clouds.\"$os_cloud\".auth.application_credential_id" \
	              "$clouds" 2>/dev/null)"

	case "$credential" in
		null|"") return ;;
		*)       echo -n "$credential" ;;
	esac
}

#
# Prints the JSON record of an application credential, read by the credential
# itself through the cloud entry; nothing when it cannot, which is the case
# once it has expired. `show -f json` uses title-case keys.
#
function credential_record()
{
	local credential="$1"

	[[ -n "$credential" ]] || return

	openstack --os-cloud "$os_cloud" application credential show \
		"$credential" -f json 2>/dev/null
}

#
# Prints the JSON record of an application credential, read as you through
# your own cloud entry; nothing when Keystone no longer has it. This is how
# an expired credential is still recognised as ours or as hand-made.
#
function credential_record_as_you()
{
	local credential="$1"

	[[ -n "$credential" ]] || return

	human_login
	openstack --os-cloud "$human_cloud" application credential show \
		"$credential" -f json 2>/dev/null
}

#
# Prints the name in a credential record, or the fallback when the record is
# empty or has no name.
#
function credential_name()
{
	local record="$1"
	local fallback="$2"
	local name

	name="$(printf '%s' "$record" | jq -r '.Name // empty' 2>/dev/null)"
	echo -n "${name:-$fallback}"
}

#
# Checks whether a credential name is one this script made, now or before.
#
function credential_is_ours()
{
	local name="$1"

	# Also the prefix these names carried until 2026-09-29, so that a
	# credential made under the old one is replaced and pruned rather than
	# reported as hand-made and left in Keystone for good. Keystone scopes a
	# listing to the operator, so this only ever matches your own.
	[[ "$name" == "$id-"* || "$name" == "swamp-$id-"* ]]
}

#
# Prints the role names in a credential record, space separated.
#
function credential_roles()
{
	local record="$1"

	printf '%s' "$record" | jq -r '[.Roles[].name] | join(" ")' 2>/dev/null
}

#
# Prints the seconds until a credential record expires: 0 when there is no
# record, or when it has no expiry at all (a hand-made one).
#
function credential_seconds_left()
{
	local record="$1"
	local expiration

	expiration="$(printf '%s' "$record" | jq -r '."Expires At" // empty' \
	              2>/dev/null)"

	if [[ -z "$record" || -z "$expiration" ]]; then
		echo -n 0
	else
		echo -n $(( $(epoch_of "$expiration") - now ))
	fi
}

#
# Makes sure the openstack CLI can log in as you without prompting on every
# call: when neither OS_PASSWORD nor the entry carries a password, asks once
# and exports it for the rest of the run. Call it at top level, not inside a
# command substitution, or the export dies with the subshell. A password in
# clouds.yaml is a tier 1 root credential on disk and is pointed out.
#
function human_login()
{
	[[ -n "$OS_PASSWORD" ]] && return

	if yq -e ".clouds.\"$human_cloud\".auth.password" "$clouds" \
	   >/dev/null 2>&1; then
		warn "Entry $human_cloud keeps a password in $clouds; tier 1 should not"
		return
	fi

	[[ -t 0 ]] || return

	read -r -s -p "Password for cloud entry $human_cloud: " OS_PASSWORD
	echo >&2
	export OS_PASSWORD
}

#
# Creates an application credential as you, with the given roles, and prints
# its JSON record. Keystone refuses a duplicate name, so the name carries a
# timestamp.
#
function create_application_credential()
{
	local name="$1"
	shift

	local role_opts=()
	local role expiration

	for role in "$@"; do
		role_opts+=("--role" "$role")
	done

	expiration="$(hours_from_now "$ttl_hours")" || return $?

	run openstack --os-cloud "$human_cloud" application credential create \
	    "$name" "${role_opts[@]}" --expiration "$expiration" \
	    --description "swamp models in $repo, made by bin/openstack" \
	    -f json
}

#
# Writes the cloud entry into clouds.yaml from a credential's JSON record,
# copying auth_url, region and interface from your own cloud entry.
#
function write_cloud()
{
	local record="$1"
	local credential secret

	# `create -f json` uses title-case keys, like `show`.
	credential="$(printf '%s' "$record" | jq -r '.ID // empty')"
	secret="$(printf '%s' "$record" | jq -r '.Secret // empty')"

	if [[ -z "$credential" || -z "$secret" ]]; then
		error "The credential record has no ID or Secret; not writing $clouds"
		return 1
	fi

	AC_ID="$credential" AC_SECRET="$secret" \
	CLOUD="$os_cloud" HUMAN="$human_cloud" \
	yq -i '.clouds[strenv(CLOUD)] = {
		"auth_type": "v3applicationcredential",
		"auth": {
			"auth_url": .clouds[strenv(HUMAN)].auth.auth_url,
			"application_credential_id": strenv(AC_ID),
			"application_credential_secret": strenv(AC_SECRET)},
		"region_name": .clouds[strenv(HUMAN)].region_name,
		"interface": (.clouds[strenv(HUMAN)].interface // "public"),
		"identity_api_version": 3}' "$clouds" || return $?
	chmod 600 "$clouds" || return $?
}

#
# Checks that the cloud entry can issue a token.
#
function verify_cloud()
{
	run openstack --os-cloud "$os_cloud" token issue -f value -c expires \
		>/dev/null
}

#
# Lists your application credentials other than the one to keep, one per line
# as "delete|keep <id> <name>": delete for ours by name, now or before, keep
# for the rest. The listing goes through the cloud entry itself when it
# answers, a credential may list its user's credentials, and as you otherwise.
#
function other_credentials()
{
	local keep="$1"
	local listing pairs credential name

	listing="$(openstack --os-cloud "$os_cloud" application credential list \
	           -f json 2>/dev/null)" ||
	listing="$(openstack --os-cloud "$human_cloud" application credential \
	           list -f json)" || return $?

	pairs="$(printf '%s' "$listing" |
	         jq -r --arg keep "$keep" '
		.[] | select(.Name != $keep) | .ID + " " + .Name')" || return $?

	# jq lists and credential_is_ours decides, so that "ours" has one
	# definition: a name this repository used before is pruned by the same
	# rule that lets it be replaced, and not by a second copy of the prefix.
	while read -r credential name; do
		[[ -n "$credential" ]] || continue

		if credential_is_ours "$name"; then
			echo "delete $credential $name"
		else
			echo "keep $credential $name"
		fi
	done <<<"$pairs"
}

#
# Deletes the application credentials with our name prefix that the kept one
# supersedes, and names any others so a human can decide about them. Only a
# delete needs your login.
#
function prune_application_credentials()
{
	local keep="$1"
	local others verb credential name

	others="$(other_credentials "$keep")" || return $?

	if ! printf '%s\n' "$others" | grep -q '^delete '; then
		log "Nothing of ours to prune"
	else
		human_login   # at top level: prune is never called in a subshell
	fi

	while read -r verb credential name; do
		case "$verb" in
			delete)
				run openstack --os-cloud "$human_cloud" application credential \
				    delete "$credential" </dev/null || return $?
				log "Deleted $name"
				;;
			keep)
				warn "Left alone: $name ($credential), not ours by name"
				;;
		esac
	done <<<"$others"
}
