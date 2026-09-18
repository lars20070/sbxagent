#!/usr/bin/env bash
# Shared helpers for the read-claude-code-session-traces scripts.
#
# Sourced, never executed. Every function here assumes `set -euo pipefail` in
# the caller. Targets bash 3.2, so no associative arrays: anything needing a
# map does it in awk instead.

# Name the caller, not this file, so errors read as the command the user ran.
SELF="$(basename "$0")"

die() {
	echo "${SELF}: $*" >&2
	exit 1
}

warn() {
	echo "${SELF}: $*" >&2
}

# Fail early and by name when a dependency is missing. These scripts are
# thin wrappers around jq and rg; without them nothing below works.
require_tools() {
	local tool
	for tool in "$@"; do
		command -v "${tool}" >/dev/null 2>&1 ||
			die "'${tool}' is required but was not found on PATH"
	done
}

need_file() {
	[[ -f "$1" ]] || die "not a file: $1"
	[[ -r "$1" ]] || die "not readable: $1"
}

need_dir() {
	[[ -d "$1" ]] || die "not a directory: $1"
	[[ -r "$1" ]] || die "not readable: $1"
}

# Collect the top-level session transcripts of a trace directory into a file,
# NUL-separated so paths containing spaces, colons or newlines survive.
# Subdirectories hold subagent transcripts and offloaded tool output and are
# deliberately skipped.
#
# The list goes to a file rather than straight down a pipe on purpose. Feeding a
# `while read` loop from a process substitution would run this in a subshell,
# where die() could only kill that subshell: an empty directory would look like
# a directory whose every session was empty, and the caller would report success
# over nothing at all.
list_sessions() {
	local dir="$1" out="$2" file found=0
	: >"${out}"
	for file in "${dir}"/*.jsonl; do
		[[ -f "${file}" ]] || continue
		printf '%s\0' "${file}" >>"${out}"
		found=1
	done
	[[ "${found}" -eq 1 ]] || die "no .jsonl session files in: ${dir}"
}

# Emit the subagent transcripts belonging to a session file, NUL-separated.
# Absent is normal: a session only gets the directory if it spawned subagents.
subagent_files() {
	local session="$1" dir file
	dir="$(dirname -- "${session}")/$(session_id_of "${session}")/subagents"
	[[ -d "${dir}" ]] || return 0
	for file in "${dir}"/*.jsonl; do
		[[ -f "${file}" ]] || continue
		printf '%s\0' "${file}"
	done
}

# The session id, taken from the filename. The `sessionId` field inside the
# records matches it, but the filename is available without parsing anything.
session_id_of() {
	local base
	base="$(basename -- "$1")"
	printf '%s' "${base%.jsonl}"
}

# Feed a transcript to jq, dropping a trailing partial line.
#
# These files are appended to live, so the last line can be half-written when a
# reader opens it. jq aborts the whole stream on one malformed line, which would
# turn a cosmetic race into a failed report, so check that one line up front.
# Corruption anywhere else is not silently tolerated: jq will fail and the
# caller reports it.
feed() {
	local file="$1" last
	last="$(tail -n 1 -- "${file}")"
	if [[ -n "${last}" ]] && ! printf '%s\n' "${last}" | jq -e . >/dev/null 2>&1; then
		warn "ignoring an incomplete final line in $(basename -- "${file}") (file is probably being written)"
		sed '$d' -- "${file}"
	else
		cat -- "${file}"
	fi
}

# Shared jq preamble: timestamp helpers and the record classification the
# schema reference describes. Prepended to the filters in the other scripts.
#
# Timestamps carry milliseconds, which fromdateiso8601 rejects, hence the strip.
# All time arithmetic lives here rather than in `date`, whose parsing flags
# differ between GNU and BSD.
# SC2034: consumed by the scripts that source this file, not by this file.
# SC2016: jq syntax — `$n` and friends must reach jq unexpanded by the shell.
# shellcheck disable=SC2034,SC2016
JQ_PRELUDE='
def epoch: if . == null then null else (sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) end;
def hms:
	if . == null then "-"
	else
		(. | floor) as $s
		| if $s >= 3600 then "\(($s / 3600) | floor)h \((($s % 3600) / 60) | floor)m"
			elif $s >= 60 then "\(($s / 60) | floor)m \($s % 60)s"
			else "\($s)s" end
	end;
def is_chain: has("uuid");
def flat: if . == null then "" else (tostring | gsub("[\\r\\n\\t]+"; " ")) end;
def clip($n): if ($n > 0 and (. | length) > $n) then (.[0:$n] + " …[truncated]") else . end;
'
