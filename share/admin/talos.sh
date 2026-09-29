# shellcheck shell=bash
#
# Talos: the Omni-proxied talosconfig as a named context.
#

#
# Fetches the cluster's talosconfig from Omni into a file and names its one
# context after the cluster, whatever Omni called it.
#
function fetch_talosconfig()
{
	local dest="$1"
	local old_name

	omni talosconfig --cluster "$cluster" --merge=false --force "$dest" \
		>/dev/null || return $?

	old_name="$(yq -r .context "$dest")" || return $?
	[[ "$old_name" == "$cluster" ]] && return

	NEW="$cluster" OLD="$old_name" yq -i '
		.contexts[strenv(NEW)] = .contexts[strenv(OLD)] |
		del(.contexts[strenv(OLD)]) |
		.context = strenv(NEW)' "$dest" || return $?
}

#
# Prints the talos context of ours as one line of JSON, from the talosconfig
# or from a fetched file; "null" when absent.
#
function talos_context_json()
{
	local file="$1"

	[[ -f "$file" ]] || { echo -n null; return; }
	NAME="$cluster" yq -o=json -I=0 '.contexts[strenv(NAME)] // null' "$file" \
		2>/dev/null || echo -n null
}

#
# Checks whether the talos context is ours: absent, or Omni-proxied (its
# endpoint is Omni) and without a client certificate. A context with a
# certificate and key is a raw or break-glass talosconfig, made by hand.
#
function talos_context_is_ours()
{
	local existing

	existing="$(talos_context_json "$talosconfig")"
	[[ "$existing" == "null" ]] && return

	printf '%s' "$existing" | jq -e --arg url "$omni_url" '
		(.crt // .key // "") == "" and
		((.endpoints // []) | any(. == $url))' >/dev/null 2>&1
}

#
# Writes one context from a talosconfig file into the talosconfig in place,
# unless it is already identical. Not `talosctl config merge`: that renames
# a duplicate to <name>-1 and switches the current context to it. The current
# context is left alone. Prints "unchanged" or "written".
#
function write_talos_context()
{
	local src="$1"

	if [[ "$(talos_context_json "$src")" == \
	      "$(talos_context_json "$talosconfig")" ]]; then
		echo -n unchanged
		return
	fi

	mkdir -p "${talosconfig%/*}" || return $?

	if [[ ! -f "$talosconfig" ]]; then
		printf 'context: %s\ncontexts: {}\n' "$cluster" >"$talosconfig" ||
			return $?
	fi

	SRC="$src" NEW="$cluster" yq -i '
		.contexts[strenv(NEW)] = load(strenv(SRC)).contexts[strenv(NEW)] |
		.context = (.context // strenv(NEW))' "$talosconfig" || return $?
	chmod 600 "$talosconfig" || return $?
	echo -n written
}

#
# Checks that the talos context exists.
#
function talos_context_present()
{
	talosctl config contexts 2>/dev/null |
		awk -v c="$cluster" '$1 == c || $2 == c { f = 1 } END { exit !f }'
}

#
# Prints the address of one node in the cluster, from Omni; nothing if none.
# Omni reports addresses with their prefix length (10.0.0.103/24); talosctl
# wants the bare address.
#
function first_node()
{
	omni get machinestatus -l "omni.sidero.dev/cluster=$cluster" -o json \
		2>/dev/null |
	jq -rs '(.[0].spec.network.addresses[0] // empty) | split("/")[0]'
}

#
# Asks one node for its version through Omni's proxy with the Reader key.
#
function verify_talos_context()
{
	local node="$1"

	[[ -s "$reader_key_file" ]] || return 1

	OMNI_ENDPOINT="$omni_url" \
	OMNI_SERVICE_ACCOUNT_KEY="$(cat "$reader_key_file")" \
	run talosctl --context "$cluster" -n "$node" version --short >/dev/null
}
