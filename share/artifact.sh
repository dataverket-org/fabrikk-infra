#
# One config artifact per component (decisions 013, 028; the gitless plan):
# the functions that render an artifact's recipe, prove the committed
# rendering true, and push the directory into zot signed and tagged.
#
# An artifact is artifacts/<name>/, pushed as platform/<name>-config. What is
# in the directory and what each optional file means:
#
#	kustomization.yaml	What Flux applies; without one, every manifest
#				in the directory, as Flux generates it
#	recipe/			Charts and values kustomize inflates with helm
#				into rendered/, which is committed
#	render.sh		A bespoke renderer, used instead of recipe/
#	prepush.sh		Run before the push with $user and $password
#				exported, for an image the artifact names
#	.sourceignore		Paths left out of the artifact, one a line,
#				beside the defaults below
#	*.enc.yaml		Secrets, sops-encrypted to the cluster key;
#				they travel in the artifact and never render
#

# shellcheck source=share/logging.sh
source "${BASH_SOURCE[0]%/*}/logging.sh" || return $?

repo_dir="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)"
registry="registry.dataverket.org"
credential_file="$repo_dir/artifacts/zot/zot-ci-credentials.enc.yaml"
signing_key="$repo_dir/vaults/operator/osl1/cosign.enc.json"
default_ignore="README.md,recipe/,*.sh,.sourceignore"

# Kinds that have no namespace, so a rendered object of one is not refused.
cluster_kinds="CustomResourceDefinition|ClusterRole|ClusterRoleBinding|"
cluster_kinds+="ClusterIssuer|Namespace|APIService|MutatingWebhookConfiguration|"
cluster_kinds+="ValidatingWebhookConfiguration|PriorityClass|StorageClass|"
cluster_kinds+="GatewayClass|RuntimeClass|CSIDriver"

#
# Prints the directory of an artifact, failing when there is none. A
# directory without a kustomization.yaml is applied as Flux generates one,
# every manifest in it.
#
function artifact_dir()
{
	local name="$1"
	local dir="$repo_dir/artifacts/$name"

	if [[ ! -d "$dir" ]]; then
		error "No artifact at artifacts/$name!"
		return 1
	fi
	echo "$dir"
}

#
# Renders a recipe into a directory: one file per object, and a
# kustomization listing them. Refuses a Secret, a Job and an object without a
# namespace, the checks cert-manager's renderer made.
#
function render_recipe()
{
	local dir="$1"
	local out="$2"
	local file kind status=0

	run kubectl kustomize --enable-helm "$dir/recipe" -o "$out" || return $?

	if grep -ql '^kind: Secret$' "$out"/*.yaml; then
		error "The recipe renders a Secret; secrets travel encrypted" \
		      "beside rendered/, never through it!"
		return 1
	fi
	if grep -ql '^kind: Job$' "$out"/*.yaml; then
		error "The recipe renders a Job; a hook does not run twice" \
		      "from a plain manifest. Disable it, or carry it on purpose!"
		return 1
	fi
	for file in "$out"/*.yaml; do
		kind="$(grep -m1 '^kind:' "$file" | cut -d' ' -f2)"
		[[ "$kind" =~ ^($cluster_kinds)$ ]] && continue
		if ! grep -q '^  namespace:' "$file"; then
			error "No namespace: ${file##*/}"
			status=1
		fi
	done
	[[ "$status" -eq 0 ]] || return 1

	{
		echo "# Written by bin/artifact; do not edit. One file per object," \
		     "in the order kustomize emitted them."
		echo "apiVersion: kustomize.config.k8s.io/v1beta1"
		echo "kind: Kustomization"
		echo "resources:"
		for file in "$out"/*.yaml; do
			[[ "${file##*/}" == kustomization.yaml ]] && continue
			echo "  - ${file##*/}"
		done
	} >"$out/kustomization.yaml"
}

#
# Prints how many objects a rendering holds.
#
function rendered_count()
{
	local out="$1"

	find "$out" -name '*.yaml' ! -name kustomization.yaml | wc -l | tr -d ' '
}

#
# Writes rendered/ from the recipe, or runs the bespoke renderer.
#
function artifact_render()
{
	local name="$1"
	local dir tmp

	dir="$(artifact_dir "$name")" || return $?

	if [[ -x "$dir/render.sh" ]]; then
		run "$dir/render.sh" || return $?
		return 0
	fi
	if [[ ! -d "$dir/recipe" ]]; then
		log "artifacts/$name has no recipe; nothing to render"
		return 0
	fi

	tmp="$(mktemp -d)" || return $?
	render_recipe "$dir" "$tmp" || { rm -rf "$tmp"; return 1; }
	rm -rf "$dir/rendered" || return $?
	mv "$tmp" "$dir/rendered" || return $?
	log "Rendered $(rendered_count "$dir/rendered") objects into" \
	    "artifacts/$name/rendered/; commit them"
}

