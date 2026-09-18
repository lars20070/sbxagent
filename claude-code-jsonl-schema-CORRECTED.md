# Claude Code JSONL Transcript Format

A schema reference derived entirely from direct observation of real transcript
files. Every claim below was measured; the `jq`/`python3` command that produced
each number is given so it can be re-run.

## 1. Scope

Corpus examined:

```text
/Users/lars/.local/state/sbxagent/traces/sbxagent-9df4f2fe/sbxclaude/projects/-Users-lars-Code-sbxagent/
```

| Property | Value |
| --- | --- |
| Main session files | 15 (`<sessionId>.jsonl`) |
| Total lines | 5092 |
| Subagent transcripts | 7 (`<sessionId>/subagents/agent-<id>.jsonl`) |
| Offloaded tool outputs | 3 (`<sessionId>/tool-results/<id>.txt`) |
| Date range | 2026-09-15 to 2026-09-18 |
| Claude Code versions | `2.1.246`, `2.1.272`, `2.1.273` |
| Models | `claude-opus-5`, `claude-sonnet-5` (and `claude-haiku-4-5-20251001`, see §8) |
| Entry point | `cli` only |

**What this bounds.** Everything here is true of Claude Code 2.1.246–2.1.273
transcripts written by the CLI. It says nothing about earlier versions, other
entry points (desktop, web, SDK), or features this corpus never exercised — see
§13 for the explicit list of what was not observed.

One session file was excluded from all counts because it was being appended to
while the measurements ran. Work from a copy:

```bash
SNAP=/tmp/corpus && rm -rf "$SNAP" && mkdir -p "$SNAP"
cp -R .../projects/-Users-lars-Code-sbxagent/. "$SNAP"/
find "$SNAP" -name .DS_Store -delete
```

## 2. On-disk layout

```text
projects/<encoded-project-path>/
├── <sessionId>.jsonl                     # the session transcript
├── <sessionId>/
│   ├── subagents/
│   │   ├── agent-<agentId>.jsonl         # one subagent's full transcript
│   │   └── agent-<agentId>.meta.json     # who spawned it, and why
│   └── tool-results/
│       └── <id>.txt                      # tool output too large to inline
```

- The filename UUID always equals the `sessionId` field on every record in the
  file. Verified across all 15 files, zero mismatches.
- `<encoded-project-path>` is the working directory with non-alphanumeric
  characters replaced by `-`, e.g. `/Users/lars/Code/sbxagent` →
  `-Users-lars-Code-sbxagent`.
- The `<sessionId>/` sibling directory is created only when the session
  actually spawns subagents or offloads a large tool result. 5 of 15 sessions
  here have one.

```bash
# filename == sessionId check
for f in *.jsonl; do b="${f%.jsonl}"
  jq -r --arg b "$b" 'select(.sessionId != null and .sessionId != $b) | .sessionId' "$f"
done | sort -u   # empty output == all match
```

## 3. Record types

Every line is one self-contained JSON object with a `type` discriminator.
Fourteen types occur in main session files:

| `type` | Count | In chain? | Meaning |
| --- | ---: | :---: | --- |
| `attachment` | 1710 | yes | Context injected into the conversation (reminders, file contents, hook output, mode changes). The most common record by far. |
| `assistant` | 1224 | yes | One content block of a model response. |
| `user` | 744 | yes | A typed prompt, or tool results returned to the model. |
| `mode` | 217 | no | Session mode latch (`normal`, `plan`, `auto`, `default`, `bypassPermissions`). |
| `ai-title` | 215 | no | Background-generated session title. |
| `atis-latch` | 214 | no | Short status string shown in the UI; often `""`. |
| `last-prompt` | 208 | no | Snapshot of the most recent user prompt plus the leaf it belongs to. |
| `permission-mode` | 167 | no | Permission-mode latch. |
| `system` | 124 | yes | System-generated events, discriminated by `subtype`. |
| `file-history-snapshot` | 110 | no | Full file-backup state for undo/rewind. |
| `agent-name` | 69 | no | Human-readable session name. |
| `file-history-delta` | 54 | no | Incremental file-backup update. |
| `cost-state` | 20 | no | Authoritative running cost and token totals. |
| `queue-operation` | 16 | no | Background-task notification enqueue/dequeue. |

