# shellcheck shell=bash
#
# Zitadel: your own browser login, the machine users this repository's models
# act as, and their key files.
#
# Zitadel has no CLI with a config of its own, so the file that says where our
# Zitadel answers is one these scripts read themselves. It has the shape of an
# omniconfig, a context by name, and holds no secret:
#
#	contexts:
#	  default:
#	    url: <where our Zitadel answers>
#	    client_id: "<the native application these scripts log in through>"
#	    login_url: <the login UI there, such as .../ui/v2/login>
#
# login_url is optional and names the login UI to confirm the code in. Zitadel
# sends a device code to its old login UI whatever the instance otherwise
# uses, and a passkey registered in the new one is refused there (seen
# 2026-10-01, Errors.User.WebAuthN.BeginLoginFailed), so an instance that
# runs the new UI names it here.
#
# The login is the device authorization grant: the script prints an address
# and a code, you confirm in the browser as yourself, and the access token
# that comes back lives in this process and is never written. No refresh
# token is asked for, which would be a login with nobody present.
#

zitadel_scope="openid urn:zitadel:iam:org:project:id:zitadel:aud"

# What each machine user may do. The reader is a member of the instance and
# can read all of it and change nothing. The operator is a member of nothing
# but the projects named in ZITADEL_PROJECTS, which it owns: it can change
# those and no other project, no user and no setting. Not ORG_PROJECT_CREATOR:
# on Zitadel 4.15.3 that role creates a project and then may not touch it
# (seen 2026-10-01), so a project is made by you and handed to the operator.
zitadel_reader_role="IAM_OWNER_VIEWER"
zitadel_reader_members="/admin/v1/members"
zitadel_project_role="PROJECT_OWNER"

#
# Prints one value of the named context in the Zitadel config; nothing when
# the file, the context or the value is absent.
#
function zitadel_context_value()
{
	local key="$1"

	CTX="$zitadel_context" KEY="$key" \
	yq -r '.contexts[strenv(CTX)][strenv(KEY)] // ""' \
		"$zitadelconfig" 2>/dev/null
}

#
# Checks that the Zitadel config has the context we use, and remembers its
# address and the client to log in through. Says nothing, so that status and
# due can ask. Call it at top level: it assigns zitadel_url,
# zitadel_client_id and zitadel_login_url.
#
function zitadel_context_present()
{
	zitadel_url="$(zitadel_context_value url)"
	zitadel_client_id="$(zitadel_context_value client_id)"
	zitadel_login_url="$(zitadel_context_value login_url)"
	zitadel_url="${zitadel_url%/}"
	zitadel_login_url="${zitadel_login_url%/}"

	[[ -n "$zitadel_url" && -n "$zitadel_client_id" ]]
}

#
# Stops unless the Zitadel config has the context we use.
#
function require_zitadel_context()
{
	zitadel_context_present && return

	error "Zitadel context $zitadel_context is not in $zitadelconfig"
	error "Create the file once, with url and client_id under"
	error "contexts.$zitadel_context; both are in this repository's README"
	return 1
}

#
# Calls Zitadel with a bearer token and prints the response body. The token
# reaches curl on stdin, so it is in no argument list and no debug line.
#
function zitadel_request()
{
	local token="$1"
	local method="$2"
	local path="$3"
	local body="$4"

	local args=(-sS --fail-with-body --max-time 30 -X "$method")
	args+=(-H "Accept: application/json")

	if [[ -n "$body" ]]; then
		args+=(-H "Content-Type: application/json" --data "$body")
	fi

	debug "curl $method $zitadel_url$path"
	printf 'header = "Authorization: Bearer %s"\n' "$token" |
		curl "${args[@]}" -K - "$zitadel_url$path"
}

