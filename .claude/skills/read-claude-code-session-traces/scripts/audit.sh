#!/usr/bin/env bash
# Cost, token and tool-usage accounting for Claude Code session transcripts.
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
Usage: audit.sh [options] <trace-dir | session.jsonl>

Report what a session or a whole trace directory cost, which models it used,
and how its tool calls went.

Cost comes from the last cost-state record, which is the figure Claude Code
itself keeps. It is not recomputed from token prices. A session can have no
cost-state at all; that session reports "unavailable" and the rest of the run
continues.

Token totals are read from the transcript and deduplicated by requestId, so
they are a lower bound: cost-state also covers background model calls that the
transcript never records. Both figures are shown so the gap is visible.

Tool durations are elapsed wall time between a tool_use record and its
tool_result. Calls issued in parallel overlap, so the per-tool figures are not
summed into a session total; cost-state's own totalToolDuration is reported
separately for that.

A call counts as failed only when its tool_result carries is_error: true.

Options:
  --include-subagents   fold subagent transcripts into tokens and tool counts
  --json                emit the raw per-session JSON instead of a report
ENDOFUSAGE
}

include_subagents=0
as_json=0
target=""

while [[ $# -gt 0 ]]; do
	case "$1" in
	-h | --help)
		usage
		exit 0
		;;
	--include-subagents)
		include_subagents=1
		shift
		;;
	--json)
		as_json=1
		shift
		;;
	--)
		shift
		[[ $# -eq 1 ]] || die "expected one path after --"
		target="$1"
		shift
		;;
	-*)
		die "unknown option: $1 (try -h)"
		;;
	*)
		[[ -z "${target}" ]] || die "expected one path, also got: $1"
		target="$1"
		shift
		;;
	esac
done

[[ -n "${target}" ]] || {
	usage >&2
	exit 1
}

require_tools jq

