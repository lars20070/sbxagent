#!/usr/bin/env bash
# List the sessions in a Claude Code trace directory: what they were about,
# when they ran, how long, how much they cost, and which ones continue which.
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
Usage: index.sh <trace-dir>

List every session transcript in a Claude Code trace directory, one row each.

Columns:
  session   the session id (the filename stem)
  title     the last ai-title, else the last agent-name, else "-"
  start     timestamp of the first record that is part of the conversation
  span      time from the first such record to the last
  prompts   number of typed human turns
  cost      the last cost-state's totalCostUSD, or "-" when absent
  lineage   the session this one was resumed from, or "-" when it is an origin

Rows are grouped by lineage: sessions resumed from a common origin sit
together, groups run oldest-first, and members within a group run oldest-first.
ENDOFUSAGE
}

trace_dir=""
while [[ $# -gt 0 ]]; do
	case "$1" in
	-h | --help)
		usage
		exit 0
		;;
	--)
		shift
		break
		;;
	-*)
		die "unknown option: $1 (try -h)"
		;;
	*)
		[[ -z "${trace_dir}" ]] || die "expected one trace directory, also got: $1"
		trace_dir="$1"
		shift
		;;
	esac
done
[[ $# -eq 0 ]] || { trace_dir="${trace_dir:-$1}"; }

[[ -n "${trace_dir}" ]] || {
	usage >&2
	exit 1
}

require_tools jq
need_dir "${trace_dir}"

# One streaming pass per file. Everything the table needs is a running
# accumulation, so nothing larger than a handful of scalars is ever held.
read_session() {
	local file="$1" sid
	sid="$(session_id_of "${file}")"
	feed "${file}" | jq -n -r --arg sid "${sid}" "
		${JQ_PRELUDE}"'
		def money: if . == null then "-" else "$\((. * 10000 | round) / 10000)" end;
		reduce inputs as $r (
			{first: null, last: null, prompts: 0, title: null, name: null, cost: null, lineage: null};
			(if ($r | is_chain) and $r.timestamp != null
				then (if .first == null then .first = $r.timestamp else . end) | .last = $r.timestamp
				else . end)
			| (if $r.type == "user" and ($r.message.content | type) == "string"
				then .prompts += 1 else . end)
			| (if $r.type == "ai-title" then .title = $r.aiTitle else . end)
			| (if $r.type == "agent-name" then .name = $r.agentName else . end)
			| (if $r.type == "cost-state" then .cost = $r.totalCostUSD else . end)
			| (if $r.session_id != null and $r.session_id != $sid
				then .lineage = $r.session_id else . end)
		)
		| (.title // .name) as $title
		| (if .first == null or .last == null then null
			else (.last | epoch) - (.first | epoch) end) as $span
		| [
			(.first // "~"),
			(.lineage // $sid),
			$sid,
			(if $title == null then "-" else ($title | flat | clip(48)) end),
			(.first // "-"),
			($span | hms),
			(.prompts | tostring),
			(.cost | money),
			(.lineage // "-")
		] | @tsv'
}

rows="$(mktemp)"
grouped="$(mktemp)"
sessions="$(mktemp)"
trap 'rm -f "${rows}" "${grouped}" "${sessions}"' EXIT

list_sessions "${trace_dir}" "${sessions}"
while IFS= read -r -d '' session_file; do
	read_session "${session_file}" >>"${rows}"
done <"${sessions}"

# Prefix each row with its lineage group's earliest start so one sort orders
# groups and their members together. Sessions with no usable timestamp sort
# last: "~" is above every digit in ASCII, and displays as "-".
awk -F'\t' '
	NR == FNR {
		if (!($2 in first) || $1 < first[$2]) first[$2] = $1
		next
	}
	{ print first[$2] "\t" $0 }
' "${rows}" "${rows}" | LC_ALL=C sort -t"$(printf '\t')" -k1,1 -k2,2 -k3,3 >"${grouped}"

# Two passes to size the columns, so a long title cannot shear the table.
awk -F'\t' '
	BEGIN {
		split("session title start span prompts cost lineage", head, " ")
		for (i = 1; i <= 7; i++) width[i] = length(head[i])
	}
	{
		n++
		for (i = 1; i <= 7; i++) {
			cell[n, i] = $(i + 3)
			if (length(cell[n, i]) > width[i]) width[i] = length(cell[n, i])
		}
		group[n] = $3
	}
	END {
		if (n == 0) { print "no sessions found"; exit }
		line = ""
		for (i = 1; i <= 7; i++) line = line sprintf("%-*s  ", width[i], head[i])
		print line
		for (i = 1; i <= 7; i++) { dash = ""; while (length(dash) < width[i]) dash = dash "-"
			printf "%-*s  ", width[i], dash }
		printf "\n"
		for (r = 1; r <= n; r++) {
			if (r > 1 && group[r] != group[r - 1]) printf "\n"
			line = ""
			for (i = 1; i <= 7; i++) line = line sprintf("%-*s  ", width[i], cell[r, i])
			sub(/ +$/, "", line)
			print line
		}
	}
' "${grouped}"
