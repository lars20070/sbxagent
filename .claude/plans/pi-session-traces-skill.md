# Plan: `read-pi-session-traces` skill

## Context

This repo already ships a skill, `read-claude-code-session-traces`, that lets
a coding agent efficiently explore Claude Code's own JSONL session traces
(list sessions, render one as readable markdown, grep across all of them,
and account for cost/tokens) without ever slurping a huge file into context.

`sbxpi` (this repo's wrapper for the "Pi" coding agent,
github.com/earendil-works/pi) writes its own session traces in a different
on-disk format, to a different path
(`~/.local/state/sbxagent/traces/<slug>-<hash>/sbxpi/sessions/--<escaped-cwd>--/<timestamp>_<id>.jsonl`,
documented in `docs/traces.md`). No tooling in this repo currently reads Pi's
trace *content* — only the Claude skill exists. The user wants a sibling
skill, `read-pi-session-traces`, giving the same exploration power for Pi
traces, built the same way `skill-creator` prescribes and structurally
mirroring the Claude skill where Pi's format actually matches it — but not
where it doesn't.

**This plan was independently reviewed and revised.** The first draft relied
on public docs fetched from Pi's `main` branch and one 18-line real trace
file, which produced several wrong or incomplete claims. Every claim below
has now been checked against the *exact pinned version this repo actually
runs* (`@earendil-works/pi-coding-agent@0.84.4`, tag `v0.84.4`, commit
`b79e4cc834970cca69daebffab7df1da7d1e52c4`, confirmed via
`kits/sbxpi/spec.yaml:554` and cross-checked against the npm registry's
`gitHead` for that version). Where a fact differs between the pinned version
and current `main`, both are stated explicitly.

## Compatibility scope

**Baseline: Pi `0.84.4` (tag `v0.84.4`).** This is what `sbxpi` actually
installs and what any real trace file on this machine was written by. All
"confirmed" claims below are checked against this exact tag unless marked
otherwise.

Known additions on `main` (currently `0.87.1`) that do **not** exist at
`0.84.4` and will not appear in a real trace from this repo's sandboxes,
unless `PI_VERSION` in `kits/sbxpi/spec.yaml` is bumped later:
- A top-level `UsageEntry` (`type: "usage"`, with its own `kind`/`provider`/
  `model`/`usage`/`note` fields) — added after 0.84.4, exact version
  unconfirmed by changelog text but present on `main`
  ([`session-manager.ts` on `main`](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/src/core/session-manager.ts)).
- A `ContextEditEntry` (`type: "context_edit"`) — added in **0.87.0**, per
  [`CHANGELOG.md`](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/CHANGELOG.md):
  "Added `ContextEditEntry` to the exported `SessionEntry` union."
- `CompactionEntry.systemMessage` — added in **0.86.0**, per the same
  changelog: "Added transcript-backed mid-conversation system prompt and
  tool changes... see [Entry Types](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/session-format.md#entry-types)."
- `packages/coding-agent/docs/message-types.md` — a `main`-only doc; does
  not exist at `0.84.4` (the message-shape facts below come from reading the
  actual `0.84.4` source directly instead).

**Policy:** every script must treat an entry `type` or message `role` it
doesn't recognise as safe, generic, forward-compatible input (render a
clipped placeholder, never error) — this already covers all three additions
above without special-casing them for *rendering*. `audit.sh` gets one
explicit, deliberate exception: it recognises a top-level `usage` entry
defensively for **cost/token counting only**, since if one ever appears it
represents real, uncounted spend — see the `audit.sh` section.

## What we know about Pi's trace format

**Path** (already documented in `docs/traces.md`, unchanged from the first
draft):
```
~/.local/state/sbxagent/traces/<slug>-<hash>/sbxpi/sessions/--<escaped-cwd>--/<timestamp>_<id>.jsonl
```
`sbxpi name` (the shared `name` subcommand in `scripts/sbxagent`, confirmed
present) prints `sbxpi-<slug>-<hash>` — drop the `sbxpi-` prefix to get the
state folder. If `XDG_STATE_HOME` is set to an absolute path, the tree lives
there instead of `~/.local/state` — `docs/traces.md` already documents this
override; `SKILL.md`'s path template must mention it too, not just the
default.

