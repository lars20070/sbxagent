#!/usr/bin/env bash
# Render one Claude Code session transcript as readable Markdown.
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
Usage: transcript.sh [options] <session.jsonl>

Render one session as Markdown: prompts, replies, tool calls and their results.

A transcript file can hold more than one conversation. Interruptions, retries
and denials leave abandoned branches behind, and printing the file in order
would splice them together as though they were one exchange. So this renders a
single path: it picks a leaf and walks parentUuid back to the root.

Options:
  --leaf UUID         render the path ending at this record (default: the last
                      record in the file that is part of a conversation)
  --list-leaves       list the branch endpoints and exit, newest last
  --thinking          include thinking blocks (usually redacted to empty text)
  --attachments       include injected context: reminders, hook output, files
  --no-tools          omit tool calls and their results
  --max-result N      clip each tool result to N characters (default 800, 0 = no clip)
  --expand-offloaded  inline offloaded tool output instead of noting its path

This renders one file. A conversation resumed across several sessions spans
several files; run index.sh to see the lineage grouping, then render each
member in turn.
ENDOFUSAGE
}

leaf=""
list_leaves=0
show_thinking=0
show_attachments=0
show_tools=1
max_result=800
expand_offloaded=0
session=""

while [[ $# -gt 0 ]]; do
	case "$1" in
	-h | --help)
		usage
		exit 0
		;;
	--leaf)
		[[ $# -ge 2 ]] || die "--leaf needs a uuid"
		leaf="$2"
		shift 2
		;;
	--list-leaves)
		list_leaves=1
		shift
		;;
	--thinking)
		show_thinking=1
		shift
		;;
	--attachments)
		show_attachments=1
		shift
		;;
	--no-tools)
		show_tools=0
		shift
		;;
	--max-result)
		[[ $# -ge 2 ]] || die "--max-result needs a number"
		[[ "$2" =~ ^[0-9]+$ ]] || die "--max-result needs a number, got: $2"
		max_result="$2"
		shift 2
		;;
	--expand-offloaded)
		expand_offloaded=1
		shift
		;;
	--)
		shift
		[[ $# -eq 1 ]] || die "expected one session file after --"
		session="$1"
		shift
		;;
	-*)
		die "unknown option: $1 (try -h)"
		;;
	*)
		[[ -z "${session}" ]] || die "expected one session file, also got: $1"
		session="$1"
		shift
		;;
	esac
done

[[ -n "${session}" ]] || {
	usage >&2
	exit 1
}

require_tools jq
need_file "${session}"

session_dir="$(dirname -- "${session}")"
session_id="$(session_id_of "${session}")"

# Offloaded output is resolved by a post-processing pass, so the renderer has to
# hand it a control line through the same stream as the transcript text. That
# text is untrusted: a prompt or a tool result can contain any bytes at all,
# including whatever a control line looks like. With a fixed marker, transcript
# content could therefore choose which files get opened and inlined.
#
# The marker carries a token drawn fresh for each run, which the data cannot
# predict, and the post-processor additionally refuses any path outside this
# session's own tool-results directory. Either check would do; both are cheap.
offload_token="OFFLOAD-$(od -An -N12 -tx1 /dev/urandom | tr -d ' \n')"
[[ "${offload_token}" != "OFFLOAD-" ]] || die "could not generate a marker token"
offload_root="${session_dir}/${session_id}/tool-results/"

# Pass one: the shape of the conversation tree, nothing else. Only uuid, parent
# and line number are kept, so this stays small however large the transcript is.
chain="$(mktemp)"
keep="$(mktemp)"
trap 'rm -f "${chain}" "${keep}"' EXIT

