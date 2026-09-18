# Claude Code JSONL transcript: field reference

Record-by-record detail for the format. `SKILL.md` covers the handling that
changes an answer; this covers the fields.

The format is internal to Claude Code and undocumented. It changes between
releases, and this reference was assembled by observation, not from a
specification. **Treat every field as optional**, switch on `type`, and ignore
records and fields you do not recognise rather than failing on them.

## Contents

- [On-disk layout](#on-disk-layout)
- [Record types](#record-types)
- [The common envelope](#the-common-envelope)
- [`assistant` records](#assistant-records)
- [`user` records](#user-records)
- [`system` records](#system-records)
- [`attachment` records](#attachment-records)
- [Session bookkeeping records](#session-bookkeeping-records)
- [Tool calls and results](#tool-calls-and-results)
- [Cost and tokens](#cost-and-tokens)
- [The conversation tree](#the-conversation-tree)
- [Subagents](#subagents)

## On-disk layout

```text
projects/<escaped-cwd>/
├── <sessionId>.jsonl                 # the session transcript
├── <sessionId>/
│   ├── subagents/
│   │   ├── agent-<agentId>.jsonl     # one subagent's full transcript
│   │   └── agent-<agentId>.meta.json # who spawned it, and why
│   └── tool-results/
│       └── <id>.txt                  # tool output too large to inline
```

`<escaped-cwd>` is the working directory with non-alphanumeric characters
replaced by `-`. The filename stem is the session id and matches the
`sessionId` field on every record in the file.

The `<sessionId>/` sibling directory exists only when the session actually
spawned a subagent or offloaded a large tool result.

## Record types

Every line is a self-contained JSON object with a `type` discriminator. Two
families:

**Chain-participating** — carry `uuid` and `parentUuid`, and form the
conversation tree:

| `type` | Meaning |
| --- | --- |
| `assistant` | One content block of a model response. |
| `user` | A typed prompt, or tool results returned to the model. |
| `attachment` | Context injected into the conversation. Usually the most numerous type in a file. |
| `system` | System-generated events, discriminated by `subtype`. |

**Session bookkeeping** — keyed by `sessionId` only, no `uuid`, not part of the
tree. Last-write-wins: read the final occurrence.

| `type` | Meaning |
| --- | --- |
| `cost-state` | Running cost and token totals. See [Cost and tokens](#cost-and-tokens). |
| `mode` | Session mode latch. |
| `permission-mode` | Permission-mode latch. |
| `ai-title` | Background-generated session title. |
| `agent-name` | Human-readable session name. |
| `atis-latch` | Short status string for the UI; often empty. |
| `last-prompt` | The most recent prompt, plus the chain record it produced. |
| `file-history-snapshot` | Full file-backup state for undo/rewind. |
| `file-history-delta` | Incremental file-backup update. |
| `queue-operation` | Background-task notification enqueue/dequeue. |

Other types exist in other releases. Switch on `type` and pass over unknowns.

```bash
jq -r '.type' session.jsonl | sort | uniq -c | sort -rn
```

## The common envelope

Fields on chain-participating records:

| Field | Type | Notes |
| --- | --- | --- |
| `uuid` | string | Unique id of this record. |
| `parentUuid` | string \| null | Previous record in the chain; `null` at the file root. |
| `sessionId` | string | This session. Matches the filename. |
| `session_id` | string | **Different field.** The lineage root — see below. |
| `timestamp` | string | ISO 8601 with milliseconds and `Z`. |
| `cwd` | string | Working directory at write time. |
| `version` | string | Claude Code version that wrote the record. |
| `gitBranch` | string | Branch at write time; empty outside a repository. |
| `userType` | string | Typically `"external"`. |
| `entrypoint` | string | How Claude Code was launched, e.g. `"cli"`. |
| `isSidechain` | bool | `false` in the main file; `true` in subagent transcripts. |
| `slug` | string | Human-readable session slug. Per-session, not on every record. |
| `isMeta` | bool | Marks injected, non-conversational content. |

### `sessionId` versus `session_id`

Not an alias and not a naming slip. `sessionId` is this session; `session_id`
is the id of the session this one was **resumed from**, constant within a file.
A conversation continued several times produces several files that all carry
the same `session_id`, and the origin session's own `session_id` equals its
`sessionId`.

```bash
# group a directory's sessions by lineage root
for f in *.jsonl; do
    echo "$(jq -r 'select(.session_id != null) | .session_id' "$f" | head -1)  <- ${f%.jsonl}"
done | sort
```

Note also that the camelCase convention is not universal inside records:
`tool_result` blocks use `tool_use_id`, while a `hook_success` attachment uses
`toolUseID`.

## `assistant` records

One content block per record. Several records sharing a `requestId` make up one
reply, repeating the same `message.id` and the same `usage`.

```jsonc
{
  "parentUuid": "…", "uuid": "…", "timestamp": "…",
  "type": "assistant",
  "requestId": "req_…",           // groups the blocks of one reply
  "isSidechain": false,
  "effort": "high",               // reasoning effort for the turn
  "perTurnEffort": null,
  "sessionId": "…", "session_id": "…", "cwd": "…", "version": "…",
  "message": { /* below */ }
}
```

Occasional extras: `apiBlockIndex`, `wireToolInputs`, `wireIngestContext`, and
`attributionMcpServer` / `attributionMcpTool` when the turn is attributed to an
MCP tool.

### `message`

Mirrors the Anthropic Messages API response: `id`, `type`, `role`, `model`,
`content`, `stop_reason`, `stop_sequence`, `usage`. Fields such as `container`,
`context_management`, `diagnostics` and `stop_details` appear but are commonly
`null`.

`stop_reason` **is** populated here — typically `tool_use` or `end_turn`. Do not
assume it is always null.

### Content blocks

| Block | Shape |
| --- | --- |
| `text` | `{type, text}` |
| `thinking` | `{type, thinking, signature}` |
| `tool_use` | `{type, id: "toolu_…", name, input}` |

Thinking text is frequently **redacted to an empty string** while the
`signature` is retained. Treat empty `thinking` as normal, not as corruption.
Other block types (`redacted_thinking`, `image`) exist; render unknown blocks as
a placeholder rather than dropping them silently.

### `usage`

```jsonc
{
  "input_tokens": 2,                                  // placeholder, see below
  "output_tokens": 303,
  "output_tokens_details": { "thinking_tokens": 105 },
  "cache_read_input_tokens": 42209,
  "cache_creation_input_tokens": 25592,
  "cache_creation": { "ephemeral_5m_input_tokens": 0, "ephemeral_1h_input_tokens": 25592 },
  "server_tool_use": { "web_search_requests": 0, "web_fetch_requests": 0 },
  "service_tier": "standard",
  "inference_geo": "not_available",
  "speed": "standard",
  "iterations": [ { "…": "…" } ]
}
```

`input_tokens` is a small constant and carries no information. The meaningful
prompt-side figure is `cache_read_input_tokens + cache_creation_input_tokens`.
`output_tokens` is genuine. Older records use a shorter key set without
`output_tokens_details`, `iterations`, `server_tool_use` or `speed`.

## `user` records

`message.content` is either a **string** (a typed human prompt) or an **array**
(tool results, occasionally a text block).

| Field | Notes |
| --- | --- |
| `promptId` | Identifies the prompt. |
| `sourceToolAssistantUUID` | The `assistant` record whose `tool_use` this answers. |
| `toolUseResult` | Structured result; see [Tool calls and results](#tool-calls-and-results). |
| `origin` | e.g. `{"kind":"human"}` or `{"kind":"task-notification"}`. |
| `promptSource` | e.g. `typed`, `queued`, `system`. |
| `permissionMode` | Mode in force for this prompt. |
| `interruptedMessageId` | Present when the user interrupted the turn. |
| `toolDenialKind` | Present when the user denied a tool call. |

Counting typed human turns means counting `user` records whose
`message.content` is a string — the array ones are machine traffic.

## `system` records

Carry `subtype`, and usually `content`, `level` and `isMeta`. Observed
subtypes:

| `subtype` | Meaning |
| --- | --- |
| `turn_duration` | Timing for a turn: `durationMs`, `messageCount`. Carries no `content`. |
| `away_summary` | Short recap of what happened while the user was away. |
| `local_command` | Output of a slash command, wrapped in `<local-command-stdout>`. |
| `informational` | Notices shown to the user. |

## `attachment` records

Context injected into the conversation rather than authored by either party.
The payload sits under `attachment`, discriminated by `attachment.type`.

Common variants include `output_style`, `total_tokens_reminder` and
`hook_success` (which carries `hookName`, `hookEvent`, `command`, `stdout`,
`stderr`, `exitCode`, `durationMs`, `toolUseID`). Others seen include `file`,
`directory`, `already_read_file`, `edited_text_file`, `skill_listing`,
`agent_listing_delta`, `deferred_tools_delta`, `deferred_tools_record`,
`mcp_instructions_delta`, `plan_mode`, `plan_mode_exit`, `plan_mode_reentry`,
`auto_mode`, `auto_mode_exit`, `queued_command`, `prompt_snapshot`,
`session_context`, `output_style_instructions`, `instructions`, `environment`,
`model`, `date`, `remote_session_change`, `hook_stopped_continuation`.

The key set varies **within** a single variant, so treat every payload key as
optional.

Two optional top-level fields carry the text actually shown to the model:
`rendered` and `renderedInHumanTurn`, both arrays of content blocks. When
present, they are what a human-readable render should show.

```bash
jq -r 'select(.type == "attachment") | .attachment.type' session.jsonl |
    sort | uniq -c | sort -rn
```

## Session bookkeeping records

These carry no `uuid` and sit outside the conversation tree. Each is keyed by
`sessionId` and rewritten as the session goes, so **read the last occurrence**
of the type you want.

```jsonc
{"type":"mode","mode":"normal","sessionId":"…"}
{"type":"permission-mode","permissionMode":"bypassPermissions","sessionId":"…"}
{"type":"ai-title","aiTitle":"Generated session title","sessionId":"…"}
{"type":"agent-name","agentName":"human-readable-name","sessionId":"…"}
{"type":"atis-latch","atis":"","sessionId":"…"}
{"type":"last-prompt","lastPrompt":"the prompt text …","leafUuid":"…","sessionId":"…"}
```

`last-prompt.leafUuid` is the one place a bookkeeping record points back into
the conversation tree.

File history, for undo and rewind, comes in two shapes — a full snapshot and an
incremental delta:

```jsonc
{"type":"file-history-snapshot","isSnapshotUpdate":false,"messageId":"<a chain uuid>",
 "snapshot":{"messageId":"…","timestamp":"…",
   "trackedFileBackups":{"<relative path>":{"backupFileName":"…","version":2,
     "backupTime":"…","realParentDir":"…"}}}}

{"type":"file-history-delta","messageId":"<a chain uuid>","snapshotMessageId":"…",
 "trackingPath":"<relative path>","backup":{"…":"…"},"timestamp":"…"}
```

`messageId` is a chain `uuid`, so file state can be joined to the conversation
position that produced it.

`queue-operation` records background-task notifications in `enqueue`/`dequeue`
pairs; the `enqueue` carries a `content` blob that can be very large.

`cost-state` is covered under [Cost and tokens](#cost-and-tokens).

## Tool calls and results

An `assistant` record emits a `tool_use` block; a later `user` record carries a
`tool_result` block. They link by `tool_use.id` == `tool_result.tool_use_id`,
and the pairing is normally exact in both directions.

```jsonc
{ "type": "tool_result", "tool_use_id": "toolu_…", "content": "…", "is_error": false }
```

`is_error` is sometimes absent; absent means not an error. `is_error: true` is
the **only** reliable failure signal — a shell command can print error text and
still succeed as a tool call.

`content` is a string or an array of blocks. Several `tool_use` blocks can be
issued in one reply and run in parallel, each answered by its own `user` record.

### `toolUseResult`

The `user` record also carries a top-level `toolUseResult`: a richer,
Claude-Code-specific version of the result. **Its JSON type varies** — object,
string, or array — for the same tool name.

| Tool | Typical object keys |
| --- | --- |
| `Bash` | `stdout`, `stderr`, `interrupted`, `isImage`, `noOutputExpected`, `bashEditDiff`, `persistedOutputPath`, `persistedOutputSize` |
| `Edit` | `filePath`, `oldString`, `newString`, `originalFile`, `replaceAll`, `structuredPatch`, `userModified` |
| `Write` | `filePath`, `content`, `originalFile`, `structuredPatch`, `userModified` |
| `Read` | `file`, `type` |
| `Agent` | `agentId`, `description`, `prompt`, `status`, `isAsync`, `outputFile`, `resolvedModel` |
| `WebFetch` | `url`, `bytes`, `code`, `codeText`, `result`, `durationMs` |
| `ToolSearch` | `query`, `matches`, `total_deferred_tools` |
| `AskUserQuestion` | `questions`, `answers`, `annotations` |

Tools that failed frequently return a bare string instead of the object. MCP
tools typically return an array of content blocks.

`durationMs` is the only per-call duration in the data and only a few tools
report it. For everything else, the closest available figure is elapsed wall
time between the `tool_use` record's timestamp and its `tool_result`'s — an
upper bound, since parallel calls overlap.

### Offloaded output

Output too large to inline is written beside the transcript and referenced by
`toolUseResult.persistedOutputPath` and `persistedOutputSize`. The recorded path
is absolute **and belongs to the machine that wrote it**, which is often a
sandbox rather than the machine reading the file. Rebuild it:

```text
dirname(session.jsonl)/<sessionId>/tool-results/basename(persistedOutputPath)
```

Check the rebuilt path exists before reading, and fall back to the inline
preview when it does not.

## Cost and tokens

`cost-state` is Claude Code's own accounting record.

```jsonc
{
  "type": "cost-state",
  "sessionId": "…",
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
    "<model-id>": {
      "inputTokens": 4130, "outputTokens": 42354,
      "cacheReadInputTokens": 8791513, "cacheCreationInputTokens": 168578,
      "webSearchRequests": 0, "costUSD": 7.1610365
    }
  }
}
```

- It is rewritten periodically. **Read the last one in the file.**
- It can be **absent** entirely. Subagent transcripts never have one.
- `modelUsage` regularly lists models that no `assistant` record in the
  transcript uses — background calls for titles and classification. This is why
  transcript token sums come in under `cost-state`, even when deduplicated
  correctly.
- `totalToolDuration` is a session total. It cannot be apportioned per tool.

## The conversation tree

`uuid` and `parentUuid` form a tree. In practice a transcript is written in
topological order — every record's parent appears earlier in the file — so
streaming top to bottom is a valid traversal.

What streaming does **not** do is pick a branch. Interruptions, retries and
denied tool calls leave abandoned paths in the file, and rendering everything in
order splices them into an exchange that never happened.

To render one conversation:

1. Build `uuid -> parentUuid` for records that have a `uuid`.
2. Leaves are uuids that never appear as anyone's `parentUuid`. The last chain
   record in the file is the active leaf.
3. Walk `parentUuid` from the chosen leaf back to the root.
4. Render those records in file order.

Guard the walk: a `parentUuid` naming a record the file does not contain should
end the walk, and a visited set keeps a cycle from hanging.

## Subagents

Subagent conversations never appear inline in the main file — every main-file
record has `isSidechain: false`, every subagent record `true`.

```jsonc
// <sessionId>/subagents/agent-<agentId>.meta.json
{
  "agentType": "Explore",
  "description": "Map repo script and lint conventions",
  "toolUseId": "toolu_…",
  "spawnDepth": 1
}
```

Join a subagent back to its parent through `toolUseId`, which matches the `id`
of the spawning `Agent`/`Task` `tool_use` block in the main file. That call's
`toolUseResult.agentId` matches the subagent's filename.

Subagent transcripts use the same envelope and the same tree structure, and
contain only `assistant`, `user` and `attachment` records. Their token usage is
already included in the parent session's `cost-state`.