# One streaming pass per transcript. The only maps held are keyed by tool call
# and by requestId, so memory tracks the number of calls, not the file size.
scan() {
	feed "$1" | jq -n -c "${JQ_PRELUDE}"'
		reduce inputs as $r (
			{seen: {}, tok: {i: 0, o: 0, cr: 0, cc: 0, th: 0}, use: {}, res: [], cost: null};
			if $r.type == "assistant" then
				(if (.seen[$r.requestId // "-"] // false) then .
					else
						.seen[$r.requestId // "-"] = true
						| .tok.i += ($r.message.usage.input_tokens // 0)
						| .tok.o += ($r.message.usage.output_tokens // 0)
						| .tok.cr += ($r.message.usage.cache_read_input_tokens // 0)
						| .tok.cc += ($r.message.usage.cache_creation_input_tokens // 0)
						| .tok.th += ($r.message.usage.output_tokens_details.thinking_tokens // 0)
					end)
				| reduce ($r.message.content[]? | select(.type == "tool_use")) as $b (.;
					.use[$b.id] = {name: ($b.name // "(unnamed)"), ts: ($r.timestamp | epoch)})
			elif $r.type == "user" then
				reduce ($r.message.content[]? | select(.type == "tool_result")) as $b (.;
					.res += [{
						id: ($b.tool_use_id // ""),
						err: (($b.is_error // false) == true),
						ts: ($r.timestamp | epoch),
						ms: ($r.toolUseResult | if type == "object" then .durationMs else null end)
					}])
			elif $r.type == "cost-state" then .cost = $r
			else . end
		)
		| .use as $use
		| (reduce .res[] as $x ({};
				($use[$x.id].name // "(no matching call)") as $n
				| .[$n] = {
					calls: ((.[$n].calls // 0) + 1),
					failures: ((.[$n].failures // 0) + (if $x.err then 1 else 0 end)),
					elapsed: ((.[$n].elapsed // 0)
						+ (if ($use[$x.id].ts != null and $x.ts != null)
							then ($x.ts - $use[$x.id].ts) else 0 end)),
					measured_ms: ((.[$n].measured_ms // 0) + ($x.ms // 0)),
					measured_calls: ((.[$n].measured_calls // 0) + (if $x.ms == null then 0 else 1 end))
				}
			)) as $tools
		| ([.res[].id] | map(select(. != "")) | unique) as $answered
		| {
			tokens: .tok,
			tools: $tools,
			unanswered: ([$use | keys[] | select(. as $k | $answered | index($k) | not)] | length),
			cost: (if .cost == null then null else {
				totalCostUSD: (.cost.totalCostUSD // null),
				totalToolDuration: (.cost.totalToolDuration // null),
				totalDuration: (.cost.totalDuration // null),
				totalAPIDuration: (.cost.totalAPIDuration // null),
				linesAdded: (.cost.totalLinesAdded // null),
				linesRemoved: (.cost.totalLinesRemoved // null),
				modelUsage: (.cost.modelUsage // {})
			} end)
		}'
}

# Merge a subagent transcript into its parent session's numbers. Subagent files
# never carry a cost-state of their own; their spend is already inside the
# parent's, so only tokens and tool counts are folded in.
merge() {
	jq -s '
		def add_tools($a; $b):
			reduce ($b | keys_unsorted[]) as $k ($a;
				.[$k] = {
					calls: ((.[$k].calls // 0) + $b[$k].calls),
					failures: ((.[$k].failures // 0) + $b[$k].failures),
					elapsed: ((.[$k].elapsed // 0) + $b[$k].elapsed),
					measured_ms: ((.[$k].measured_ms // 0) + $b[$k].measured_ms),
					measured_calls: ((.[$k].measured_calls // 0) + $b[$k].measured_calls)
				});
		reduce .[1:][] as $x (.[0];
			.tokens.i += $x.tokens.i | .tokens.o += $x.tokens.o
			| .tokens.cr += $x.tokens.cr | .tokens.cc += $x.tokens.cc
			| .tokens.th += $x.tokens.th
			| .unanswered += $x.unanswered
			| .tools = add_tools(.tools; $x.tools))'
}

summaries="$(mktemp)"
parts="$(mktemp)"
sessions="$(mktemp)"
trap 'rm -f "${summaries}" "${parts}" "${sessions}"' EXIT

audit_one() {
	local session="$1" session_id
	session_id="$(session_id_of "${session}")"
	: >"${parts}"
	scan "${session}" >>"${parts}"
	if [[ "${include_subagents}" -eq 1 ]]; then
		while IFS= read -r -d '' subagent; do
			scan "${subagent}" >>"${parts}"
		done < <(subagent_files "${session}")
	fi
	merge <"${parts}" | jq -c --arg session "${session_id}" '{session: $session} + .' >>"${summaries}"
}

if [[ -d "${target}" ]]; then
	need_dir "${target}"
	list_sessions "${target}" "${sessions}"
	while IFS= read -r -d '' session_file; do
		audit_one "${session_file}"
	done <"${sessions}"
elif [[ -e "${target}" ]]; then
	need_file "${target}"
	case "${target}" in
	*.jsonl) ;;
	*) die "expected a .jsonl transcript or a directory: ${target}" ;;
	esac
	audit_one "${target}"
else
	die "no such file or directory: ${target}"
fi

if [[ "${as_json}" -eq 1 ]]; then
	cat "${summaries}"
	exit 0
fi

jq -s -r '
	def money: if . == null then "unavailable" else "$\((. * 10000 | round) / 10000)" end;
	def num: if . == null then "-" else (. | tostring) end;
	def secs: if . == null then "-" else "\((. / 1000) | round)s" end;
	def pad($n): (. | tostring) as $s | $s + (" " * (($n - ($s | length)) | if . < 0 then 0 else . end));

	. as $all
	| "# Cost",
		"",
		(("session" | pad(38)) + ("cost" | pad(13)) + "models"),
		(("-" * 36 | pad(38)) + ("-" * 11 | pad(13)) + ("-" * 30)),
		($all[] | (.session | pad(38))
			+ ((.cost.totalCostUSD | money) | pad(13))
			+ ((.cost.modelUsage // {}) | keys | join(", ") | if . == "" then "-" else . end)),
		"",
		"total: " + (([$all[] | .cost.totalCostUSD // 0] | add) | money)
			+ "   (sessions with no cost-state are excluded from this total)",
		"",
		"# Tokens",
		"",
		"Deduplicated by requestId from the transcript. input_tokens is a",
		"placeholder in this format; the prompt-side figure that means something is",
		"cache read + cache create. These are a lower bound on what was billed:",
		"cost-state covers background model calls the transcript never records.",
		"",
		(("session" | pad(38)) + ("output" | pad(12)) + ("thinking" | pad(12))
			+ ("cache read" | pad(14)) + "cache create"),
		(("-" * 36 | pad(38)) + ("-" * 10 | pad(12)) + ("-" * 10 | pad(12))
			+ ("-" * 12 | pad(14)) + ("-" * 12)),
		($all[] | (.session | pad(38))
			+ (.tokens.o | num | pad(12)) + (.tokens.th | num | pad(12))
			+ (.tokens.cr | num | pad(14)) + (.tokens.cc | num)),
		"",
		"# Tools",
		"",
		"Elapsed is wall time from the call record to its result record, summed.",
		"Parallel calls overlap, so it is an upper bound on real time spent, and is",
		"deliberately not reconciled with cost-state totalToolDuration below.",
		"Measured is the duration a tool reported itself, where it reports one.",
		"",
		(("tool" | pad(36)) + ("calls" | pad(8)) + ("failed" | pad(8))
			+ ("elapsed" | pad(10)) + "measured"),
		(("-" * 34 | pad(36)) + ("-" * 6 | pad(8)) + ("-" * 6 | pad(8))
			+ ("-" * 8 | pad(10)) + ("-" * 8)),
		((reduce ($all[] | .tools) as $t ({};
			reduce ($t | keys_unsorted[]) as $k (.;
				.[$k] = {
					calls: ((.[$k].calls // 0) + $t[$k].calls),
					failures: ((.[$k].failures // 0) + $t[$k].failures),
					elapsed: ((.[$k].elapsed // 0) + $t[$k].elapsed),
					measured_ms: ((.[$k].measured_ms // 0) + $t[$k].measured_ms),
					measured_calls: ((.[$k].measured_calls // 0) + $t[$k].measured_calls)
				}))) as $agg
			| ($agg | to_entries | sort_by(-.value.calls)[]
				| (.key | pad(36)) + (.value.calls | num | pad(8))
					+ (.value.failures | num | pad(8))
					+ ((.value.elapsed | floor) | tostring | . + "s" | pad(10))
					+ (if .value.measured_calls == 0 then "-"
						else "\(.value.measured_ms | secs) over \(.value.measured_calls)" end))),
		"",
		"unanswered tool calls (no matching result): "
			+ (([$all[] | .unanswered] | add) | num),
		"",
		"# Session totals reported by cost-state",
		"",
		(("session" | pad(38)) + ("wall" | pad(10)) + ("api" | pad(10))
			+ ("tools" | pad(10)) + "lines +/-"),
		(("-" * 36 | pad(38)) + ("-" * 8 | pad(10)) + ("-" * 8 | pad(10))
			+ ("-" * 8 | pad(10)) + ("-" * 9)),
		($all[] | (.session | pad(38))
			+ (.cost.totalDuration | secs | pad(10))
			+ (.cost.totalAPIDuration | secs | pad(10))
			+ (.cost.totalToolDuration | secs | pad(10))
			+ "\(.cost.linesAdded | num)/\(.cost.linesRemoved | num)")
' <"${summaries}"