#
# Proves rendered/ true to the recipe, or lets the bespoke renderer do so.
#
function artifact_check()
{
	local name="$1"
	local dir tmp

	dir="$(artifact_dir "$name")" || return $?

	if [[ -x "$dir/render.sh" ]]; then
		run "$dir/render.sh" --check || return $?
		return 0
	fi
	if [[ ! -d "$dir/recipe" ]]; then
		log "artifacts/$name has no recipe; nothing to check"
		return 0
	fi

	tmp="$(mktemp -d)" || return $?
	render_recipe "$dir" "$tmp" || { rm -rf "$tmp"; return 1; }
	if ! diff -r "$tmp" "$dir/rendered" >/dev/null; then
		error "artifacts/$name/rendered/ differs from what recipe/ renders;" \
		      "run bin/artifact $name and commit!"
		diff -r "$tmp" "$dir/rendered" >&2
		rm -rf "$tmp"
		return 1
	fi
	log "artifacts/$name/rendered/ is true to recipe/" \
	    "($(rendered_count "$tmp") objects)"
	rm -rf "$tmp"
}

#
# Fails when the artifact's directory has changes git does not hold, so the
# revision annotation of a push is true.
#
function require_clean()
{
	local dir="$1"

	if ! git -C "$dir" diff --quiet HEAD -- . ||
	   [[ -n "$(git -C "$dir" ls-files --others --exclude-standard .)" ]]; then
		error "artifacts/${dir##*/} has uncommitted changes; commit first" \
		      "so the revision annotation is true!"
		return 1
	fi
}

#
# Reads the push credential into $user and $password: one sops run, one
# YubiKey touch, nothing written anywhere.
#
function read_credential()
{
	local json

	json="$(sops -d --output-type json "$credential_file")" || return $?
	user="$(jq -r '.stringData.username' <<<"$json")" || return $?
	password="$(jq -r '.stringData.password' <<<"$json")" || return $?
	[[ -n "$user" && -n "$password" ]] || {
		error "The credential file has no username and password!"
		return 1
	}
}

#
# Prints the ignore list for a push: the defaults and the directory's
# .sourceignore, as one comma-separated argument.
#
function ignore_paths()
{
	local dir="$1"
	local list="$default_ignore" line

	[[ -f "$dir/.sourceignore" ]] || { echo "$list"; return; }
	while IFS= read -r line; do
		[[ -z "$line" || "$line" == \#* ]] && continue
		list+=",$line"
	done <"$dir/.sourceignore"
	echo "$list"
}

#
# Pushes an artifact's directory into zot at the commit it is at, signs the
# digest when the site's key exists, and moves the current tag to it.
#
function artifact_push()
{
	local name="$1"
	local dir rev source repo pushed digest_url

	dir="$(artifact_dir "$name")" || return $?
	require_clean "$dir" || return $?
	artifact_check "$name" || return $?

	rev="$(git -C "$dir" rev-parse HEAD)" || return $?
	source="$(git -C "$dir" remote get-url origin)" || return $?
	source="${source/#ssh:\/\/git@/https://}"
	repo="oci://$registry/platform/$name-config"

	read_credential || return $?

	if [[ -x "$dir/prepush.sh" ]]; then
		log "Running artifacts/$name/prepush.sh ..."
		(cd "$dir" && user="$user" password="$password" ./prepush.sh) ||
			return $?
	fi

	log "Pushing $repo:$rev ..."
	pushed="$(run flux push artifact "$repo:$rev" \
		--creds "$user:$password" \
		--path "$dir" \
		--source "$source" \
		--revision "main@sha1:$rev" \
		--reproducible \
		--ignore-paths "$(ignore_paths "$dir")" \
		--output json)" || return $?
	digest_url="$(jq -r '.repository + "@" + .digest' <<<"$pushed")" ||
		return $?
	log "Pushed $digest_url"

	sign_digest "$digest_url" || return $?

	run flux tag artifact "$repo:$rev" --creds "$user:$password" \
		--tag current || return $?
	log "Tagged $repo:current"
}

#
# Signs a pushed digest with the site's cosign key when the key exists
# (vaults/operator/README.md, "Signing keys"); one touch, no transparency
# log. Flux checks the signature once the OCIRepository's verify is on.
#
function sign_digest()
{
	local digest_url="$1"

	if [[ ! -f "$signing_key" ]]; then
		warn "No signing key at ${signing_key#"$repo_dir/"}; pushed unsigned"
		return 0
	fi
	command -v cosign >/dev/null || {
		error "cosign is not on PATH, and the signing key exists!"
		return 1
	}
	run sops exec-env "$signing_key" \
		"cosign sign --yes --tlog-upload=false --key env://COSIGN_PRIVATE_KEY \
		 --registry-username '$user' --registry-password '$password' \
		 '$digest_url'" || return $?
	log "Signed $digest_url"
}