feed "${session}" |
	jq -r 'select(has("uuid"))
		| [input_line_number, .uuid, (.parentUuid // ""), (.timestamp // ""), .type] | @tsv' >"${chain}"

[[ -s "${chain}" ]] || die "no conversation records in: ${session}"

if [[ "${list_leaves}" -eq 1 ]]; then
	awk -F'\t' '
		{ seen[$2] = 1; ts[$2] = $4; kind[$2] = $5; order[++n] = $2
			if ($3 != "") isparent[$3] = 1 }
		END {
			print "leaf\ttimestamp\ttype"
			for (i = 1; i <= n; i++) {
				u = order[i]
				if (!(u in isparent)) print u "\t" ts[u] "\t" kind[u]
			}
		}
	' "${chain}"
	exit 0
fi

# Walk from the chosen leaf back to the root. awk because bash 3.2 has no
# associative arrays. A visited set makes a cycle terminate instead of hanging,
# and a parent that names a record this file does not contain simply ends the
# walk rather than aborting the render.
awk -F'\t' -v want="${leaf}" '
	{ line[$2] = $1; parent[$2] = $3; order[++n] = $2 }
	END {
		leaf = (want != "") ? want : order[n]
		if (!(leaf in line)) { print "MISSING" > "/dev/stderr"; exit 3 }
		cur = leaf
		while (cur != "" && (cur in line) && !(cur in seen)) {
			seen[cur] = 1
			print line[cur]
			cur = parent[cur]
		}
	}
' "${chain}" >"${keep}" || die "no record with uuid: ${leaf}"

# Pass two: re-read the file, keep only the lines on that path, render them.
#
# One assistant reply is written as several records, one content block each,
# sharing a requestId. A header is opened the first time an id is seen, so the
# blocks reassemble into a single turn. Tracking every id seen, rather than just
# the previous one, means a non-contiguous reappearance cannot split the turn.
render() {
	feed "${session}" |
		awk -F'\t' 'NR == FNR { k[$1] = 1; next } (FNR in k)' "${keep}" - |
		jq -n -r \
			--arg dir "${session_dir}" \
			--arg sid "${session_id}" \
			--arg token "${offload_token}" \
			--argjson tools "${show_tools}" \
			--argjson thinking "${show_thinking}" \
			--argjson attachments "${show_attachments}" \
			--argjson clip "${max_result}" \
			"${JQ_PRELUDE}"'
		def fence($s): "\n```\n" + ($s | rtrimstr("\n")) + "\n```\n";

		# A tool result block carries either a string or a list of blocks.
		def result_text:
			if . == null then ""
			elif type == "string" then .
			elif type == "array" then ([.[] | if type == "object" then (.text // (. | tojson)) else tostring end] | join("\n"))
			else tojson end;

		# Large tool output is written beside the transcript instead of inlined.
		# The recorded path is absolute and belongs to whatever machine wrote it,
		# so rebuild it from this file location rather than trusting it.
		def offload($r):
			($r.toolUseResult | if type == "object" then .persistedOutputPath else null end) as $p
			| if $p == null then ""
				else "\($token) \($r.toolUseResult.persistedOutputSize // 0) \($dir)/\($sid)/tool-results/\($p | split("/") | last)\n"
				end;

		def tool_result($b; $r):
			if $tools == 0 then ""
			else
				"\n**-> result**\($b.tool_use_id // "" | if . == "" then "" else " `\(.)`" end)"
				+ (if ($b.is_error // false) then "  **(error)**" else "" end) + "\n"
				+ fence($b.content | result_text | clip($clip))
				+ offload($r)
			end;

		def user_block($b; $r):
			if $b.type == "text" then "\n## User  _\($r.timestamp // "")_\n\n\($b.text)\n"
			elif $b.type == "tool_result" then tool_result($b; $r)
			else "\n_[user content block: \($b.type // "untyped")]_\n"
			end;

		def assistant_block($b; $r):
			if $b.type == "text" then "\n\($b.text)\n"
			elif $b.type == "thinking" then
				(if $thinking == 0 then ""
					else "\n> _thinking:_ " + (if ($b.thinking // "") == "" then "_(redacted; signature retained)_" else ($b.thinking | flat) end) + "\n"
					end)
			elif $b.type == "tool_use" then
				(if $tools == 0 then ""
					else "\n**<- tool** `\($b.name)`  `\($b.id)`\n" + fence($b.input | tojson | clip($clip))
					end)
			else "\n_[assistant content block: \($b.type // "untyped")]_\n"
			end;

		def system_line($r):
			if $r.subtype == "turn_duration" then ""
			elif ($r.content // "") == "" then ""
			else "\n_[\($r.subtype // "system")]_ \($r.content | flat | clip(400))\n"
			end;

		def attachment_line($r):
			if $attachments == 0 then ""
			else "\n_[attachment: \($r.attachment.type // "untyped")]_ "
				+ (($r.rendered // $r.renderedInHumanTurn // []) | map(.content // "") | join(" ") | flat | clip(400)) + "\n"
			end;

		foreach inputs as $r ({seen: {}, out: ""};
			.out = ""
			| if $r.type == "user" then
					.out = (if ($r.message.content | type) == "string"
						then "\n## User  _\($r.timestamp // "")_\n\n\($r.message.content)\n"
						else ([$r.message.content[]? | user_block(.; $r)] | join(""))
						end)
				elif $r.type == "assistant" then
					(if (.seen[$r.requestId // "-"] // false) then .
						else .seen[$r.requestId // "-"] = true
							| .out = "\n## Assistant  _\($r.timestamp // "") \($r.message.model // "")_\n"
						end)
					| .out = .out + ([$r.message.content[]? | assistant_block(.; $r)] | join(""))
				elif $r.type == "system" then .out = system_line($r)
				elif $r.type == "attachment" then .out = attachment_line($r)
				else .out = "\n_[record type: \($r.type // "untyped")]_\n"
				end;
			.out | select(. != ""))
	'
}

# Offloaded output is left as a marker by the renderer so that reading it from
# disk stays here, where a missing file can be reported plainly.
{
	echo "# Session ${session_id}"
	echo
	echo "_Rendered from $(basename -- "${session}")_"
	render
} | awk -v expand="${expand_offloaded}" -v token="${offload_token}" -v root="${offload_root}" '
	# A control line is "<token> <size> <path>". The token is random per run, so
	# transcript text cannot forge one, and the path must still sit under the
	# tool-results directory of this session before anything opens it.
	$1 == token {
		size = $2
		path = substr($0, length(token) + length(size) + 3)
		if (substr(path, 1, length(root)) != root) {
			print "\n_[ignored an offload reference pointing outside " root "]_"
			next
		}
		if ((getline probe < path) < 0) {
			print "\n_[offloaded output not found at " path "]_"
		} else {
			close(path)
			if (expand == 1) {
				print "\n<!-- offloaded output: " path " (" size " bytes) -->\n"
				print "```"
				while ((getline l < path) > 0) print l
				close(path)
				print "```"
			} else {
				print "\n_[full output offloaded to " path " (" size " bytes); re-run with --expand-offloaded to inline it]_"
			}
		}
		next
	}
	{ print }
'
