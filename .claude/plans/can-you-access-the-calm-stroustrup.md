# Plan: write the `read-claude-code-session-traces` skill

## Context

`claude-code-jsonl-schema-CORRECTED.md` documents the Claude Code JSONL
transcript format, verified against real files. That knowledge is currently a
one-off document: nothing loads it when someone actually wants to read a trace,
and the useful `jq` incantations are buried in prose.

This turns it into a skill at
`.claude/skills/read-claude-code-session-traces/` — so that when anyone asks
"what happened in that session", "what did this cost", or "find where I did X",
the right method and working tooling load automatically.

Traces can be large (single sessions run to megabytes), so the skill uses `rg`
to narrow and `jq` to stream, avoiding a slurp of the full transcript.

Decisions already made with the user:

- **Four jobs**, one script each: index, transcript, search, audit.
- **Explicit path only.** Every script takes its trace directory or session
  file as a required argument. No auto-discovery.
- **No corpus statistics in the skill.** The reference describes types and
  fields qualitatively. Counts from one machine are not facts about the format.

This revision incorporates `plan-review.md`. Every point it raised was checked
against the corpus and confirmed, including three that change the design:
one session file genuinely has **no** `cost-state`; parallel tool calls reach
**six** `tool_use` blocks in a single response, so elapsed-time subtraction
overlaps; and MCP tools return an **array** `toolUseResult`, a third JSON type
beyond object and string.

## Deliverable

```text
.claude/skills/read-claude-code-session-traces/
├── SKILL.md                  # workflow + the gotchas that change what you do
├── references/
│   └── schema.md             # full field reference, read on demand
└── scripts/
    ├── index.sh              # what sessions exist
    ├── transcript.sh         # what happened in one session
    ├── search.sh             # find a string across sessions
    └── audit.sh              # cost, tokens, tool usage
tests/read_traces_test.sh     # fixture tests, wired into make test-unit
```

## SKILL.md

Frontmatter — note `compatibility`, because all four scripts hard-depend on
external binaries:

```yaml
name: read-claude-code-session-traces
description: >-
  Read, summarise, search and cost-account Claude Code JSONL session
  transcripts. Use whenever the user asks what happened in a past session,
  wants a conversation rendered readable, wants to find something across their
  session history, asks what a session cost or how many tokens it used, or
  points at a .jsonl transcript or a ~/.claude/projects-style trace directory
  — even if they never say "transcript" or "JSONL".
compatibility: Requires bash, jq and rg on PATH.
```

Body (~180 lines, well under the 500-line guide):

1. **Pick the script that matches the question** — a four-row table so the
   common case is one command.
2. **The six things that change what you do.** Only facts that make a naive
   reading wrong:
   - `assistant` records hold one content block each in observed versions.
     Group by `requestId` to reassemble a response and count its `usage` once.
     Summing every row overcounts tokens; keeping only the last row loses
     content. Iterate every element of `message.content` anyway — the format is
     undocumented and a future record may carry several.
   - **`cost-state` is the cost record.** Read the last one in the file. Do not
     recompute from token prices. It can be absent, and it covers models the
     transcript never logs, so transcript-summed tokens are a lower bound.
   - **`input_tokens` is a placeholder.** Observed prompt size is
     `cache_read_input_tokens + cache_creation_input_tokens`.
   - **`session_id` ≠ `sessionId`.** `sessionId` is this session; `session_id`
     is the lineage root shared by every session resumed from it. Use
     `index.sh` to see the grouping, then render each member separately —
     `transcript.sh` is deliberately file-local (see §Scripts).
   - **`toolUseResult` is an object, a string, *or* an array** for the same
     tool name. Branch on JSON type before indexing.
   - **A file can be appended to while you read it.** Skip unparseable lines
     with a warning; never abort a whole report for one partial final line.
3. **Efficiency rules** — `rg` first to find candidate lines, `jq` second to
   parse only those; `jq -n 'reduce inputs as $r (…)'` to stream a file;
   never `jq -s` on a multi-megabyte transcript.
4. **Writing your own query** — a few working one-liners, then a pointer to
   `references/schema.md`.
5. **Reporting to the user** — summarise, quote the evidence, name the session
   and turn it came from.

## references/schema.md

Adapted from `claude-code-jsonl-schema-CORRECTED.md`, with all corpus-specific
counts removed and a table of contents (it will exceed 300 lines):

- On-disk layout: `<sessionId>.jsonl`, `<sessionId>/subagents/`,
  `<sessionId>/tool-results/`.
- Record types split into **chain-participating** (`user`, `assistant`,
  `system`, `attachment`) and **session bookkeeping** (`mode`,
  `permission-mode`, `ai-title`, `agent-name`, `atis-latch`, `last-prompt`,
  `cost-state`, `file-history-snapshot`, `file-history-delta`,
  `queue-operation`) — the latter keyed by `sessionId`, last-write-wins.
- Envelope, `message`, `usage`, content-block types, `attachment.type` and
  `system.subtype` variants.