Subagent transcripts contain only three of these: `assistant` (281), `user`
(172), `attachment` (43).

```bash
cat *.jsonl | jq -r '.type' | sort | uniq -c | sort -rn
cat */subagents/*.jsonl | jq -r '.type' | sort | uniq -c | sort -rn
```

**"In chain?"** means the record carries `uuid` and `parentUuid` and therefore
participates in the conversation tree (§9). The eight bookkeeping types that do
not are keyed only by `sessionId` and are last-write-wins state, not history.

## 4. The envelope

Records that participate in the chain (`user`, `assistant`, `system`,
`attachment` — 3802 of 5092 lines) share a common envelope. Presence is stated
as a fraction of records of that type.

| Field | Type | Presence | Notes |
| --- | --- | --- | --- |
| `uuid` | string | 100% | Unique id of this record. |
| `parentUuid` | string \| null | 100% | Previous record in the chain; `null` only at the file root. |
| `sessionId` | string | 100% | This session. Always equals the filename. |
| `session_id` | string | 78% | **Not a duplicate** — see below. |
| `timestamp` | string | 100% | ISO 8601 with milliseconds and `Z`. |
| `cwd` | string | 100% | Working directory at write time. |
| `version` | string | 100% | Claude Code version, e.g. `"2.1.273"`. |
| `gitBranch` | string | 100% | Branch at write time. |
| `userType` | string | 100% | `"external"` in every record. |
| `entrypoint` | string | 100% | `"cli"` in every record. |
| `isSidechain` | bool | 100% | `false` in all 3802 main-file records; `true` in all 496 subagent records. |
| `slug` | string | 63% | Human-readable session slug. Present per-session, not per-record. |
| `isMeta` | bool | `system` 100%, `user` 3% | Marks non-conversational injected content. |

### `sessionId` vs `session_id` — a lineage pointer, not a naming slip

These two fields disagree on 1974 records. They are not the same value with two
spellings:

- `sessionId` is **this** session (always equals the filename).
- `session_id` is the **root of the resume lineage** — the id of the original
  session this one continues from. It is constant within a file.

In this corpus eight separate session files all carry
`session_id: "d8315a1f-…"`, and `d8315a1f` is itself the earliest of them
(started 09:12 on 2026-09-17; the others start at 09:43, 13:42, 16:18, 16:27,
18:10, 18:13, 18:16). Sessions that were never resumed have
`session_id == sessionId`.

```bash
# group files by lineage root
for f in *.jsonl; do
  echo "$(jq -r 'select(.session_id!=null)|.session_id' "$f" | head -1)  <- ${f%.jsonl}"
done | sort
```

So `session_id` is how you reconstruct "one long conversation continued across
eight files". Do not treat it as a redundant alias and do not assume camelCase
everywhere.

## 5. `assistant` records

```jsonc
{
  "parentUuid": "21fe835d-…",
  "isSidechain": false,
  "apiBlockIndex": 0,                      // optional, see below
  "requestId": "req_011Cf7Xf…",
  "type": "assistant",
  "uuid": "e9f45ed1-…",
  "timestamp": "2026-09-16T17:41:05.582Z",
  "effort": "high",                        // "high" | "xhigh"
  "perTurnEffort": null,
  "session_id": "3b8059d6-…",
  "userType": "external",
  "entrypoint": "cli",
  "cwd": "/Users/lars/Code/sbxagent",
  "sessionId": "3b8059d6-…",
  "version": "2.1.272",
  "gitBranch": "lars20070/morechanges",
  "message": { /* Anthropic Messages API shape, see §5.1 */ }
}
```

