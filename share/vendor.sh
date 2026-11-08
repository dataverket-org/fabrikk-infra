#
# Upstream manifests kept in the repository (decision 035): the table of what
# is vendored, and the functions that fetch a copy and prove the committed
# one true to its pin.
#
# A row names the directory under the repository root, the file the manifest
# is kept as, the URL it comes from and the SHA-256 the copy must have. The
# hash is the pin: a release that changes under its URL is refused, not
# taken. Bumping a version is a change to this table and to the file.
#

# shellcheck source=share/logging.sh
source "${BASH_SOURCE[0]%/*}/logging.sh" || return $?

repo_dir="${BASH_SOURCE[0]%/*}/.."

# dir|file|url|sha256
vendored=(
	"infrastructure/cnpg-operator|cnpg-1.30.0.yaml|https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.30/releases/cnpg-1.30.0.yaml|f8bede43fe4ee0d478c2355b204a36876b2ae4faac60f2a9452280b293da3b88"
	"infrastructure/cnpg-barman-plugin|plugin-barman-cloud-v0.15.0.yaml|https://github.com/cloudnative-pg/plugin-barman-cloud/releases/download/v0.15.0/manifest.yaml|1c483eae12a7424ad28ac66bdfee771b510ee8e234cb8756c3ade7254cef2fad"
)

#
# Prints the SHA-256 of a file.
#
function sha256_of()
{
	local file="$1"

	shasum -a 256 "$file" | cut -d' ' -f1
}

#
# Downloads a URL into a destination path, refusing an HTML error page that
# a server sends with a success status.
#
function download()
{
	local url="$1"
	local dest="$2"

	run curl -fsSL --retry 3 --retry-delay 5 -o "$dest" "$url" || return $?
	if head -c 64 "$dest" | grep -qi '<html'; then
		error "$url answered an HTML page, not a manifest!"
		return 1
	fi
}

#
# Fetches one vendored manifest into its directory, when the committed copy
# is missing or does not match its pin, and verifies the result.
#
function vendor_fetch()
{
	local dir="$1"
	local file="$2"
	local url="$3"
	local sha256="$4"
	local dest="$repo_dir/$dir/$file"
	local tmp

	if [[ -f "$dest" && "$(sha256_of "$dest")" == "$sha256" ]]; then
		log "$dir/$file is already true to its pin"
		return 0
	fi

	tmp="$(mktemp)" || return $?
	log "Fetching $url ..."
	download "$url" "$tmp" || { rm -f "$tmp"; return 1; }

	if [[ "$(sha256_of "$tmp")" != "$sha256" ]]; then
		error "$url has SHA-256 $(sha256_of "$tmp"), the pin says $sha256!"
		rm -f "$tmp"
		return 1
	fi

	mv "$tmp" "$dest" || return $?
	log "Wrote $dir/$file; commit it"
}

#
# Verifies that one committed manifest matches its pin, without the network.
#
function vendor_check()
{
	local dir="$1"
	local file="$2"
	local sha256="$4"
	local dest="$repo_dir/$dir/$file"

	if [[ ! -f "$dest" ]]; then
		error "$dir/$file is missing; run bin/vendor"
		return 1
	fi
	if [[ "$(sha256_of "$dest")" != "$sha256" ]]; then
		error "$dir/$file does not match its pin; run bin/vendor"
		return 1
	fi
	log "$dir/$file is true to its pin"
}

#
# Runs one function over every row of the table, and fails if any row did.
#
function vendor_each()
{
	local action="$1"
	local row status=0

	for row in "${vendored[@]}"; do
		IFS='|' read -r dir file url sha256 <<<"$row"
		"$action" "$dir" "$file" "$url" "$sha256" || status=1
	done
	return "$status"
}