- Tool-call linkage, the three `toolUseResult` JSON types, the offload
  mechanism.
- Chain reconstruction, branches, and why file order is normally usable.
- Subagent files and the `meta.json` → `toolUseId` join.
- A "treat every field as optional" note.

## Scripts

Shared conventions, copied from `scripts/sbxagent`: `#!/usr/bin/env bash`,
`set -euo pipefail`, tabs, a `die()` helper, `SELF="$(basename "$0")"`, usage on
`-h` or a missing argument, and a `command -v jq rg` dependency check that dies
naming the missing binary.

All four skip unparseable lines, warn once to stderr with a count, and continue.

### `index.sh <trace-dir>`

One row per top-level session file. Columns and their exact rules:

| Column | Rule |
| --- | --- |
| `session` | filename stem |
| `title` | last `ai-title.aiTitle`; else last `agent-name.agentName`; else `-` |
| `start` | timestamp of the **first chain record** (not `cost-state.startTime`, which can be absent) |
| `span` | last chain timestamp − first, in `jq` |
| `prompts` | count of `user` records whose `message.content` is a **string** — i.e. typed human turns |
| `cost` | last `cost-state.totalCostUSD`; `-` if no `cost-state` |
| `lineage` | `session_id` if it differs from `sessionId`, else `-` |

**Ordering is a single deterministic key:** group by lineage root (a session
with no `session_id` is its own group); order groups by the group's earliest
`start`; order members within a group by `start` ascending. Missing values
render as `-` and sort last.

### `transcript.sh <session.jsonl> [flags]`

**Branch policy — the correction that matters most.** A file can hold several
leaves, so rendering in raw file order would interleave mutually exclusive
history as one conversation. Instead:

1. Pass one: stream the file building a compact index of chain records only —
   `uuid → {parentUuid, line-number}` — plus the set of leaf uuids. Record
   bodies are not retained.
2. Default leaf is the **last chain record in the file**. `--leaf <uuid>`
   selects another; `--list-leaves` prints candidates with their timestamps and
   exits.
3. Walk `parentUuid` from the chosen leaf to the root, collecting line numbers,
   guarding against cycles and dangling parents.
4. Pass two: stream the file again, render only lines on that path, in file
   order.

Emit an assistant header only when `requestId` changes **and that id has not
been seen before** — contiguous runs are a file-order optimisation observed in
practice, not a format guarantee, so a reappearing id must not open a second
turn.

Flags: `--leaf`, `--list-leaves`, `--thinking`, `--attachments`,
`--expand-offloaded`, `--no-tools`.

### `search.sh [-e|--regex] <trace-dir> -- <pattern>`

- **Literal by default** (`rg -F`); `--regex` switches to rg regex syntax. The
  pattern comes after `--`, so a leading dash is safe.
- Paths are never parsed out of rg output. The script enumerates candidate
  files itself and runs `rg -n` per file, so a colon or space in a path cannot
  corrupt the hit list.
- **One hit = one matching JSONL record.** Excerpts are decoded from the JSON
  string by `jq`, not printed raw.
- Default scope: top-level session files, chain record types only. Flags:
  `--all-types` (include bookkeeping), `--include-subagents`,
  `--include-offloaded` (also grep `tool-results/*.txt`).
- Output: session, timestamp, record type, uuid, excerpt.

### `audit.sh <trace-dir|session.jsonl> [--include-subagents]`

**Cost.** Last `cost-state` per session; per-model breakdown from `modelUsage`.

- Directory mode considers **top-level `*.jsonl` only** for per-session cost.
- A session with no `cost-state` renders `cost: unavailable` and does **not**
  abort the run. This is real: a file in the reference corpus has none, and
  subagent files never do.
- Only an unreadable or non-JSONL input is a fatal error.

**Tools.** Tally by name, with failure count and duration:

- **Failure is exactly `tool_result.is_error == true`** on the linked result,
  absent treated as false. Error text inside stdout is not a failure signal.
- **Per-call duration is elapsed wall time** — linked `tool_result` record
  timestamp minus `tool_use` record timestamp — and is labelled as such.
  Parallel calls (observed up to six `tool_use` blocks in one response) overlap,
  so these are **not summed** into a session figure.
- `cost-state.totalToolDuration` is reported separately as the authoritative
  session total, with no attempt to apportion it per tool.
- Where a tool reports its own duration (`toolUseResult.durationMs`, e.g.
  WebFetch), prefer it and mark it as measured rather than elapsed.
- Subagent tool calls are excluded unless `--include-subagents`.

### Offloaded tool output

`persistedOutputPath` is absolute and recorded from the writing environment,
so it must not be used literally or appended to the trace directory. Resolve it
as:

```text
dirname(session.jsonl)/<sessionId>/tool-results/basename(persistedOutputPath)
```

Verified against the reference corpus: both offloaded files resolve correctly
this way. Validate with `[ -f ]`; if missing, fall back to the inline preview
and say so. `transcript.sh` shows the preview plus the resolved path and byte
size by default — inlining megabytes would defeat a readable transcript —
and only inlines the full file under `--expand-offloaded`.