Field presence across 1224 `assistant` records:

| Field | Presence | Notes |
| --- | ---: | --- |
| `requestId` | 100% | API request id. **Not unique per record** — see §8. |
| `effort` | 100% | `"high"` (1004) or `"xhigh"` (220). |
| `perTurnEffort` | 100% | `null` in every record here. |
| `slug` | 64% | |
| `apiBlockIndex` | 7% | Only on versions 2.1.272 / 2.1.273. Values 0, 1, 2. |
| `wireToolInputs` | 4% | |
| `wireIngestContext` | 2% | |
| `attributionMcpServer` / `attributionMcpTool` | 2% | Set when the turn was attributed to an MCP tool. |

### 5.1 The nested `message` object

Key set is identical across all 1224 records:

```text
container, content, context_management, diagnostics, id, model,
role, stop_details, stop_reason, stop_sequence, type, usage
```

`container`, `context_management`, `diagnostics` and `stop_details` are `null`
in 100% of records in this corpus.

**`stop_reason` is populated, not null.** Measured distribution:

| Value | Count |
| --- | ---: |
| `tool_use` | 1123 |
| `end_turn` | 100 |
| `null` | 1 |

(1123 + 100 + 1 = 1224, i.e. every `assistant` record.)

```bash
cat *.jsonl | jq -r 'select(.type=="assistant") | .message.stop_reason | tostring' \
  | sort | uniq -c
```

**Content blocks.** `message.content` is an array. Across main files:

| Block type | Count | Shape |
| --- | ---: | --- |
| `tool_use` | 592 | `{type, id: "toolu_…", name, input}` |
| `thinking` | 347 | `{type, thinking, signature}` |
| `text` | 285 | `{type, text}` |

**Thinking text is redacted in this corpus.** 346 of 347 thinking blocks have
`thinking: ""` while retaining a full `signature`. Exactly one block has
non-empty text. A parser must not assume `thinking` carries readable reasoning.

```bash
cat *.jsonl | jq -r 'select(.type=="assistant") | .message.content[]
  | select(.type=="thinking")
  | (if .thinking=="" then "EMPTY" else "nonempty" end)' | sort | uniq -c
```

### 5.2 `message.usage`

Richer than the Messages API baseline. Key set on 1223 of 1224 records:

```text
input_tokens, output_tokens, output_tokens_details, cache_creation,
cache_creation_input_tokens, cache_read_input_tokens, server_tool_use,
service_tier, inference_geo, iterations, speed
```

One record uses a shorter legacy key set without `output_tokens_details`,
`iterations`, `server_tool_use` or `speed`.

```jsonc
{
  "input_tokens": 2,
  "cache_creation_input_tokens": 25592,
  "cache_read_input_tokens": 42209,
  "output_tokens": 303,
  "output_tokens_details": { "thinking_tokens": 105 },
  "server_tool_use": { "web_search_requests": 0, "web_fetch_requests": 0 },
  "service_tier": "standard",
  "cache_creation": { "ephemeral_1h_input_tokens": 25592, "ephemeral_5m_input_tokens": 0 },
  "inference_geo": "not_available",
  "speed": "standard",
  "iterations": [ { "input_tokens": 2, "output_tokens": 303, "…": "…", "type": "message" } ]
}
```

`input_tokens` is **2 in all 1224 records**. It is a placeholder; the real
prompt size lives in `cache_read_input_tokens` + `cache_creation_input_tokens`.
`output_tokens` is genuine (see §8 for the reconciliation).

## 6. `user` records

`message.content` is either a plain string (146 records — a typed prompt) or an
array (598 records — tool results).