#
# Calls Zitadel as you, with the token your login left in this process, and
# prints the response body. A refusal is reported with Zitadel's own message.
#
function zitadel_api()
{
	local method="$1"
	local path="$2"
	local body="$3"
	local output message

	if ! output="$(zitadel_request "$zitadel_token" "$method" "$path" "$body")"
	then
		message="$(printf '%s' "$output" | jq -r '.message // empty' \
		           2>/dev/null)"
		error "Zitadel refused $method $path: ${message:-$output}"
		return 1
	fi

	printf '%s' "$output"
}

#
# Opens an address in your browser when this host has one; the address is
# printed either way, so a host without a browser still works.
#
function open_browser()
{
	local url="$1"

	if   command -v xdg-open >/dev/null; then xdg-open "$url"
	elif command -v open >/dev/null;     then open "$url"
	fi >/dev/null 2>&1
}

#
# Logs in to Zitadel as you, through the browser, and keeps the access token
# in this process. Does nothing when this run has logged in already. Call it
# at top level, or from a function that is: it assigns zitadel_token.
#
function zitadel_login()
{
	local grant device_code user_code url interval expires deadline
	local response problem

	[[ -z "$zitadel_token" ]] || return 0

	grant="$(run curl -sS --fail-with-body --max-time 30 \
	         "$zitadel_url/oauth/v2/device_authorization" \
	         --data-urlencode "client_id=$zitadel_client_id" \
	         --data-urlencode "scope=$zitadel_scope")" || {
		error "Zitadel did not start a login: $grant"
		return 1
	}

	device_code="$(printf '%s' "$grant" | jq -r '.device_code // empty')"
	user_code="$(printf '%s' "$grant" | jq -r '.user_code // empty')"
	url="$(printf '%s' "$grant" |
	       jq -r '.verification_uri_complete // .verification_uri // empty')"
	interval="$(printf '%s' "$grant" | jq -r '.interval // 5')"
	expires="$(printf '%s' "$grant" | jq -r '.expires_in // 300')"

	if [[ -z "$device_code" || -z "$url" ]]; then
		error "Zitadel's answer to the login request names no code"
		return 1
	fi

	# The login UI the config names, when it names one, with the same code.
	if [[ -n "$zitadel_login_url" ]]; then
		url="$zitadel_login_url/device?user_code=$user_code"
	fi

	log "Zitadel: browser login ..."
	log "Open $url"
	log "and confirm the code $user_code as yourself"
	open_browser "$url"

	deadline=$(( $(date +%s) + expires ))

	while (( $(date +%s) < deadline )); do
		sleep "$interval"

		response="$(printf 'data-urlencode = "device_code=%s"\n' \
		            "$device_code" |
		            curl -sS --max-time 30 -K - "$zitadel_url/oauth/v2/token" \
		            --data-urlencode "client_id=$zitadel_client_id" \
		            --data-urlencode \
		            "grant_type=urn:ietf:params:oauth:grant-type:device_code")"
		zitadel_token="$(printf '%s' "$response" |
		                 jq -r '.access_token // empty' 2>/dev/null)"

		if [[ -n "$zitadel_token" ]]; then
			log "Logged in to Zitadel; the token stays in this process"
			return
		fi

		problem="$(printf '%s' "$response" | jq -r '.error // empty' \
		           2>/dev/null)"

		case "$problem" in
			authorization_pending)	;;
			slow_down)		interval=$(( interval + 5 )) ;;
			*)
				error "Zitadel login failed: ${problem:-$response}"
				return 1
				;;
		esac
	done

	error "Zitadel login was not confirmed in time"
	return 1
}

#
# Revokes the token your login left in this process, so that it ends with the
# run and not with its own lifetime. A failure is a warning: the token is in
# no file and dies with the process either way.
#
function zitadel_logout()
{
	[[ -n "$zitadel_token" ]] || return 0

	printf 'data-urlencode = "token=%s"\n' "$zitadel_token" |
		curl -sS --fail-with-body --max-time 30 -K - \
		"$zitadel_url/oauth/v2/revoke" \
		--data-urlencode "client_id=$zitadel_client_id" >/dev/null 2>&1 ||
		warn "Could not revoke the Zitadel login token; it expires by itself"

	zitadel_token=""
}

