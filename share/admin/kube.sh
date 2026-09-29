# shellcheck shell=bash
#
# Kubernetes: Omni service-account kubeconfigs as named contexts.
#

#
# Prints the user a kube context points at; nothing when it is absent.
#
function context_user()
{
	local name="$1"

	kubectl config view \
		-o jsonpath="{.contexts[?(@.name==\"$name\")].context.user}" \
		2>/dev/null
}

#
# Prints the decoded JWT payload behind a kube context; nothing when the
# context is missing or its user has no token.
#
function context_token_payload()
{
	local name="$1"
	local user token payload

	user="$(context_user "$name")"
	[[ -n "$user" ]] || return

	token="$(kubectl config view --raw \
	         -o jsonpath="{.users[?(@.name==\"$user\")].user.token}")"
	[[ -n "$token" ]] || return

	payload="$(echo -n "$token" | cut -d. -f2 | tr '_-' '/+')"

	case $(( ${#payload} % 4 )) in
		2) payload="$payload==" ;;
		3) payload="$payload=" ;;
	esac

	echo -n "$payload" | base64_decode
}

#
# Prints the seconds until the token behind a kube context expires; 0 when
# the context is missing or carries no JWT.
#
function context_seconds_left()
{
	local name="$1"
	local expiration

	expiration="$(context_token_payload "$name" | jq -r '.exp // 0' \
	              2>/dev/null)"

	if [[ -z "$expiration" || "$expiration" == 0 ]]; then
		echo -n 0
	else
		echo -n $(( expiration - now ))
	fi
}

#
# Prints the subject of the token behind a kube context; nothing if none.
#
function context_subject()
{
	local name="$1"

	context_token_payload "$name" | jq -r '.sub // empty' 2>/dev/null
}

#
# Checks whether a kube context is ours: absent, or carrying a token whose
# subject is the given one. A context that exists with any other user, a
# different subject, an OIDC user, a client certificate, was made by hand.
#
function context_is_ours()
{
	local name="$1"
	local subject="$2"

	[[ -z "$(context_user "$name")" ]] && return
	[[ "$(context_subject "$name")" == "$subject" ]]
}

#
# Mints an Omni service-account kubeconfig into the kubeconfig as a named
# context for a subject, with the shared lifetime. A hand-made context is
# left alone. Ours is renewed when renew_now says so. omnictl switches the
# current context to what it wrote, so the operator's choice is put back.
# Remaining arguments go to omnictl.
#
function mint_kube_context()
{
	local name="$1"
	local subject="$2"
	shift 2

	local left reason current

	if ! context_is_ours "$name" "$subject"; then
		warn "Context $name is not ours ($(context_user "$name")); left alone"
		warn "To let this script manage it, delete the context and rerun"
		return
	fi

	left="$(context_seconds_left "$name")"

	if ! reason="$(renew_now "$left")"; then
		log "Context $name has $(humanize "$left") left; keeping it"
		return
	fi

	current="$(kubectl config current-context 2>/dev/null)"

	log "Context $name $reason; minting ..."
	omni kubeconfig --cluster "$cluster" --service-account --ttl "$tier2_ttl" \
	     --user "$subject" --force-context-name "$name" --force "$@" \
	     >/dev/null || return $?
	chmod 600 "$kubeconfig" || return $?

	# Only if it still exists: the context that was current may be the one that
	# was just deleted, which is what a rename of the subject looks like.
	if [[ -n "$current" && "$current" != "$name" ]] &&
	   kubectl config get-contexts -o name 2>/dev/null | grep -qx "$current"
	then
		kubectl config use-context "$current" >/dev/null || return $?
	fi

	run kubectl --context "$name" get --raw=/version >/dev/null || return $?
	log "Wrote $kubeconfig: context $name for $subject, $tier2_ttl; it answers"
}