| Field | Presence | Notes |
| --- | ---: | --- |
| `promptId` | 749/765 | |
| `sourceToolAssistantUUID` | 603 | The `assistant` record whose `tool_use` this answers. |
| `toolUseResult` | 603 | Claude-Code-specific structured result (§7). |
| `slug` | 452 | |
| `origin` | 87 | `{"kind":"human"}` (80) or `{"kind":"task-notification"}` (2). |
| `permissionMode` | 87 | |
| `promptSource` | 87 | `typed` (79), `system` (2), `queued` (1). |
| `isMeta` | 25 | |
| `interruptedMessageId` | 4 | Set when the user interrupted a turn. |
| `toolDenialKind` | 4 | Set when the user denied a tool call. |
| `classifierMetaLines` | 3 | |

`tool_result` blocks inside `message.content`:

```jsonc
{ "type": "tool_result", "tool_use_id": "toolu_…", "content": "…", "is_error": false }
```

`is_error` is present on 346 of 592 blocks: `false` 331, `true` 15. Absent on
the other 246. Treat absent as false, but note that `is_error: false` is
explicitly written more often than not.

## 7. Tool calls and results

### 7.1 Linkage is exact

`tool_use.id` ↔ `tool_result.tool_use_id`. In main session files:

- 592 `tool_use` blocks, 592 `tool_result` blocks
- 0 calls without a result
- 0 results without a call

Tools used: `Bash` 340, `Edit` 108, `Read` 79, `Write` 20,
`mcp__context7__query-docs` 11, `ToolSearch` 8, `Agent` 7, `ExitPlanMode` 7,
`AskUserQuestion` 6, `WebFetch` 3, `mcp__context7__resolve-library-id` 2,
`ScheduleWakeup` 1.

### 7.2 `toolUseResult`

The `user` record that carries a `tool_result` block also carries a top-level
`toolUseResult` — a richer, tool-specific structure. Its JSON type varies:
object (564), string (15), array (13). Observed key sets:

| Tool | `toolUseResult` keys |
| --- | --- |
| `Bash` | `stdout`, `stderr`, `interrupted`, `isImage`, `noOutputExpected`, `bashEditDiff`, `persistedOutputPath`, `persistedOutputSize` — or a plain string |
| `Edit` | `filePath`, `oldString`, `newString`, `originalFile`, `replaceAll`, `structuredPatch`, `userModified`, `staleRecovered` |
| `Write` | `filePath`, `content`, `originalFile`, `structuredPatch`, `type`, `userModified` |
| `Read` | `file`, `type` — or a plain string |
| `Agent` | `agentId`, `description`, `prompt`, `status`, `isAsync`, `outputFile`, `canReadOutputFile`, `resolvedModel` |
| `WebFetch` | `url`, `bytes`, `code`, `codeText`, `result`, `durationMs` |
| `ToolSearch` | `query`, `matches`, `total_deferred_tools` |
| `AskUserQuestion` | `questions`, `answers`, `annotations` |
| `ExitPlanMode` | `plan`, `filePath`, `planExists`, `isAgent` — or a plain string |
| MCP tools | plain string |

**A tool can return either an object or a bare string for the same tool name.**
`Bash`, `Read`, `ExitPlanMode` and `ScheduleWakeup` all do so here. Branch on
the JSON type before indexing.

### 7.3 Large output offload

When a tool's output is too large to inline, it is written to
`<sessionId>/tool-results/<id>.txt` and the JSONL record points at it:

```jsonc
"toolUseResult": {
  "persistedOutputPath": "/home/agent/.claude/projects/-Users-lars-Code-sbxagent/02042587-…/tool-results/<id>.txt",
  "persistedOutputSize": 74384,
  "stdout": "…truncated preview…"
}
```

The path is **absolute and recorded from inside the writing environment**. In
this corpus it reads `/home/agent/.claude/projects/…` while the files are read
from `/Users/lars/.local/state/sbxagent/traces/…` — the sandbox's own view, not
the host's. Resolve it relative to the transcript directory, not literally.

```bash
cat *.jsonl | jq -r 'select(.toolUseResult.persistedOutputPath?)
  | "\(.toolUseResult.persistedOutputPath)  size=\(.toolUseResult.persistedOutputSize)"'
```