#
# Prints the id of the organization you belong to.
#
function zitadel_org_id()
{
	local output

	output="$(zitadel_api GET /management/v1/orgs/me)" || return $?
	printf '%s' "$output" | jq -r '.org.id // empty'
}

#
# Prints the id of the user with this exact username in an organization;
# nothing when there is none.
#
function zitadel_user_id()
{
	local name="$1"
	local org="$2"
	local body output

	body="$(jq -n --arg name "$name" --arg org "$org" '{
		queries: [
			{ userNameQuery: { userName: $name,
			                   method: "TEXT_QUERY_METHOD_EQUALS" } },
			{ organizationIdQuery: { organizationId: $org } }
		]
	}')"
	output="$(zitadel_api POST /v2/users "$body")" || return $?

	printf '%s' "$output" | jq -r --arg name "$name" '
		[.result[]? | select(.username == $name) | (.userId // .id)]
		| first // empty'
}

#
# Creates a machine user in an organization and prints its id.
#
function create_machine_user()
{
	local name="$1"
	local org="$2"
	local description="$3"
	local body output

	body="$(jq -n --arg name "$name" --arg org "$org" \
	        --arg description "$description" '{
		organizationId: $org,
		username: $name,
		machine: { name: $name, description: $description,
		           accessTokenType: "ACCESS_TOKEN_TYPE_BEARER" }
	}')"
	output="$(zitadel_api POST /v2/users/new "$body")" || return $?

	printf '%s' "$output" | jq -r '.id // .userId // empty'
}

#
# Brings a user's membership to exactly one role: added when the user is no
# member, set when it holds anything else, left alone when it already holds
# that role and no other. The members path says of what: the instance or
# your organization.
#
function ensure_member()
{
	local members="$1"
	local user_id="$2"
	local role="$3"
	local body output held

	body="$(jq -n --arg id "$user_id" \
	        '{ queries: [ { userIdQuery: { userId: $id } } ] }')"
	output="$(zitadel_api POST "$members/_search" "$body")" || return $?
	held="$(printf '%s' "$output" | jq -r --arg id "$user_id" '
		[.result[]? | select(.userId == $id) | .roles[]?] | sort | join(" ")')"

	[[ "$held" != "$role" ]] || return 0

	if [[ -z "$held" ]]; then
		body="$(jq -n --arg id "$user_id" --arg role "$role" \
		        '{ userId: $id, roles: [$role] }')"
		zitadel_api POST "$members" "$body" >/dev/null || return $?
		log "Gave it $role"
	else
		body="$(jq -n --arg role "$role" '{ roles: [$role] }')"
		zitadel_api PUT "$members/$user_id" "$body" >/dev/null || return $?
		log "It held $held; set to $role and nothing else"
	fi
}

#
# Adds a key with the shared lifetime to a machine user, writes the key file
# and prints the new key's id. The key goes from Zitadel's answer to the file
# and nowhere else.
#
function create_user_key()
{
	local user_id="$1"
	local file="$2"
	local body output key_id

	body="$(jq -n --arg expires "$(hours_from_now "$ttl_hours")Z" \
	        '{ expirationDate: $expires }')"
	output="$(zitadel_api POST "/v2/users/$user_id/keys" "$body")" || return $?
	key_id="$(printf '%s' "$output" | jq -r '.keyId // empty')"

	if [[ -z "$key_id" ]]; then
		error "Zitadel's answer names no key"
		return 1
	fi

	mkdir -p "${file%/*}" || return $?
	printf '%s' "$output" | jq -r '.keyContent // empty' | base64_decode \
		>"$file.tmp" || return $?

	if [[ ! -s "$file.tmp" ]]; then
		rm -f "$file.tmp"
		error "Zitadel's answer carries no key content"
		return 1
	fi

	mv "$file.tmp" "$file" || return $?
	echo -n "$key_id"
}

