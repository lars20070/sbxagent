#!/usr/bin/env bash
# Find text across the sessions in a Claude Code trace directory.
# common.sh is sourced at runtime from this script's own directory. `make lint`
# runs shellcheck without -x, so it cannot follow the source: SC1091 is that
# miss and SC2154 is the helper variable it therefore cannot see. Both are
# verified separately with `shellcheck -x`, which does follow the source.
# shellcheck disable=SC1091,SC2154
set -euo pipefail

SCRIPT_DIR="$(dirname -- "$0")"
# shellcheck source=common.sh
. "${SCRIPT_DIR}/common.sh"

usage() {
	cat <<'ENDOFUSAGE'
Usage: search.sh [options] <trace-dir> [--] <pattern>

Search every session in a trace directory and report which session, when, and
in what kind of record each hit sits.

rg finds the candidate lines and jq decodes only those, so a large directory
costs one fast scan rather than a full parse.

The pattern is a literal string by default, so punctuation needs no escaping.
Put it after -- if it begins with a dash.

Options:
  -e, --regex           treat the pattern as a regular expression
  -i, --ignore-case     match case-insensitively
  --all-types           also search session bookkeeping records
  --include-subagents   also search subagent transcripts
  --include-offloaded   also search offloaded tool output (tool-results/*.txt)
  --max-hits N          stop after N hits per session (default 20, 0 = no limit)

Exits 1 when nothing matched.
ENDOFUSAGE
}

regex=0
ignore_case=0
all_types=0
include_subagents=0
include_offloaded=0
max_hits=20
trace_dir=""
pattern=""
have_pattern=0

while [[ $# -gt 0 ]]; do
	case "$1" in
	-h | --help)
		usage
		exit 0
		;;
	-e | --regex)
		regex=1
		shift
		;;
	-i | --ignore-case)
		ignore_case=1
		shift
		;;
	--all-types)
		all_types=1
		shift
		;;
	--include-subagents)
		include_subagents=1
		shift
		;;
	--include-offloaded)
		include_offloaded=1
		shift
		;;
	--max-hits)
		[[ $# -ge 2 ]] || die "--max-hits needs a number"
		[[ "$2" =~ ^[0-9]+$ ]] || die "--max-hits needs a number, got: $2"
		max_hits="$2"
		shift 2
		;;
	--)
		shift
		[[ $# -ge 1 ]] || die "-- must be followed by the pattern"
		pattern="$1"
		have_pattern=1
		shift
		[[ $# -eq 0 ]] || die "unexpected argument after the pattern: $1"
		;;
	-*)
		die "unknown option: $1 (try -h)"
		;;
	*)
		if [[ -z "${trace_dir}" ]]; then
			trace_dir="$1"
		elif [[ "${have_pattern}" -eq 0 ]]; then
			pattern="$1"
			have_pattern=1
		else
			die "unexpected argument: $1"
		fi
		shift
		;;
	esac
done

[[ -n "${trace_dir}" && "${have_pattern}" -eq 1 ]] || {
	usage >&2
	exit 1
}
[[ -n "${pattern}" ]] || die "the pattern is empty"

require_tools jq rg
need_dir "${trace_dir}"

lines="$(mktemp)"
scratch="$(mktemp)"
sessions="$(mktemp)"
trap 'rm -f "${lines}" "${scratch}" "${sessions}"' EXIT

# rg is invoked one file at a time with --no-filename, so its output is always
# "<line>:<text>". Nothing has to be prised out of a path, which keeps a colon
# or a space in the directory name harmless.
#
# Building the argument list in an array rather than interpolating a string
# keeps an empty optional flag from turning into an empty argument.
hits_in() {
	local file="$1" status=0
	local -a args
	args=(--no-filename --line-number)
	[[ "${ignore_case}" -eq 1 ]] && args+=(--ignore-case)
	[[ "${regex}" -eq 1 ]] || args+=(--fixed-strings)
	rg "${args[@]}" --regexp "${pattern}" -- "${file}" || status=$?
	# 1 is "no matches", an ordinary outcome here. Anything else is a real fault.
	[[ "${status}" -le 1 ]] || die "rg failed on: ${file}"
}

# Turn the matching line numbers into one summary line per record.
report_records() {
	local file="$1"
	feed "${file}" |
		awk 'NR == FNR { keep[$1] = 1; next } (FNR in keep)' "${lines}" - |
		jq -r \
			--arg pat "${pattern}" \
			--argjson regex "${regex}" \
			--argjson icase "${ignore_case}" \
			--argjson all "${all_types}" \
			"${JQ_PRELUDE}"'
		# Everything a person might plausibly have been searching for, as one
		# string per record.
		#
		# rg scans the raw JSON line, so it matches fields this does not name.
		# The tool-output fields below are here because that is where a match
		# most often lands and where the API-shaped tool_result block carries
		# only a truncated preview; without them a hit in Bash stdout would be
		# reported with an excerpt that does not contain what was searched for.
		# Anything still missed is caught by the raw-JSON fallback in excerpt.
		def tool_output:
			if type == "string" then [.]
			elif type == "array" then [.[]? | if type == "object" then .text? else tostring end]
			elif type == "object" then
				[.stdout?, .stderr?, .result?, .codeText?, .content?, .plan?, .query?,
					.filePath?, .oldString?, .newString?, .description?, .prompt?,
					(.file? | if type == "object" then .content? else null end)]
			else [] end;

		def searchable:
			[ (.message.content | if type == "string" then . else null end),
				(.message.content[]? | .text?, .thinking?,
					(.input? | if . == null then null else tojson end),
					(.content? | if type == "string" then .
						elif type == "array" then (map(.text?) | join(" "))
						else null end)),
				.content?,
				(.toolUseResult? | tool_output)[]?,
				((.rendered // .renderedInHumanTurn // []) | map(.content?) | join(" ")),
				.aiTitle?, .agentName?, .lastPrompt?
			]
			| map(select(type == "string" and . != ""))
			| join("   ");

		def window($text; $at):
			(($at - 55) | if . < 0 then 0 else . end) as $from
			| (($text[$from:($at + 110)]) | flat) as $w
			| (if $from > 0 then "..." + $w else $w end) + "...";

		def find($text):
			($text | if $icase == 1 then ascii_downcase else . end) as $hay
			| ($pat | if $icase == 1 then ascii_downcase else . end) as $needle
			| if $regex == 1
				then (try ($hay | match($needle) | .offset) catch null)
				else ($hay | index($needle))
				end;

		# rg matched this record, so something in it contains the pattern. When the
		# readable text does not, fall back to the raw JSON rather than printing an
		# excerpt that lacks what was searched for: a hit the user cannot see is
		# worse than an ugly one.
		def excerpt($text):
			find($text) as $at
			| if $at != null then window($text; $at)
				else (tojson) as $raw
					| find($raw) as $rawAt
					| if $rawAt != null then "(raw) " + window($raw; $rawAt)
						else ($text | flat | clip(150))
						end
				end;

		select($all == 1 or is_chain)
		| . as $r
		| (searchable) as $text
		| [ ($r.timestamp // "-"),
			($r.type // "-"),
			(($r.uuid // "--------")[0:8]),
			excerpt($text)
		] | @tsv' |
		awk -F'\t' '{ printf "  %-24s  %-10s  %-8s  %s\n", $1, $2, $3, $4 }'
}

# One session or subagent transcript. Writes nothing when it has no hits, so
# the caller can tell an empty result from a real one.
#
# The count comes from the records actually reported, not from the lines rg
# matched. Those differ whenever a record type is out of scope: rg sees the raw
# JSON of every record, while the report covers only the ones in scope, and a
# heading claiming hits above an empty list would be a lie.
emit_records() {
	local file="$1" label="$2" count limit
	hits_in "${file}" | cut -d: -f1 >"${lines}"
	[[ -s "${lines}" ]] || return 0
	report_records "${file}" >"${scratch}"
	count="$(wc -l <"${scratch}")"
	count="${count// /}"
	[[ "${count}" -gt 0 ]] || return 0
	limit="${count}"
	if [[ "${max_hits}" -gt 0 && "${count}" -gt "${max_hits}" ]]; then
		limit="${max_hits}"
		printf '=== %s (%s hits, showing %s) ===\n' "${label}" "${count}" "${limit}"
	else
		printf '=== %s (%s hits) ===\n' "${label}" "${count}"
	fi
	head -n "${limit}" "${scratch}"
	printf '\n'
}

# Offloaded tool output is plain text, so rg's own output is the report.
emit_text() {
	local file="$1" label="$2" count limit
	hits_in "${file}" >"${lines}"
	count="$(wc -l <"${lines}")"
	count="${count// /}"
	[[ "${count}" -gt 0 ]] || return 0
	limit="${count}"
	[[ "${max_hits}" -gt 0 && "${count}" -gt "${max_hits}" ]] && limit="${max_hits}"
	printf '=== %s (%s hits, showing %s) ===\n' "${label}" "${count}" "${limit}"
	head -n "${limit}" "${lines}" |
		awk -F: '{ n = $1; sub(/^[0-9]+:/, ""); printf "  line %-8s  %.150s\n", n, $0 }'
	printf '\n'
}

found=0

# Each emitter writes to a buffer first so an empty result prints no heading.
run() {
	local kind="$1" file="$2" label="$3" buffer
	buffer="$(mktemp)"
	if [[ "${kind}" == "text" ]]; then
		emit_text "${file}" "${label}" >"${buffer}"
	else
		emit_records "${file}" "${label}" >"${buffer}"
	fi
	if [[ -s "${buffer}" ]]; then
		cat "${buffer}"
		found=1
	fi
	rm -f "${buffer}"
}

list_sessions "${trace_dir}" "${sessions}"
while IFS= read -r -d '' session_file; do
	session_id="$(session_id_of "${session_file}")"
	run records "${session_file}" "${session_id}"

	if [[ "${include_subagents}" -eq 1 ]]; then
		while IFS= read -r -d '' subagent; do
			agent_name="$(basename -- "${subagent}")"
			run records "${subagent}" "${session_id}/subagents/${agent_name}"
		done < <(subagent_files "${session_file}")
	fi

	if [[ "${include_offloaded}" -eq 1 ]]; then
		offload_dir="$(dirname -- "${session_file}")/${session_id}/tool-results"
		if [[ -d "${offload_dir}" ]]; then
			for offloaded in "${offload_dir}"/*; do
				[[ -f "${offloaded}" ]] || continue
				offload_name="$(basename -- "${offloaded}")"
				run text "${offloaded}" "${session_id}/tool-results/${offload_name}"
			done
		fi
	fi
done <"${sessions}"

if [[ "${found}" -eq 0 ]]; then
	echo "no matches for: ${pattern}"
	exit 1
fi
