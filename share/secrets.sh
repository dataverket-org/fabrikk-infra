# shellcheck shell=bash
#
# The password managers a reference can name, for any script in bin/. Sourced,
# never run; needs logging.sh first. bin/with-secrets is how a task uses it.
#
# A reference says where a value lives and is not itself a secret, so it may
# sit in a taskfile or your environment. By convention the reference for NAME
# is NAME_REF. Its scheme selects the backend that resolves it, with that
# backend's own session:
#
#	pass://VAULT/ITEM/FIELD		Proton Pass, by name or by id, active
#					items only; pass-cli keeps its own
#					session (task admin:start)
#	passstore://PATH		passwordstore.org, the first line of the
#					entry; gpg-agent asks for what it needs
#	sops://FILE#FIELD		A sops file's field (default value),
#					FILE relative to this repository unless
#					absolute or ~/; sops asks for its key
#
# A secret is one value. A sops file of one value keeps it in the field value,
# as vaults/operator/ does (decision 016), and its reference names no field.
# A sops reference may name any file you can decrypt. The plan for access
# requests holds that vaults/operator/ keeps nothing that completes a routine
# login, so a login password belongs in a file of your own, not there.
#
# A resolved value goes to stdout and from there into the environment of one
# run. It never reaches an argument or a log line (operator rule 4). Adding a
# backend is a case in each function below and its CLI in the Brewfile.
#

secrets_repo_dir="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"

#
# Prints the name of the backend a reference selects; fails for none.
#
function secret_backend()
{
	case "$1" in
		pass://*)	echo -n proton ;;
		passstore://*)	echo -n passstore ;;
		sops://*)	echo -n sops ;;
		*)		return 1 ;;
	esac
}

#
# Prints the CLI a backend resolves with.
#
function secret_backend_tool()
{
	case "$1" in
		proton)		echo -n pass-cli ;;
		passstore)	echo -n pass ;;
		sops)		echo -n sops ;;
	esac
}

#
# Prints the passwordstore.org entry file a passstore:// reference names.
#
function passstore_file()
{
	local path="${1#passstore://}"

	echo -n "${PASSWORD_STORE_DIR:-$HOME/.password-store}/$path.gpg"
}

#
# Prints a pass:// reference with its vault and item as ids, for one that may
# name either by title. Only active items count: pass-cli resolves a title
# against the trash as well, and may pick an item deleted long ago. Fails,
# and says why, when no active item or more than one has the title. Reads
# only the listing, which carries no field values.
#
function proton_ref_by_id()
{
	local ref="${1#pass://}"
	local vault="${ref%%/*}"
	local rest="${ref#*/}"
	local item="${rest%%/*}"
	local field=""
	local listing matches

	if [[ "$rest" == "$ref" || -z "$vault" || -z "$item" ]]; then
		warn "A Proton Pass reference is pass://VAULT/ITEM/FIELD: $1"
		return 1
	fi

	[[ "$rest" == */* ]] && field="/${rest#*/}"

	listing="$(pass-cli item list --vault-name "$vault" \
	           --filter-state active --output json 2>/dev/null)" ||
	listing="$(pass-cli item list --share-id "$vault" \
	           --filter-state active --output json 2>/dev/null)" || {
		warn "No vault $vault in Proton Pass, by name or by id"
		return 1
	}

	matches="$(jq -r --arg item "$item" '.items[] |
		select(.id == $item or .title == $item) |
		.share_id + "/" + .id' <<<"$listing")" || return 1

	case "$(grep -c . <<<"$matches")" in
		1)	echo -n "pass://$matches$field" ;;
		0)	warn "No active item $item in vault $vault"
			return 1 ;;
		*)	warn "More than one active item is $item in vault $vault"
			warn "Name it by id: pass-cli item list $vault"
			return 1 ;;
	esac
}