### Portability and lint

- **All time arithmetic in `jq`**, never `date`: `date -d` is GNU-only and
  `date -j -f` is BSD-only, which `AGENTS.md` forbids. Timestamps carry
  milliseconds, which `fromdateiso8601` rejects, so the idiom is
  `sub("\\.[0-9]+Z$";"Z") | fromdateiso8601` — verified working.
- **bash 3.2 floor**: no `declare -A`, `mapfile`, `${var,,}`, or bare
  `"${arr[@]}"` on a possibly-empty array under `set -u`.
- `make lint` runs `shellcheck --enable=all` on tracked `*.sh`, skills included
  (only markdownlint and cspell skip `**/skills/**`). Satisfy the optional
  checks (`SC2250`, `SC2312`) rather than blanket-disabling; any
  `# shellcheck disable=` names the code and says why, as
  `scripts/publish-kit.sh` does.
- `--slurpfile` for the tool-result map does load that map into memory. That is
  a bounded tradeoff and is fine, but the map stores offloaded output by
  reference, never by value.

## Tests

`tests/read_traces_test.sh`, added to the `test-unit` target in `Makefile`
alongside `sbxagent_test.sh` and `mount_state_test.sh`, following their style
(self-contained temp dir, assertion helpers, cleanup trap).

It builds small synthetic JSONL fixtures and asserts **exact output and exit
status**, not just "no crash". Fixtures cover:

- repeated `requestId` blocks — usage counted once, blocks concatenated into
  one turn; plus a non-contiguous reappearance that must not open a second turn;
- a branched `parentUuid` chain — default leaf, `--leaf`, `--list-leaves`;
- a dangling `parentUuid` and a cycle — neither may hang or crash;
- `toolUseResult` as object, string, and array;
- missing fields, unknown `type`, unknown content-block type;
- no `cost-state`, and multiple `cost-state` records (last wins);
- lineage siblings and their ordering in `index.sh`;
- offloaded output present and missing;
- a subagent file plus its `meta.json` join;
- an unparseable trailing line (simulating a live append);
- search patterns with regex metacharacters and a leading dash, and a trace
  directory whose path contains a space and a colon.

## Verification

1. `python3 .claude/skills/skill-creator/scripts/quick_validate.py .claude/skills/read-claude-code-session-traces`
2. `bash tests/read_traces_test.sh`, then `make test-unit`. Also run it under
   `/bin/bash` when present, mirroring CI's macOS bash-3.2 gate.
3. Explicit lint over the new files — **required, because `make lint` finds
   shell scripts via `git ls-files` and will silently skip untracked ones**:
   ```bash
   shellcheck --enable=all .claude/skills/read-claude-code-session-traces/scripts/*.sh tests/read_traces_test.sh
   bash -n .claude/skills/read-claude-code-session-traces/scripts/*.sh tests/read_traces_test.sh
   markdownlint-cli2 .claude/skills/read-claude-code-session-traces/**/*.md
   ```
   Then `git add -N` the new paths and run `make lint` so the repo-wide check
   actually covers them. (markdownlint/cspell skip skills by design; run
   markdownlint directly as above.)
4. Integration run against the real corpus, checking the three things fixtures
   cannot:
   ```bash
   T=/Users/lars/.local/state/sbxagent/traces/sbxagent-9df4f2fe/sbxclaude/projects/-Users-lars-Code-sbxagent
   S=.claude/skills/read-claude-code-session-traces/scripts
   "$S"/index.sh "$T"                      # eight siblings grouped under one root
   "$S"/transcript.sh "$T"/e988898f-*.jsonl
   "$S"/search.sh "$T" -- 'make lint'
   "$S"/audit.sh "$T"                      # 3b8059d6 shows cost: unavailable
   ```
   Assert `audit.sh`'s cost for a session equals its last `cost-state` read
   directly, and that a known multi-block response renders as one turn.
5. Failure paths: missing argument, nonexistent path, a directory with no
   `.jsonl` files, and a truncated file — each must die with a clear message
   and a non-zero status, not a cascade of `jq` errors.

## Out of scope

- Changing `claude-code-jsonl-schema-CORRECTED.md` — the skill's reference is a
  derived, generalised copy; the report stays as the evidence-backed original.
- Other agents' trace formats (Codex, Cursor, Pi) — `docs/traces.md` covers
  those; this skill is Claude Code only, as its name says.
- Auto-discovering trace directories — explicitly ruled out by the user.
- `make validate` — nothing here touches `kits/*/spec.yaml` or `kits/*/files/`.
- A `CHANGELOG.md` entry: a development-agent skill is not a user-facing change
  to the shipped kits, and `AGENTS.md` says to skip those.
- Any git commit or push (per `AGENTS.md`, the user does those). `git add -N`
  in step 3 only makes the files visible to `git ls-files`; it stages no
  content.