## 8. Tokens and cost

### 8.1 `requestId` repeats are content blocks, not streaming snapshots

1224 `assistant` records span only 616 distinct `requestId` values:

| Records per `requestId` | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Count | 184 | 278 | 140 | 9 | 3 | 1 | 1 |

Within a group, all records share the same `message.id` (616/616) and a
**byte-identical `usage` object** (616/616). Each record holds exactly one
content block of the response:

```text
uuid=6fdff74c  msgid=…FKbjBw  out=232  stop=tool_use  blocks=[('text', "I'll look at the release not")]
uuid=ab426224  msgid=…FKbjBw  out=232  stop=tool_use  blocks=[('tool_use', 'ToolSearch')]
uuid=336bc83e  msgid=…FKbjBw  out=232  stop=tool_use  blocks=[('tool_use', 'Bash')]
```

So the correct rule is:

- **To reconstruct a response:** group by `requestId` and **concatenate** the
  content blocks in file order. Keeping only the last record loses blocks.
- **To sum tokens:** count each `requestId` **once**. Summing every row
  overcounts by 2.4× (1 296 716 vs 550 206 output tokens in this corpus).

Both halves matter and they pull in opposite directions.

### 8.2 `cost-state` is the authoritative cost record

```jsonc
{
  "type": "cost-state",
  "sessionId": "f5541174-…",
  "totalCostUSD": 7.1671865,
  "totalAPIDuration": 609101,
  "totalAPIDurationWithoutRetries": 608959,
  "totalToolDuration": 25527,
  "totalDuration": 6135520,
  "totalLinesAdded": 33,
  "totalLinesRemoved": 47,
  "startTime": 1789662469084,
  "hasUnknownModelCost": false,
  "modelUsage": {
    "claude-opus-5": {
      "inputTokens": 4130, "outputTokens": 42354,
      "cacheReadInputTokens": 8791513, "cacheCreationInputTokens": 168578,
      "webSearchRequests": 0, "costUSD": 7.1610365
    },
    "claude-haiku-4-5-20251001": { "…": "…", "costUSD": 0.00615 }
  }
}
```

`cost-state` is rewritten periodically; **read the last one in the file**.
`totalCostUSD` is Claude Code's own figure — there is no need to recompute cost
from token prices.

### 8.3 Why the transcript undercounts, even when deduped correctly

Reconciling deduped transcript totals against the final `cost-state` of the
same session:

| Session | Source | input | output | cacheRead | cacheCreate |
| --- | --- | ---: | ---: | ---: | ---: |
| `f5541174` | transcript (deduped) | 132 | 41 862 | 7 382 479 | 161 419 |
| | `cost-state` | 7 960 | 42 818 | 8 791 513 | 168 578 |
| `02042587` | transcript + 3 subagent files | 538 | 240 448 | 50 914 816 | 1 260 548 |
| | `cost-state` | 28 812 | 281 151 | 54 615 390 | 1 262 659 |

The `cacheCreate` figures agree to within 0.2% for `02042587`, which confirms
the dedup rule is right. The residual gap has one cause: **`cost-state` lists
`claude-haiku-4-5-20251001` but no `assistant` record in any transcript file
uses that model.** Haiku calls (background titles, classifiers) are billed but
never written to the transcript.

Consequence: even a perfectly-deduped transcript sum is a lower bound. Use
`cost-state`.

```bash
cat *.jsonl | jq -c 'select(.type=="cost-state")' | tail -1
```

## 9. The conversation chain

Measured across all 15 files (3802 chain-participating records):

| Property | Result |
| --- | --- |
| Roots (`parentUuid == null`) | exactly 1 per file, 15 total |
| Dangling `parentUuid` targets | **0** |
| Records whose parent appears later in the file | **0** |
| Leaves | 18 (12 files have 1; 3 files have 2–3) |
| Parents with more than one child | 3, across 2 files |