#
# Deletes every key of a machine user but the one named, so that the user
# holds one short-lived key and a renewal leaves nothing behind.
#
function delete_other_user_keys()
{
	local user_id="$1"
	local keep="$2"
	local body output key_id

	body="$(jq -n --arg id "$user_id" \
	        '{ filters: [ { userIdFilter: { id: $id } } ] }')"
	output="$(zitadel_api POST /v2/users/keys/search "$body")" || return $?

	for key_id in $(printf '%s' "$output" | jq -r '.result[]?.id // empty'); do
		[[ "$key_id" != "$keep" ]] || continue

		zitadel_api DELETE "/v2/users/$user_id/keys/$key_id" >/dev/null ||
			return $?
		log "Deleted the superseded key $key_id"
	done
}

#
# Prints the seconds until the key in a key file expires, read from the file
# itself; 0 when the file is absent or names no expiry, so that an unreadable
# expiry counts as due rather than as time left.
#
function key_file_seconds_left()
{
	local file="$1"
	local expiration epoch

	expiration="$(jq -r '.expirationDate // empty' "$file" 2>/dev/null)"
	epoch="$(epoch_of "$expiration")"

	if [[ -z "$expiration" || -z "$epoch" ]]; then
		echo -n 0
	else
		echo -n $(( epoch - now ))
	fi
}

#
# Encodes stdin as base64url without padding, for the parts of a JWT.
#
function base64url()
{
	openssl base64 -A | tr '+/' '-_' | tr -d '='
}

#
# Prints an access token for the machine user a key belongs to, given the
# key's JSON, by signing an assertion with it and exchanging that, as the
# models do; nothing when the JSON is no key or Zitadel refuses it. The key
# is handed on through stdin and file descriptors, never an argument.
#
function key_json_token()
{
	local json="$1"
	local key_id user_id header claims signature

	key_id="$(jq -r '.keyId // empty' <<<"$json" 2>/dev/null)"
	user_id="$(jq -r '.userId // empty' <<<"$json" 2>/dev/null)"
	[[ -n "$key_id" && -n "$user_id" ]] || return 1

	header="$(jq -cn --arg kid "$key_id" '{ alg: "RS256", kid: $kid }' |
	          base64url)"
	claims="$(jq -cn --arg sub "$user_id" --arg aud "$zitadel_url" \
	          --argjson now "$now" \
	          '{ iss: $sub, sub: $sub, aud: $aud, iat: $now,
	             exp: ($now + 300) }' | base64url)"
	signature="$(printf '%s.%s' "$header" "$claims" |
	             openssl dgst -sha256 -sign <(jq -r '.key' <<<"$json") -binary \
	             2>/dev/null | base64url)"
	[[ -n "$signature" ]] || return 1

	debug "curl POST $zitadel_url/oauth/v2/token (jwt-bearer)"
	printf 'data-urlencode = "assertion=%s"\n' "$header.$claims.$signature" |
		curl -sS --max-time 30 -K - "$zitadel_url/oauth/v2/token" \
		--data-urlencode "scope=$zitadel_scope" \
		--data-urlencode \
		"grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer" 2>/dev/null |
		jq -r '.access_token // empty' 2>/dev/null
}

#
# Prints an access token for the machine user a key file belongs to; nothing
# when the file is unreadable or Zitadel refuses the key.
#
function key_file_token()
{
	local file="$1"

	[[ -r "$file" ]] || return 1
	key_json_token "$(cat "$file")"
}