#
# Prints the file a sops:// reference names.
#
function sops_file()
{
	local file="${1#sops://}"

	file="${file%%#*}"

	# A literal ~/ from the reference, not one for the shell to expand.
	# shellcheck disable=SC2088
	case "$file" in
		/*)	;;
		"~/"*)	file="$HOME/${file#"~/"}" ;;
		*)	file="$secrets_repo_dir/$file" ;;
	esac

	echo -n "$file"
}

#
# Prints the field a sops:// reference names as a yq path, like .a.b;
# value when the reference names none.
#
function sops_field()
{
	local field="value"

	[[ "$1" == *#* ]] && field="${1#*#}"
	echo -n ".$field"
}

#
# Checks that a backend has a session to resolve with. A pass store needs
# none of its own: gpg-agent asks for a passphrase or a touch when it decrypts,
# and sops asks its age plugin or gpg-agent the same way.
#
function secret_session_open()
{
	case "$1" in
		proton)		pass-cli info >/dev/null 2>&1 ;;
		passstore)	return 0 ;;
		sops)		return 0 ;;
		*)		return 1 ;;
	esac
}

#
# Prints the secret a reference names. Prints nothing and fails when the
# backend has no session or the entry is not there.
#
function resolve_secret()
{
	local ref="$1"
	local id_ref

	case "$(secret_backend "$ref")" in
		proton)
			id_ref="$(proton_ref_by_id "$ref")" || return 1
			pass-cli item view "$id_ref" 2>/dev/null
			;;
		passstore)
			pass show "${ref#passstore://}" 2>/dev/null | head -n 1
			;;
		sops)
			sops decrypt "$(sops_file "$ref")" 2>/dev/null |
				yq -r -e "$(sops_field "$ref")" 2>/dev/null
			;;
		*)
			return 1
			;;
	esac
}

#
# Checks that a reference names an entry that is there, without printing it
# and, where the backend allows, without decrypting it: Proton Pass finds
# the one active item in its listing, a pass store checks that the file
# exists, and a sops file that the field is there, since sops leaves the keys
# in clear.
#
function secret_present()
{
	local ref="$1"

	case "$(secret_backend "$ref")" in
		proton)
			proton_ref_by_id "$ref" >/dev/null
			;;
		passstore)
			[[ -f "$(passstore_file "$ref")" ]]
			;;
		sops)
			yq -e "$(sops_field "$ref")" "$(sops_file "$ref")" \
				>/dev/null 2>&1
			;;
		*)
			return 1
			;;
	esac
}

#
# Checks a reference without printing what it names, and says why when it is
# no good: no backend for its scheme, that backend's CLI missing or without a
# session, or no such entry. A pass store and a sops file are checked without
# decrypting, so nothing asks for a touch here.
#
function secret_ref_usable()
{
	local ref="$1"
	local backend tool

	if ! backend="$(secret_backend "$ref")"; then
		warn "$ref names no password manager;" \
		     "a reference is pass://, passstore:// or sops://"
		return 1
	fi

	tool="$(secret_backend_tool "$backend")"

	if ! command -v "$tool" >/dev/null; then
		warn "$tool is not on PATH, for $ref"
		return 1
	elif ! secret_session_open "$backend"; then
		warn "$tool has no session, for $ref"
		return 1
	elif ! secret_present "$ref"; then
		# Proton Pass has said why already.
		[[ "$backend" == proton ]] || warn "$ref names nothing in $tool"
		return 1
	fi
}

#
# Fills the variable NAME from the reference in NAME_REF and exports it, when
# NAME is empty and NAME_REF is not. One that is already set wins; one that
# does not resolve is reported and left empty, for the script to ask instead.
# Call it at top level, not inside a command substitution, or the export dies
# with the subshell.
#
function resolve_secret_into()
{
	local name="$1"
	local ref_name ref value

	if [[ ! "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
		error "Not a variable name: $name"
		return 1
	fi

	ref_name="${name}_REF"
	ref="${!ref_name:-}"

	[[ -z "${!name:-}" && -n "$ref" ]] || return 0

	if secret_ref_usable "$ref" &&
	   value="$(resolve_secret "$ref")" && [[ -n "$value" ]]; then
		export "$name=$value"
		log "$name from $ref, for this run"
	else
		warn "$name stays empty; the command asks for it, if it can"
	fi
}