**File order already is a valid topological order.** Every record's parent
appears earlier in the file, in every file. Streaming a file top to bottom and
appending to a list yields a correct chronological reconstruction — no
uuid→record map, no backward walk, no cycle detection required for this corpus.

The map-and-walk approach is still needed for the 3 branch points: to render
exactly one conversation path, select a leaf and walk `parentUuid` back to the
root. Branches arise from interruptions and retries (the 4 `interruptedMessageId`
and 4 `toolDenialKind` records).

```bash
python3 - <<'EOF'
import json,glob
from collections import Counter
for f in sorted(glob.glob("*.jsonl")):
    ch=[json.loads(l) for l in open(f) if l.strip()]
    ch=[r for r in ch if "uuid" in r]
    ids={r["uuid"] for r in ch}
    roots=sum(1 for r in ch if r.get("parentUuid") is None)
    dang=sum(1 for r in ch if r.get("parentUuid") and r["parentUuid"] not in ids)
    seen=set(); fwd=0
    for r in ch:
        p=r.get("parentUuid")
        if p and p not in seen: fwd+=1
        seen.add(r["uuid"])
    print(f"{f[:8]} chained={len(ch)} roots={roots} dangling={dang} fwd-refs={fwd}")
EOF
```

## 10. Reference: remaining record types

### 10.1 `attachment` — injected context

The single most common record type. `attachment.type` discriminates 26 variants:

| `attachment.type` | Count | Payload keys |
| --- | ---: | --- |
| `output_style` | 618 | `style` |
| `total_tokens_reminder` | 616 | `text` |
| `hook_success` | 340 | `hookName`, `hookEvent`, `command`, `content`, `stdout`, `stderr`, `exitCode`, `durationMs`, `toolUseID` |
| `skill_listing` | 14 | `names`, `skillCount`, `content`, `isInitial` |
| `mcp_instructions_delta` | 14 | `addedNames`, `removedNames`, `addedBlocks` |
| `deferred_tools_delta` | 14 | `addedNames`, `removedNames`, `readdedNames`, `surfacedNames`, `addedLines`, `wireHiddenNames`, `pendingMcpServers`, `failedMcpServers` |
| `agent_listing_delta` | 14 | `addedTypes`, `removedTypes`, `addedLines`, `isInitial`, `showConcurrencyNote` |
| `file` | 12 | `filename`, `displayPath`, `content` |
| `edited_text_file` | 11 | `filename`, `snippet` |
| `plan_mode_exit` | 8 | `planFilePath`, `planExists` |
| `plan_mode` | 6 | `planFilePath`, `planExists`, `reminderType`, `isSubAgent` |
| `queued_command` | 5 | `prompt`, `commandMode`, `timestamp` |
| `prompt_snapshot` | 4 | `systemPrompt`, and optionally `cliPrefix`, `tools` |
| `directory` | 4 | `path`, `displayPath`, `content` |
| `remote_session_change` | 3 | `url`, `commit`, `pr`, `managedCommit`, `managedPr`, `sendUserFileHint` |
| `model` | 3 | `identity`, `text` |
| `hook_stopped_continuation` | 3 | `hookName`, `hookEvent`, `message`, `toolUseID` |
| `deferred_tools_record` | 3 | `entries` |
| `date` | 3 | `date`, optionally `changed` |
| `auto_mode` | 3 | `bypass`, `steerOnly`, `bashFirst`, `autoModeConsentFlow`, optionally `bashFirstSteer` |
| `already_read_file` | 3 | `filename`, `displayPath`, `content` |
| `session_context` | 2 | `context` |
| `output_style_instructions` | 2 | `style` |
| `instructions` | 2 | `files` |
| `environment` | 2 | `snapshot` |
| `plan_mode_reentry` | 1 | `planFilePath` |

Two optional top-level fields carry the text actually shown to the model:

- `rendered` (133 records) — an array of content blocks, typically one
  `{content: "<system-reminder>…"}`. Present on 19 of the 26 subtypes.
