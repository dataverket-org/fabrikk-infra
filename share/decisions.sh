# shellcheck shell=bash
#
# Shared by bin/decisions-*: where the decisions are, how to read one, and how
# to print the set. Sourced, never run.
#
# The frontmatter and the section headings follow Structured MADR as Dataverket
# defines it, in builder-hugo's config/smadr-validator.yaml and
# internal/smadrvalidator/schemas/dataverket-policy.schema.json: the required
# fields, the filename pattern NNN-slug.md, the six sections, and the allowed
# values for type, project, category and status. Validating that is
# builder-hugo's job and is not repeated here.
#
# A number is an identity and nothing more. A new decision takes the next free
# one whatever its subject, so number order stops matching category order the
# first time that happens; the grouping comes from `category:`.
#

repo_dir="$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)" || return $?
dir="$repo_dir/docs/decisions"
index="$dir/README.md"

# Category, then the heading it prints under, most governing first. The
# categories are the ones dataverket-policy.schema.json allows; one that is not
# listed here is reported rather than silently dropped.
groups=(
	"security:Credentials and access"
	"architecture:Boundaries and direction"
	"infrastructure:How the repository is run"
	"data:Storage"
)

#
# Prints the decision files, in number order.
#
function decision_files()
{
	local file

	for file in "$dir"/[0-9][0-9][0-9]-*.md; do
		[[ -e "$file" ]] && echo "$file"
	done
}

#
# Prints one frontmatter field of a decision file.
#
function field()
{
	local file="$1"
	local name="$2"

	NAME="$name" yq --front-matter=extract -r '.[strenv(NAME)] // ""' "$file"
}

#
# Prints the audit status of a decision, lowercased, or "none" when it has no
# audit entry yet. Entries under `## Audit` are appended, newest last, so the
# last one is where the record stands now.
#
function audit_status()
{
	local file="$1"
	local status

	status="$(grep -oE '^\*\*Status:\*\* .+' "$file" | tail -1 |
	          sed 's/^\*\*Status:\*\* //')"
	echo -n "$(echo "${status:-none}" | tr '[:upper:]' '[:lower:]')"
}

#
# Prints the number a new decision would take: one past the highest in use.
#
function next_number()
{
	local file last=0 number

	while read -r file; do
		number="${file##*/}"
		number="${number%%-*}"
		(( 10#$number > last )) && last=$(( 10#$number ))
	done <<<"$(decision_files)"

	printf '%03d' $(( last + 1 ))
}

#
# Prints a title as a filename slug: lowercase, one hyphen between words.
#
function slugify()
{
	echo -n "$1" | tr '[:upper:]' '[:lower:]' |
		sed 's/[^a-z0-9]\+/-/g; s/^-\+//; s/-\+$//'
}

#
# Prints the whole set as a table: what is decided, what is still pending, and
# how old each one is.
#
function table()
{
	local file number

	printf '%-5s %-10s %-12s %-15s %-11s %s\n' \
		"#" "STATUS" "AUDIT" "CATEGORY" "ACCEPTED" "DECISION"

	while read -r file; do
		number="${file##*/}"
		number="${number%%-*}"
		printf '%-5s %-10s %-12s %-15s %-11s %s\n' \
			"$number" \
			"$(field "$file" status)" \
			"$(audit_status "$file")" \
			"$(field "$file" category)" \
			"$(field "$file" created)" \
			"$(field "$file" title | cut -c1-55)"
	done <<<"$(decision_files)"
}

#
# Prints "N decisions, M not yet implemented".
#
function summary()
{
	local file total=0 pending=0

	while read -r file; do
		total=$(( total + 1 ))
		[[ "$(audit_status "$file")" == implemented ]] || pending=$(( pending + 1 ))
	done <<<"$(decision_files)"

	if (( pending )); then
		echo -n "$total decisions, $pending not yet implemented"
	else
		echo -n "$total decisions, all implemented"
	fi
}