#
# Prints the username Zitadel knows a key file's holder by; nothing when the
# key does not authenticate. This is what "the key file answers" means here.
#
function key_file_username()
{
	local file="$1"
	local token

	[[ -s "$file" ]] || return 1
	token="$(key_file_token "$file")"
	[[ -n "$token" ]] || return 1

	zitadel_request "$token" GET /auth/v1/users/me "" 2>/dev/null |
		jq -r '.user.userName // empty' 2>/dev/null
}

#
# Brings a machine user and its key file to current: left alone when the key
# has time left and answers, otherwise the user is created if it is missing,
# given its one role when a members path names where, and given a new key,
# after which its older keys are deleted. Only a renewal logs in, so a current
# key costs no browser, and zitadel_token is set afterwards only when this run
# did log in. A key file that belongs to any other user was made by hand and
# is left alone. Safe to call at any time.
#
function ensure_zitadel_key()
{
	local name="$1"
	local members="$2"
	local role="$3"
	local file="$4"
	local description="$5"

	local left holder reason org user_id file_user key_id

	log "Zitadel machine user $name, ${role:-no role of its own}, $tier2_ttl ..."

	if [[ -s "$file" ]]; then
		left="$(key_file_seconds_left "$file")"
		holder="$(key_file_username "$file")"

		if [[ -n "$holder" && "$holder" != "$name" ]]; then
			warn "$file is a key for $holder, not ours; left alone"
			warn "To let this script manage it, remove the file and rerun"
			return
		fi

		if reason="$(renew_now "$left")"; then
			log "$name $reason; renewing ..."
		elif [[ "$holder" == "$name" ]]; then
			log "$name has $(humanize "$left") left and its key file answers"
			return
		else
			log "$file does not authenticate; renewing ..."
		fi
	else
		log "No key file at $file; minting ..."
	fi

	zitadel_login || return $?

	org="$(zitadel_org_id)" || return $?
	user_id="$(zitadel_user_id "$name" "$org")" || return $?

	if [[ -z "$user_id" ]]; then
		log "Creating $name ..."
		user_id="$(create_machine_user "$name" "$org" "$description")" ||
			return $?
		[[ -n "$user_id" ]] || return 1
	fi

	file_user="$(jq -r '.userId // empty' "$file" 2>/dev/null)"

	if [[ -n "$file_user" && "$file_user" != "$user_id" ]]; then
		warn "$file is a key for user $file_user, not $name; left alone"
		warn "To let this script manage it, remove the file and rerun"
		return
	fi

	if [[ -n "$members" ]]; then
		ensure_member "$members" "$user_id" "$role" || return $?
	fi

	key_id="$(create_user_key "$user_id" "$file")" || return $?
	log "Wrote $file"

	if [[ "$(key_file_username "$file")" != "$name" ]]; then
		error "The new key in $file does not authenticate as $name"
		return 1
	fi

	delete_other_user_keys "$user_id" "$key_id" || return $?
	log "$name answers at $zitadel_url with a key that lives $tier2_ttl"
}

#
# Prints the id of the project with this exact name in your organization;
# nothing when there is none.
#
function zitadel_project_id()
{
	local name="$1"
	local body output

	body="$(jq -n --arg name "$name" '{
		queries: [ { nameQuery: { name: $name,
		                          method: "TEXT_QUERY_METHOD_EQUALS" } } ]
	}')"
	output="$(zitadel_api POST /management/v1/projects/_search "$body")" ||
		return $?

	printf '%s' "$output" | jq -r --arg name "$name" '
		[.result[]? | select(.name == $name) | .id] | first // empty'
}

#
# Makes a machine user the owner of each named project, as you, creating a
# project that does not exist yet. This is the whole of what the operator key
# may change, so the list is in taskfiles/admin.yml and not in a console.
#
function ensure_project_owner()
{
	local user_id="$1"
	shift

	local name project output

	for name in "$@"; do
		project="$(zitadel_project_id "$name")" || return $?

		if [[ -z "$project" ]]; then
			log "Creating project $name ..."
			output="$(zitadel_api POST /management/v1/projects \
			          "$(jq -n --arg name "$name" '{ name: $name }')")" ||
				return $?
			project="$(printf '%s' "$output" | jq -r '.id // empty')"
			[[ -n "$project" ]] || return 1
		fi

		log "Project $name: owner ..."
		ensure_member "/management/v1/projects/$project/members" \
			"$user_id" "$zitadel_project_role" || return $?
	done
}

