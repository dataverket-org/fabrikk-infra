# shellcheck shell=bash
#
# Logging for every script in bin/, sourced and never run. Four functions print
# their arguments as one line: log to stdout, warn and error to stderr, debug
# only when enable_debug is 1; the first three show $HOME as ~. run calls
# debug then the command, so --debug shows every external call. fail prints
# and exits, and is the one function here that does.
#

#
# Bash 5.2 or newer. macOS's /bin/bash is 3.2, so under it the script
# restarts with Homebrew's bash and its own arguments, before it has done
# anything.
#
if (( BASH_VERSINFO[0] * 100 + BASH_VERSINFO[1] < 502 )) && [[ -f "$0" ]]
then
	for logging_bash in "${HOMEBREW_PREFIX:-/opt/homebrew}/bin/bash" \
	                    /usr/local/bin/bash /home/linuxbrew/.linuxbrew/bin/bash
	do
		[[ -x "$logging_bash" ]] && exec "$logging_bash" "$0" "$@"
	done

	echo "!!! bash $BASH_VERSION is too old; brew bundle installs bash 5" >&2
	exit 1
fi

#
# Every message, debug included, also goes to log_file as one JSON object per
# line: the fields of Go's log/slog JSON handler (time, level, msg), then
# script and run, the id LOG_RUN gives a whole task invocation. LOG_FILE
# moves it; LOG_FILE= turns it off. No value is ever a message or an argument
# (operator rule 4), so nothing secret reaches it.
#
log_file="${LOG_FILE-${XDG_STATE_HOME:-$HOME/.local/state}/$(
	basename "$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)")/log.jsonl}"
log_script="${0##*/}"
log_run="${LOG_RUN:-$(date -u +%Y%m%dT%H%M%SZ)-$$}"

#
# Appends one record to log_file; never fails the caller.
#
function log_json()
{
	local level="$1"
	shift

	[[ -n "$log_file" ]] && command -v jq >/dev/null || return 0
	mkdir -p "${log_file%/*}" 2>/dev/null || return 0

	jq -nc --arg level "$level" --arg msg "$*" --arg script "$log_script" \
	   --arg run "$log_run" '
		now as $t |
		{time: (($t | floor | strftime("%Y-%m-%dT%H:%M:%S")) + "." +
		        ("00" + ($t * 1000 | floor % 1000 | tostring))[-3:] + "Z"),
		 level: $level, msg: $msg, script: $script, run: $run}' \
		>>"$log_file" 2>/dev/null || true
}

#
# Prints a string with $HOME as ~.
#
function tilde()
{
	echo -n "${1//"$HOME"/"~"}"
}

#
# Prints a log message.
#
function log()
{
	local message

	log_json INFO "$*"
	message="$(tilde "$*")"

	if [[ -t 1 ]]; then
		echo -e "\x1b[1m\x1b[32m>>>\x1b[0m \x1b[1m$message\x1b[0m"
	else
		echo ">>> $message"
	fi
}

#
# Prints a warning message.
#
function warn()
{
	local message

	log_json WARN "$*"
	message="$(tilde "$*")"

	if [[ -t 1 ]]; then
		echo -e "\x1b[1m\x1b[33m***\x1b[0m \x1b[1m$message\x1b[0m" >&2
	else
		echo "*** $message" >&2
	fi
}

#
# Prints an error message.
#
function error()
{
	local message

	log_json ERROR "$*"
	message="$(tilde "$*")"

	if [[ -t 1 ]]; then
		echo -e "\x1b[1m\x1b[31m!!!\x1b[0m \x1b[1m$message\x1b[0m" >&2
	else
		echo "!!! $message" >&2
	fi
}

# enable_debug is set from DEBUG in admin.sh.

#
# Prints a debugging message, only if enable_debug is enabled.
#
function debug()
{
	log_json DEBUG "$*"

	if [[ ! $enable_debug -eq 1 ]]; then
		return
	fi

	echo "[DEBUG] $1" >&2
}

#
# Runs the command and prints the full command if debugging is enabled.
#
function run()
{
	debug "$*"
	"$@"
}

#
# Prints an error message and exits.
#
function fail()
{
	error "$*"
	exit 1
}