- `renderedInHumanTurn` (1 record) — same shape, used when the attachment is
  delivered inside a human turn.

**The key set varies within a subtype.** `auto_mode`, `date`,
`deferred_tools_delta` and `prompt_snapshot` each occur with two different key
sets. Treat every payload key as optional.

### 10.2 `system`

Four subtypes:

| `subtype` | Count | Extra fields |
| --- | ---: | --- |
| `turn_duration` | 79 | `durationMs`, `messageCount`, optionally `pendingBackgroundAgentCount` |
| `away_summary` | 23 | `content` — a short recap of what happened while the user was away |
| `local_command` | 18 | `content` (`<local-command-stdout>…</local-command-stdout>`), `level` |
| `informational` | 4 | `content`, `level` |

`level` is `"info"` where present. `content` is absent on all 79
`turn_duration` records.

### 10.3 Session bookkeeping (not in the chain)

These are keyed by `sessionId` only and are last-write-wins. Read the final
occurrence.

```jsonc
{"type":"mode","mode":"normal","sessionId":"f5541174-…"}
{"type":"permission-mode","permissionMode":"bypassPermissions","sessionId":"e4ac3e38-…"}
{"type":"ai-title","aiTitle":"Scripts/traces.sh code review fixes","sessionId":"f5541174-…"}
{"type":"agent-name","agentName":"upgrade-sbx-v0-43-0","sessionId":"61ae5d42-…"}
{"type":"atis-latch","atis":"","sessionId":"f5541174-…"}
{"type":"last-prompt","lastPrompt":"Please do not be offended. But …","leafUuid":"fad61fb…","sessionId":"…"}
```

Observed values — `mode`: `normal` (217), `plan` (42), `auto` (27);
`permissionMode`: `bypassPermissions` (95), `plan` (42), `default` (3).

`last-prompt.leafUuid` points at the chain record the prompt produced — the one
place a bookkeeping record references the chain.

### 10.4 File history

```jsonc
// full state
{"type":"file-history-snapshot","isSnapshotUpdate":false,"messageId":"01c510d5-…",
 "snapshot":{"messageId":"aa722c8b-…","timestamp":"2026-09-17T10:14:48.361Z",
   "trackedFileBackups":{
     ".claude/plans/foo.md":{"backupFileName":"726320ba4f5c4c06@v2","version":2,
       "backupTime":"2026-09-17T10:14:48.361Z","realParentDir":"/Users/lars/Code/sbxagent/.claude/plans"}}}}

// incremental update
{"type":"file-history-delta","messageId":"25de3747-…","snapshotMessageId":"f15dbf64-…",
 "trackingPath":".claude/plans/foo.md",
 "backup":{"backupFileName":null,"version":1,"backupTime":"2026-09-17T10:10:59.778Z",
   "realParentDir":"/Users/lars/Code/sbxagent/.claude/plans"},
 "timestamp":"2026-09-17T10:10:59.780Z"}
```

`messageId` here is a chain `uuid`, so file state can be joined back to the
conversation position that produced it.

### 10.5 `queue-operation`

Background-task notifications, always in `enqueue`/`dequeue` pairs.

```jsonc
{"type":"queue-operation","operation":"enqueue","timestamp":"…","sessionId":"…",
 "content":"<task-notification><task-id>abc4137…</task-id>…</task-notification>"}
{"type":"queue-operation","operation":"dequeue","timestamp":"…","sessionId":"…"}
```

`content` is present on `enqueue` (13) and absent on `dequeue`; `reason` appears
on 5. The `content` blob embeds the full subagent result and can be very large.

## 11. Subagents

Subagent conversations **never** appear inline in the main session file: all
3802 main-file chain records have `isSidechain: false`, and all 496 subagent
records have `isSidechain: true`.

Each subagent gets two files under `<sessionId>/subagents/`:

```jsonc
// agent-<agentId>.meta.json
{"agentType":"Explore","description":"Map repo script and lint conventions",
 "toolUseId":"toolu_01Y3G9…","spawnDepth":1}

// one file also carried:
{"…":"…","requestShape":"background","requestNonInteractive":true}
```

To join a subagent back to its parent: `meta.json`'s `toolUseId` matches the
`tool_use.id` of the `Agent` call in the main file. The subagent's own
`agentId` also appears in that call's `toolUseResult.agentId`.

The subagent `.jsonl` uses the same envelope and the same chain structure as a
main file. It has no `cost-state` record of its own — subagent tokens roll into
the parent session's `cost-state`.

## 12. Parsing checklist

1. **Read line by line, switch on `type`.** Tolerate unknown `type`,
   `subtype`, `attachment.type` and unknown fields rather than failing.
2. **Do not assume camelCase.** `session_id` coexists with `sessionId` and means
   something different. `toolUseID` (capital D) appears inside `hook_success`
   while `tool_use_id` (snake) appears in `tool_result` blocks.
3. **Group `assistant` records by `requestId`.** Concatenate their content
   blocks to rebuild a response; count `usage` once per group.
4. **Use `cost-state` for cost and totals**, not summed `usage`. Read the last
   one in the file.
5. **Never trust `input_tokens`** — it is 2 in every record. Real prompt size is
   `cache_read_input_tokens + cache_creation_input_tokens`.
6. **Branch on the JSON type of `toolUseResult`** before indexing — the same
   tool returns an object or a bare string depending on outcome.
7. **Follow `persistedOutputPath`**, and resolve it relative to the transcript
   directory rather than taking the absolute path literally.
8. **Expect empty `thinking` text** with a valid `signature`.
9. **File order is already topological here**, but select-a-leaf-and-walk-back
   is still needed to pick one path through the 3 branch points.
10. **Follow `session_id`** to reassemble a conversation spread over several
    resumed session files.
11. **Skip for a human-readable render:** all eight non-chain bookkeeping types,
    `system`, and `attachment` (or render only `attachment.rendered`).

## 13. Not observable in this corpus

The following were searched for explicitly and found **zero** times. Their
absence here is not evidence they do not exist in other versions or workflows —
only that nothing in this corpus exercised them.

- **Record types:** `summary`, `progress`, `custom-title`, `pr-link`, `tag`,
  `worktree-state`, `agent-setting`, `content-replacement`,
  `attribution-snapshot`. (A grep for `"summary"` returns 4 hits, but all four
  are inside an embedded tool JSON-schema in a `prompt_snapshot` attachment, not
  record types. `jq 'select(.type=="summary")'` returns nothing.)
- **Compaction:** no `compact_boundary` subtype, `compactMetadata`,
  `isCompactSummary`, or `logicalParentUuid`. No session here was compacted.
- **Forking:** no `forkedFrom` field. Session continuation is expressed through
  `session_id` instead (§4).
- **Swarm/teammate metadata:** no `teamName`, `agentColor`.
- **Other:** no `todos`, `thinkingMetadata`, `isVisibleInTranscriptOnly`,
  `redacted_thinking` blocks, `image` content blocks, or top-level `costUSD`
  (the name occurs only nested inside `cost-state.modelUsage.<model>.costUSD`).
- **Sidecar files:** no `.orphaned-*`/`.superseded-*` transcripts, no
  `remote-agents/` directory, no `history.jsonl` in this tree.
- **Versions:** nothing before 2.1.246. No claim here should be applied to
  1.0.x or early 2.x transcripts.
- **Entry points:** `entrypoint` is `cli` in all 3802 records. Desktop, web and
  SDK transcripts were not examined.

```bash
# the absence check
for f in summary progress compactMetadata isCompactSummary logicalParentUuid \
         forkedFrom todos thinkingMetadata teamName agentColor; do
  printf '%s: %s\n' "$f" "$(rg -o --no-filename "\"$f\"" *.jsonl 2>/dev/null | wc -l)"
done
```