#
# Prints the key of the machine user the chart made when the instance was
# installed, read from its Secret through the admin kube context. It is the
# one credential that exists before anybody can log in, so it is what a
# bootstrap uses, in memory and once; nothing else here reads it.
#
function zitadel_install_key()
{
	run kubectl --context "$cluster-admin" --namespace "$zitadel_namespace" \
		get secret "$zitadel_install_user" \
		-o jsonpath="{.data.${zitadel_install_user}\\.json}" | base64_decode
}

#
# Brings your organization's name to the one given; left alone when it has
# that name already.
#
function ensure_org_name()
{
	local name="$1"
	local output current

	output="$(zitadel_api GET /management/v1/orgs/me)" || return $?
	current="$(printf '%s' "$output" | jq -r '.org.name // empty')"

	if [[ "$current" == "$name" ]]; then
		log "The organization is named $name"
		return
	fi

	zitadel_api PUT /management/v1/orgs/me \
		"$(jq -n --arg name "$name" '{ name: $name }')" >/dev/null || return $?
	log "Renamed the organization from $current to $name"
}

#
# Prints the id of the project with this name, creating it when it is missing.
#
function ensure_project()
{
	local name="$1"
	local project output

	project="$(zitadel_project_id "$name")" || return $?

	if [[ -z "$project" ]]; then
		output="$(zitadel_api POST /management/v1/projects \
		          "$(jq -n --arg name "$name" '{ name: $name }')")" || return $?
		project="$(printf '%s' "$output" | jq -r '.id // empty')"
	fi

	[[ -n "$project" ]] || return 1
	echo -n "$project"
}

#
# Prints the client id of the application these tasks log in through,
# creating it in the project when it is missing: a native application with
# the device code grant and no secret. One that exists is left as it is; its
# configuration is kept by the app model, not here.
#
function ensure_login_app()
{
	local project="$1"
	local name="$2"
	local body output client_id

	body="$(jq -n --arg name "$name" '{
		queries: [ { nameQuery: { name: $name,
		                          method: "TEXT_QUERY_METHOD_EQUALS" } } ]
	}')"
	output="$(zitadel_api POST \
	          "/management/v1/projects/$project/apps/_search" "$body")" ||
		return $?
	client_id="$(printf '%s' "$output" | jq -r --arg name "$name" '
		[.result[]? | select(.name == $name) | .oidcConfig.clientId]
		| first // empty')"

	if [[ -z "$client_id" ]]; then
		body="$(jq -n --arg name "$name" '{
			name: $name,
			redirectUris: [],
			responseTypes: ["OIDC_RESPONSE_TYPE_CODE"],
			grantTypes: ["OIDC_GRANT_TYPE_DEVICE_CODE"],
			appType: "OIDC_APP_TYPE_NATIVE",
			authMethodType: "OIDC_AUTH_METHOD_TYPE_NONE"
		}')"
		output="$(zitadel_api POST \
		          "/management/v1/projects/$project/apps/oidc" "$body")" ||
			return $?
		client_id="$(printf '%s' "$output" | jq -r '.clientId // empty')"
	fi

	[[ -n "$client_id" ]] || return 1
	echo -n "$client_id"
}

#
# Writes the client id into the context of the Zitadel config, leaving the
# rest of the file as it is.
#
function write_zitadel_client_id()
{
	local client_id="$1"

	CTX="$zitadel_context" ID="$client_id" \
	yq -i '.contexts[strenv(CTX)].client_id = strenv(ID)' "$zitadelconfig"
}