**Sources**, all re-checked at the pinned tag unless marked `[main]`:
- [`packages/coding-agent/docs/session-format.md`](https://github.com/earendil-works/pi/blob/v0.84.4/packages/coding-agent/docs/session-format.md) — prose overview of the on-disk format, tree structure, `buildContextEntries`/`buildSessionProjection`.
- [`packages/coding-agent/docs/json.md`](https://github.com/earendil-works/pi/blob/v0.84.4/packages/coding-agent/docs/json.md) — **this documents the live `pi --mode json` RPC/event stream over stdout (`agent_start`, `message_update`, etc.), not the persisted `.jsonl` session file.** It is only useful here for the session-header shape, which the live stream's first line also emits. Do not cite it as a source for message/entry shapes.
- [`packages/coding-agent/src/core/session-manager.ts`](https://github.com/earendil-works/pi/blob/v0.84.4/packages/coding-agent/src/core/session-manager.ts) — `SessionHeader`, `SessionEntryBase`, and all `SessionEntry` variants except the message/content shapes themselves (those live elsewhere, below).
- [`packages/ai/src/types.ts`](https://github.com/earendil-works/pi/blob/v0.84.4/packages/ai/src/types.ts) — the real `UserMessage`/`AssistantMessage`/`ToolResultMessage`/content-block (`TextContent`/`ThinkingContent`/`ImageContent`) definitions. **`session-manager.ts` only imports these; it does not define them.**
- [`packages/coding-agent/src/core/messages.ts`](https://github.com/earendil-works/pi/blob/v0.84.4/packages/coding-agent/src/core/messages.ts) — the `BashExecutionMessage` and `CustomMessage` roles, which extend the base `Message` union at the agent level.
- [`packages/coding-agent/src/core/tools/bash.ts`](https://github.com/earendil-works/pi/blob/v0.84.4/packages/coding-agent/src/core/tools/bash.ts) — the agentic `bash` tool's `BashToolDetails` (`truncation`, `fullOutputPath`).

Plus one real sample file (18 lines: 1 header, 1 `model_change`, 1
`thinking_level_change`, 15 `message`, all one strictly linear chain, no
branching/compaction/fork) at
`/Users/lars/.local/state/sbxagent/traces/sbxagent-9df4f2fe/sbxpi/sessions/--Users-lars-Code-sbxagent--/2026-09-17T09-32-45-253Z_01a0aeb6-1b45-7013-ab4d-5454a1b5680f.jsonl`.

**Confirmed facts** (revised from the first draft — corrections marked):

- Line 1 is a header: `{"type":"session","version":3,"id":"uuid","timestamp":"...","cwd":"/path","parentSession"?}`. **The header is not a tree node** — it has no `parentId` at all, unlike every real entry. *(Correction: the first draft's "every line is a tree node" conflated the header with the entries that follow it. All tree/timing/leaf logic must explicitly exclude `.type == "session"`, not just "not add a filter".)*
- Every entry after the header has `type`, `id`, `parentId` (nullable — root entries have `parentId: null`), `timestamp` — and every entry type, including `custom`/`session_info`/`model_change`, participates in this tree. This part of the original claim holds; it's the header that's the exception, not the rule.
- `message` entries wrap a `Message` (from `packages/ai`) whose `role` is `user` / `assistant` / `toolResult`, **plus two agent-level extension roles, `bashExecution` and `custom`** (from `messages.ts`), which real trace files can contain (the `!` bash-command shortcut and custom extensions produce these). *(Correction: the first draft only accounted for 3 roles.)* Treat `bashExecution`/`custom` with a safe generic render, same as any other type we don't have a dedicated renderer for.
- `UserMessage.content` is **`string | (TextContent | ImageContent)[]`** — a plain string is valid, not just an array. *(Correction: the first draft asserted "always an array" from the one sample, which happened to only contain the array form.)* Every place that reads `.message.content` must handle both shapes.
- `AssistantMessage.content` is `(TextContent | ThinkingContent | ToolCall)[]`, plus sibling fields `api`, `provider`, `model`, `usage`, `stopReason`, `responseId` on `.message` itself.
- `ThinkingContent` is confirmed: `{type: "thinking", thinking: string, thinkingSignature?: string, redacted?: boolean}`. *(Correction: the first draft called this "unconfirmed" — it's real, at the pinned version.)* Render `.thinking` text; never print `thinkingSignature`; if `redacted` is true, render a placeholder instead of the text, mirroring how the Claude Code sibling skill treats redacted thinking.
- `ImageContent` is confirmed: `{type: "image", data: <base64>, mimeType: string}`. *(New — the first draft didn't cover image blocks at all.)* **Never render `data`.** Show `mimeType` and an approximate size (`(data length / 4) * 3` bytes, or just the base64 char count) instead.
- `ToolResultMessage` is `{role: "toolResult", toolCallId, toolName, content: (TextContent|ImageContent)[], details?, usage?: Usage, addedToolNames?, isError, timestamp}`. **`usage` is a real, optional field** representing "usage from the tool execution itself... not part of main LLM context accounting" (source comment) — e.g. a tool that itself calls a model. *(Correction: the first draft said only assistant/compaction/branch_summary can carry usage; tool results are a fourth source and must be summed too, kept in a separate bucket since the source explicitly says it's not part of main context accounting.)*
- **Tool results are not always fully inline.** The agentic `bash` tool's result can carry `details: {truncation?: {truncated: boolean, ...}, fullOutputPath?: string}`, and a `bashExecution` message (the `!`-prefix shortcut) has its own top-level `truncated: boolean` / `fullOutputPath?: string` fields. *(Correction: the first draft's "tool results are always inline, no offload mechanism" was disproven by these two real, pinned-version fields — this was a load-bearing simplification that justified deleting all offload-awareness from `transcript.sh`; that deletion must be partially undone.)* There is still no *generic* Pi-wide sidecar convention the way Claude Code has one for every tool — only these two specific message shapes carry a truncation/path pair.
- Cost/token usage's exact real shape (on `message.usage` for assistant entries, unchanged from the first draft): `{input, output, cacheRead, cacheWrite, reasoning, totalTokens, cost: {input, output, cacheRead, cacheWrite, total}}`. **Use `totalTokens` as given; never recompute it by summing `input + output + reasoning` yourself** — the review flagged a real risk of double-counting `reasoning` if it's already folded into `output`/`totalTokens` upstream, and Pi doesn't document the inclusion relationship anywhere accessible. Report `reasoning` purely as an informational breakdown figure, not as an addend.
- **There is no single authoritative session-total cost record**, and now there are *four* possible carriers of `usage`/`usage.cost` per entry, not three: `message` (assistant role), `message` (toolResult role, its own separate bucket), `compaction`, `branch_summary`. A reader must sum across all of them; missing any one undercounts.
- Two different timestamp shapes coexist: the entry-level ISO-with-millis `timestamp` (use for ordering/diffing), and a *nested* `message.timestamp`, which is raw epoch **milliseconds** (unchanged from first draft).
- **Fork and continue are precisely defined, not unconfirmed** (this is the biggest correction). `SessionHeader.parentSession` is confirmed present at `0.84.4`. The fork/continue *implementation* was verified against current `main` (commit `8562bcf`, functions `SessionManager.forkFrom`/`continueRecent`) — the field's purpose and shape are stable back to `0.84.4`, though the literal implementation line numbers weren't separately re-diffed against the old tag:
  - **Continue (`pi -c`) reopens the same file.** No new file, no `parentSession` involved.
  - **Fork (`pi --fork <path>`) creates a brand-new file, writes a header whose `parentSession` is the source file's resolved path, and then physically copies every non-header entry from the source file into the new file.** `parentSession` is always a file path in every code path that sets it — never a bare session id.
  - **Consequence 1:** a forked child file already contains a full copy of its parent's history up to the fork point. `transcript.sh` staying file-local (as designed) is correct and does not double-render anything. But `index.sh`'s lineage display must say "forked from" and make clear the child is a *copy*, not a continuation, so a user doesn't expect `transcript.sh` on the parent-then-child to read like one continuous conversation with no overlap.
  - **Consequence 2:** summing `audit.sh` over every file in a directory **double-counts** any cost that was copied into a fork. This must be a documented, explicit caveat, not solved via automatic deduplication (out of scope — see Known limitations).
- Pi's own reader tolerates malformed lines: `parseSessionEntryLine()` wraps `JSON.parse` in a try/catch and silently drops any line that fails to parse — **whether or not it's newline-terminated** — rather than treating a complete-but-malformed line as a hard error. It also self-heals a missing trailing newline by appending one. *(This directly informs `common.sh`'s `feed()` — see below: our reader should warn-and-skip on any unparseable line, matching Pi's own tolerance, not hard-fail on a complete-but-malformed one.)* The writer does always build each line as `` `${JSON.stringify(entry)}\n` `` in a single call, so the *design intent* is that every complete line is well-formed and LF-terminated; only a crash mid-write produces a genuine partial tail.
- Pi's own `buildContextEntries()`/`buildSessionProjection()` (in `session-manager.ts`) reconstruct "what the model actually saw" by walking leaf→root, folding compaction, and (on `main`, via `context_edit`) applying replacements/omissions — which is **not** the same thing as a raw root-to-leaf dump of every stored entry. Re-implementing this projection in `jq`/`awk` is out of scope for this skill's first version (see Known limitations); `transcript.sh` renders the **raw stored history**, annotated at compaction boundaries, and must say so plainly rather than imply it equals model-visible context.
- `CustomMessageEntry` and `LabelEntry` (both `session_info`-adjacent bookkeeping-ish types) are fully specified at `0.84.4`, contrary to the first draft's "fields not fully captured" hedge — that hedge was a limitation of an earlier lookup, not a real gap in Pi's schema:
  ```ts
  export interface CustomMessageEntry<T = unknown> extends SessionEntryBase {
    type: "custom_message";
    customType: string;
    content: string | (TextContent | ImageContent)[];
    details?: T;
    display: boolean;
  }
  export interface LabelEntry extends SessionEntryBase {
    type: "label";
    targetId: string;
    label: string | undefined;
  }
  ```
  They're still marked "documented, not observed in real sample data" in `schema.md` — that part of the hedge stands; only the "fields uncertain" part is now resolved.
- `compaction`, `branch_summary`, `custom`, `session_info` remain undocumented-in-practice (never appeared in the one real sample) but their `0.84.4` TS interfaces are now fully known and unchanged from the first draft's quotes (no `systemMessage` field on `CompactionEntry` at this pin — that's `main`-only, see Compatibility scope above).

## Design decision: keep 4 scripts, same question-shaped split

Unchanged from the first draft and not disputed by the review: mirror the
Claude skill's script split — `index` / `transcript` / `search` / `audit` —
because each answers a genuinely different question needing a different
traversal. Pi's format is still simpler than Claude Code's in real ways (no
subagent files, no `requestId` splitting, no chain-vs-bookkeeping divide),
just not as uniformly simple as the first draft assumed (tool-result
truncation and multi-source cost accounting reintroduce some real
complexity). No standalone "lineage" script; folds into `index.sh`.

## Files to create

```
.claude/skills/read-pi-session-traces/
├── SKILL.md
├── references/
│   └── schema.md
└── scripts/
    ├── common.sh
    ├── index.sh
    ├── transcript.sh
    ├── search.sh
    └── audit.sh
```

### `SKILL.md`

Frontmatter: `name: read-pi-session-traces`, a "pushy" `description` (per
`skill-creator`'s guidance) naming Pi/sbxpi triggers explicitly and warning
this is *not* the Claude Code skill, `compatibility: Requires bash, jq and
rg on PATH.`

Body, in order:
1. Opening paragraph: what a Pi trace is; the headline structural facts —
   every entry *after the header* is a tree node (the header itself is not);
   pinned to Pi `0.84.4`, unknown future entry/role/block types are rendered
   safely as generic placeholders rather than erroring.
2. "Start here" table (question → script), the concrete path template
   including the `$XDG_STATE_HOME` override, and a pointer to `sbxpi name`.
3. "What's structurally different from Claude Code's format" — one turn is
   one record (no `requestId` splitting); no single authoritative cost
   record; no generic tool-output sidecar (but see the truncation trap
   below); fork copies history rather than continuing it.
4. Traps section, revised:
   - **The header is not a tree node.** Don't let it show up as a phantom
     leaf or skew a session's start/span timing — exclude `.type=="session"`
     from every tree/leaf/timing computation; read header fields (`id`,
     `cwd`, `parentSession`) separately.
   - **User content can be a plain string, not just an array.** Handle both
     shapes everywhere `.message.content` is read.
   - **Roles beyond user/assistant/toolResult exist** (`bashExecution`,
     `custom`) — render unknown roles generically rather than assuming
     exactly three.
   - **Images are base64 and must never be printed.** Show `mimeType` and
     approximate size only.
   - **Cost/tokens have four possible carriers, not three**: assistant
     `message.usage`, toolResult `message.usage` (a separate "tool's own
     spend" bucket, kept apart from conversation spend), `compaction.usage`,
     `branch_summary.usage`. Miss one and the total undercounts. Use
     `usage.totalTokens` as given — never re-sum `input+output+reasoning`
     yourself, to avoid double-counting `reasoning` if it's already folded
     into the other fields.
   - **Some tool output is truncated with a pointer to the full file**, not
     always inline — the agentic `bash` tool (`details.fullOutputPath`) and
     `!`-command `bashExecution` messages (`fullOutputPath` directly) can
     both do this. Note it; don't assert the JSONL always has the complete
     output.
   - **A session can span multiple files via `parentSession`** — but a
     forked file is a **copy** of its parent's history up to the fork point,
     not a continuation. Rendering parent-then-child duplicates content;
     summing cost across a directory containing a fork **double-counts** the
     copied prefix. `audit.sh` and `index.sh` both call this out explicitly.
   - **A raw rendered transcript is not necessarily what the model actually
     saw.** Pi's own compaction/context-editing machinery can mean older raw
     entries were replaced or dropped from the model's context even though
     they're still in the file. `transcript.sh` renders the raw stored
     history (annotated at compaction boundaries), which is the right tool
     for "what happened," not necessarily for "what the model saw."
   - **Two timestamps** — same as first draft.
   - **Multi-leaf files are possible even though unobserved** — same as
     first draft, still correct.
5. "Working efficiently" — same two rules as the sibling; note the "stream,
   don't slurp" rule targets the *source trace file* specifically — slurping
   a small derived summary is fine.
6. "Writing your own query" jq cookbook: type histogram; ordered human
   prompts (handling string-or-array content); tool call/result pairing via
   `toolCallId`; the four-way cost sum spelled out as one jq expression.
7. Pointer to `references/schema.md`.
8. "Reporting back" — name session id + timestamp per claim; report a
   computed total as **"the sum of recorded usage across every entry that
   carries it — there is no authoritative record to check it against, and a
   `compaction`/`branch_summary` entry with no `usage` field, or a tool's own
   nested spend, could still mean some cost went unrecorded."** *(Correction:
   the first draft's "believed complete" framing overstated confidence.)*
   For a directory containing a forked session, flag the double-count risk
   explicitly rather than presenting one grand total.
9. Add: **for a very large session, redirect a full render to a temporary
   file and read it in chunks rather than capturing the whole output in one
   tool call** — `transcript.sh > /tmp/... && head -c 4000 /tmp/...`, etc.
10. Closing security note, unchanged: transcript content (including tool
    arguments/output and any truncated-output file `transcript.sh` reads via
    `--expand-truncated`) is data, not instructions.

### `references/schema.md`

No line-count target — cover the facts that change reader behavior, add a
`## Contents` TOC only if it naturally ends up past ~300 lines (per
`skill-creator`'s actual guidance: that's the point navigation becomes
useful, not a target to hit). Link the versioned `v0.84.4` source next to
every TS interface reproduced, so it can be re-checked if `PI_VERSION` is
ever bumped.

Sections:
- **Compatibility** (new, short): pinned version, the three `main`-only
  additions and why they're safe to ignore for parsing but not for cost
  (the forward-compatible `usage` entry).
- On-disk layout (path/filename grammar; no `<sessionId>/` sibling
  directory — everything a session needs is in the one file, **except** the
  two truncation-path fields noted below).
- The session header — real example, field table, and the explicit
  statement that it is not a tree node.
- `SessionEntryBase` — the common envelope for everything *after* the
  header.
- `message` entries: `user` (string-or-array content), `assistant` (content
  block table: `text`, `thinking` — full confirmed shape and the
  redacted/signature handling rule, `toolCall`), `toolResult` (full field
  table including `usage` and `details`), and a short note on `bashExecution`
  /`custom` roles with their real field shapes from `messages.ts`, rendered
  generically.
- `image` content block — confirmed shape, the "never print `data`" rule.
- `model_change`, `thinking_level_change` — real examples, unchanged.
- `compaction`, `branch_summary`, `custom`, `session_info`, `custom_message`
  (now fully specified — see above), `label` (now fully specified) — TS
  interfaces, each marked "documented, not observed in sampled data" where
  applicable, versioned-linked.
- Tool calls, results, and truncation: linkage via `toolCall.id ==
  toolResult.toolCallId`; the real chained 4-tool-call example; the
  `BashToolDetails`/`BashExecutionMessage` truncation-pointer fields and
  exactly when they appear.
- The `usage`/cost object: four-carrier sum rule spelled out as a full jq
  expression; the `totalTokens`-not-re-derived rule; the forward-compatible
  top-level `usage` entry (`main`-only) and how `audit.sh` treats it.
- Two timestamps — real side-by-side comparison, unchanged.
- The conversation tree — same 4-step leaf/walk algorithm, explicitly
  starting "from the first entry after the header."
- Raw history vs. model-visible context — short section explaining
  `buildContextEntries`/`buildSessionProjection` exist upstream and why this
  skill deliberately renders raw history instead (see Known limitations).
- Session-to-session lineage via `parentSession` — **confirmed**: always a
  file path, fork copies history. `index.sh`'s resolution logic (below).
- Closing "Unconfirmed / out of scope" list: exact continue/fork line
  numbers not re-diffed against `0.84.4` (only against `main`); whether
  `compaction`/`branch_summary`/`custom`/`session_info` ever appear in
  practice; model-context projection is unimplemented.

### `scripts/common.sh` (sourced only, never executed directly)

Reused from the sibling: `SELF`, `die()`, `warn()`, `require_tools()`,
`need_file()`, `need_dir()`, `list_sessions()`.

Changed:
- `session_id_of()`: strip `<timestamp>_` prefix as well as `.jsonl` suffix.
- `feed()`: **revised for efficiency, not just reused.** Instead of parsing
  the entire last line to detect an incomplete tail (which loads a
  potentially huge final record into a shell variable just to check it),
  check whether the file's last byte is a newline first (`tail -c1`, O(1)):
  if it is, feed the whole file as-is; if it isn't, warn and feed everything
  up to (not including) the last, unterminated line via `sed '$d'` without
  ever holding that line's full content in a shell variable. Any line that
  still fails to parse inside the jq pipeline (complete or not) is a `warn`
  from that script, not a hard `die` — this matches Pi's own tolerant
  reader behavior (confirmed: `parseSessionEntryLine` silently skips
  malformed lines regardless of termination) rather than being stricter than
  the format's own writer/reader.

New:
- `header_of(file)`: `head -n 1 -- "$file" | jq -c .` — warns and returns
  `null` on a bad/missing header line.

Dropped: `subagent_files()` (no subagent transcripts exist in this format).

`JQ_PRELUDE`: keep `epoch`, `hms`, `flat`, `clip($n)`. Drop `is_chain`
(nothing needs it once the header is excluded up front). Add:
- `is_header`: `.type == "session"` — used by every script to skip the
  header line inside a shared reduce/filter, so `header_of()` (cheap,
  separate) is the *only* reader of header fields.
- `entry_cost` / `entry_tokens`: branch on `.type`:
  - `message` with `.message.role == "assistant"` → `.message.usage`
  - `message` with `.message.role == "toolResult"` → `.message.usage`
    (kept in a **separate accumulator**, not merged into conversation cost,
    since the source explicitly says this isn't part of main context
    accounting)
  - `compaction` / `branch_summary` → `.usage`
  - `usage` (forward-compat, `main`-only) → `.usage`, attributed via its own
    `.provider`/`.model` fields
  - anything else → zero
  `entry_tokens` returns the object with `totalTokens` passed through as
  given (never recomputed from parts).
- `is_prompt`: `.type=="message" and .message.role=="user"` with content
  that is either a non-empty string or an array containing a `text` block —
  handles both content shapes.

### `scripts/index.sh`

`Usage: index.sh <trace-dir>` — unchanged CLI.

Same output columns, oldest-first-within-lineage ordering, two-pass awk
column sizing. Per-file streaming reduce now explicitly skips the header
(`is_header`) before accumulating `first`/`last`/`prompts`/`cost`, so a
session's `start`/`span` reflect its first real tree entry, not the moment
the file was created (these can differ by minutes, as the real sample
shows: header at 09:32:45, first tree entry at 09:38:24). `title` falls back
to the first counted prompt's text (clipped), handling string-or-array
content, since there's no `ai-title`-equivalent bookkeeping record.

`lineage`: read once via `header_of()`. **Resolution simplified to
path-based only** (confirmed: `parentSession` is always a file path, never a
bare id) — resolve it relative to the trace directory; if it points outside
the directory or doesn't exist, show the raw value prefixed `external:`.
Label a resolved lineage entry `forked from <session>` rather than implying
continuation, and precompute the whole directory's header→id/parentSession
map in **one pass** before resolving any file's lineage, instead of
re-scanning every sibling's header per session (avoids O(n²) in the number
of files, per the review's scaling concern).

### `scripts/transcript.sh`

```
Usage: transcript.sh [options] <session.jsonl>
  --leaf ID            render the path ending at this record (default: last record in file)
  --list-leaves        list branch endpoints and exit, newest last
  --thinking            include thinking-block text (never signatures; redacted blocks show a placeholder)
  --no-tools            omit toolCall / toolResult content
  --max-result N        clip each tool result to N characters (default 800, 0 = unlimited)
  --max-text N          clip each prose (user/assistant text, summaries) block to N characters (default 4000, 0 = unlimited)
  --expand-truncated    inline the full-output file for a truncated bash/bashExecution result (clipped like everything else)
  --unknown-blocks      include content blocks / message roles this script has no dedicated renderer for
```

Dropped vs. the Claude sibling: `--attachments`, `--expand-offloaded` (no
Claude-style generic offload mechanism exists in Pi).

Pass 1 now explicitly filters `select(.type != "session"; i.e. !is_header)`
before emitting `line,id,parentId,timestamp,type` rows — cheap, and
necessary so the header can't appear as a phantom leaf in `--list-leaves` or
corrupt the walk. Leaf-walk awk unchanged otherwise (renamed `id`/`parentId`).
Pass 2 re-streams only the kept lines.

Renderer per type, revised:
- `message`/`user`: `## User` heading; render content whether it's a plain
  string or an array of `text`/`image` blocks (image → metadata line only).
- `message`/`assistant`: one heading per entry (still no `requestId`
  concept). `text` → prose, clipped to `--max-text`. `thinking` → shown only
  with `--thinking`, `.thinking` text clipped to `--max-text`, never
  `.thinkingSignature`, a placeholder if `.redacted`. `image` → metadata
  line. `toolCall` → labeled fenced block of `name`/`id`/`arguments`.
  Unrecognised block type → placeholder unless `--unknown-blocks`.
- `message`/`toolResult`: labeled fenced block (`toolName`, `toolCallId`,
  error flag), content clipped to `--max-result`. If `details` carries a
  truncation flag and `fullOutputPath`, add a note ("output truncated, full
  text at `<path>`") instead of asserting completeness; with
  `--expand-truncated`, read and inline that file (clipped, treated as
  untrusted data like everything else — never executed).
- `message`/`bashExecution`: dedicated one-line render (command, exit code,
  truncated/full-output-path note, same expand behavior) since the shape is
  fully known.
- `message`/`custom` (the message role, not the entry type): generic
  fallback like any unrecognised type — `_[custom message: <customType>]_`
  plus a clipped `tojson` (with `content` stripped if it contains an image
  block's `data`).
- `model_change` / `thinking_level_change`: one-line italic notes, unchanged.
- `compaction` / `branch_summary`: italic note plus summary text and the
  referenced id, **plus an explicit note that this is a raw-history view —
  older entries before `firstKeptEntryId` may no longer be part of what the
  model actually sees.**
- `usage` (forward-compat) / `context_edit` (forward-compat): small
  dedicated one-liners, since their shapes are known from `main` even though
  unexpected at `0.84.4`.
- `custom` (entry type) / `session_info` / `custom_message` / `label`:
  generic fallback — `_[<type>]_` plus a clipped `tojson`.

### `scripts/search.sh`

```
Usage: search.sh [options] <trace-dir> [--] <pattern>
  -e, --regex        treat pattern as regex (default: literal)
  -i, --ignore-case
  --max-hits N       cap hits reported per session (default 20, 0 = unlimited)
```

Same `rg`-narrows/`jq`-decodes architecture. **Pass `--max-count N` to `rg`
itself when `--max-hits N` is nonzero**, instead of collecting every match in
the file and truncating afterward — bounds the work `rg` does, not just the
output, per the review's scaling concern. `searchable` def extended: handle
string-or-array `message.content`, skip `image` block `data` (never search
into or echo base64), include `bashExecution.output`/`command`.

### `scripts/audit.sh`

```
Usage: audit.sh [options] <trace-dir | session.jsonl>
  --json    emit raw per-session JSON instead of the formatted report
```

Revised accounting: sum `entry_cost`/`entry_tokens` (from `common.sh`,
now four-way plus the forward-compatible `usage` entry) across every
qualifying entry, with the toolResult-`usage` bucket **reported separately**
labeled "tool-execution spend (not part of conversation context)" rather
than merged into the conversation total. Per-model breakdown: assistant
messages attribute to `message.model`/`message.provider`; a forward-compat
`usage` entry attributes to its own `.provider`/`.model`; `compaction`/
`branch_summary`/`toolResult` usage — which carry no model field — go in an
explicit **"unattributed"** bucket rather than being silently dropped or
mis-attributed to whatever model happens to be current.

Tool call/result correlation: build the `toolCallId -> {name, timestamp}`
map incrementally and **delete each entry as soon as its matching
`toolResult` is seen**, so memory is bounded by outstanding (unanswered)
calls rather than growing with the total call count over a whole file — per
the review's scaling concern. Whatever remains in the map at EOF is the
"unanswered call" count. Elapsed time uses entry-level timestamps only,
never the nested `message.timestamp`.

Report framing, corrected: **"the sum of every recorded `usage`/`usage.cost`
field this format defines — not a documented lower bound like Claude Code's,
but not a proven-complete total either, since there is no authoritative
record to check it against and any of the optional `usage` fields could be
absent on a real call."** When run against a directory, add an explicit
warning if any file's header has a `parentSession` pointing at a sibling in
the same directory: **"this total double-counts the copied history a forked
session inherited from `<parent>`; treat directory-wide sums as an upper
bound in that case."** State plainly: `audit.sh` sums each file
independently and does **not** attempt lineage deduplication (see Known
limitations).

## Known limitations (explicitly out of scope for this version)

- **No model-context projection.** `transcript.sh` renders raw stored
  history, not Pi's own `buildContextEntries`/`buildSessionProjection`
  output. A compaction/branch-summary boundary is annotated, not resolved
  into "this is what the model actually received."
- **No automatic fork-cost deduplication.** `audit.sh` sums each file
  independently and flags, but does not fix, double-counted forked history.
- **`main`-only entries are rendered/ignored safely, not fully modeled.**
  `context_edit` and `CompactionEntry.systemMessage` get generic-fallback
  rendering; only the top-level `usage` entry gets bespoke cost handling,
  because ignoring real spend is worse than ignoring an entry type.
- **Reasoning-token inclusion in `totalTokens` is assumed, not proven** —
  this skill reports `totalTokens` as given rather than re-deriving it, to
  avoid a plausible double-count, but has not independently confirmed the
  inclusion relationship from Pi's source.

## Verification

1. `python3 .claude/skills/skill-creator/scripts/quick_validate.py .claude/skills/read-pi-session-traces`.
2. `shellcheck --enable=all .claude/skills/read-pi-session-traces/scripts/*.sh` and `bash -n` on each; run under `bash 3.2` semantics (no associative arrays, no `${var,,}`, etc., matching this repo's portability rules in `AGENTS.md`).
3. **Stage the new files (`git add`) before running `make lint`** — it discovers inputs via `git ls-files`, confirmed in `Makefile`, so untracked scripts are silently skipped otherwise.
4. Run `make lint` at the repo root.
5. Exercise all four scripts against the one real trace file, with **exact** (not "roughly matching") assertions where the raw file makes an exact number computable:
   ```bash
   d=/Users/lars/.local/state/sbxagent/traces/sbxagent-9df4f2fe/sbxpi/sessions/--Users-lars-Code-sbxagent--
   f="$d/2026-09-17T09-32-45-253Z_01a0aeb6-1b45-7013-ab4d-5454a1b5680f.jsonl"
   .claude/skills/read-pi-session-traces/scripts/index.sh "$d"
   .claude/skills/read-pi-session-traces/scripts/transcript.sh "$f"
   .claude/skills/read-pi-session-traces/scripts/search.sh "$d" "sbxagent"
   .claude/skills/read-pi-session-traces/scripts/audit.sh "$f" --json | jq .
   jq -s '[.[] | select(.type=="message" and .message.role=="assistant") | .message.usage.cost.total] | add' "$f"
   ```
   The last two must match exactly, not approximately.
6. Additionally construct a handful of small, hand-written synthetic
   `.jsonl` snippets (not committed as fixtures — throwaway files in the
   scratchpad) to exercise what the one real trace cannot: a header
   followed by two entries branching from the same `parentId` (assert
   `--list-leaves` reports 2, and neither is the header); a file whose last
   line is deliberately cut mid-object with no trailing newline (assert
   `feed()`/every script warns and proceeds rather than crashing, and that
   the O(1) trailing-byte check doesn't false-positive on a valid,
   newline-terminated last record); a plain-string `user` message (assert
   `index.sh`'s prompt count and title fallback both see it).
7. Confirm `transcript.sh` never emits a base64 `data` field, a
   `thinkingSignature`, or an unclipped block regardless of flags.

**Not building, pending your input (see below): a committed, generated
synthetic-fixture test suite with exhaustive exact-JSON assertions** (the
kind of thing under a `tests/` directory with generated `.jsonl` files
covering every entry/role/block combination, run under CI). The sibling
Claude skill shipped with no such suite, and none of this repo's existing
`tests/*.sh` cover skill *scripts* (they test the wrapper/mount mechanics).
Building one now would be a real scope increase beyond matching the
sibling's bar. Step 6 above gets meaningful coverage cheaply without it.

## Repository integration

- Add an `Added` entry under `CHANGELOG.md`'s `## [Unreleased]` section,
  following the exact precedent of the `0.4.9` entry for
  `read-claude-code-session-traces`.
- Stage the new skill's files with `git add` (needed for lint, see above,
  and per this repo's normal workflow); do **not** run `git commit` or
  `git push` — per `AGENTS.md`, hand the user a draft commit message instead.

## Follow-up (not part of this task, mentioned to the user)

Now that thinking/image/`bashExecution` shapes are confirmed from source,
the main remaining unknowns are things only a *new real trace* can show:
whether `compaction`, `branch_summary`, `custom`, `session_info` actually
appear in practice and render sensibly, and whether a real `pi --fork`/
`pi -c` session behaves exactly as the source code implies. If you want to
firm these up later, running a long/complex session (to trigger compaction)
and a forked session would let this skill's schema doc and scripts be
revisited against new real data. Not required to ship the skill now.
