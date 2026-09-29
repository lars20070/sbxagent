# First-principles review of the proposed Pi trace tools

## Verdict

Deterministic tooling is warranted. Pi's tree traversal, usage accounting,
content unions, fork semantics, and safe handling of images/signatures are too
easy to reproduce incorrectly with ad hoc commands every time.

The proposed five-file shell implementation is not the best shape, however.
It inherits the Claude skill's presentation-oriented split rather than the
workflow I would use to investigate a large trace. I would ship one executable
Python CLI with four subcommands:

```text
pi-trace sessions   # cheap recursive discovery
pi-trace inspect    # one-pass structure, usage, tools, leaves, and outline
pi-trace search     # fast bounded search returning stable entry identifiers
pi-trace show       # bounded retrieval around an entry or along one branch
```

`common.sh` disappears, `audit.sh` folds into `inspect`, and full Markdown
transcript rendering becomes an explicit mode of `show`, not the default way
to read a session.

## Start from the investigation loop

An agent exploring traces normally moves through four stages:

| Need | Cheapest useful operation | Desired result |
| --- | --- | --- |
| Find candidate sessions | Read headers and file metadata | IDs, paths, cwd, parent, size, time |
| Find the relevant event | Search raw bytes, decode only candidate records | Session, entry ID, field, bounded excerpt |
| Understand the neighborhood | Follow one branch and fetch a small slice | A bounded turn/entry outline or excerpt |
| Verify behavior or spend | Stream one selected file once | Counts, models, tools, leaves, recorded usage |

The planned `index → transcript → audit` path does more work and produces more
text than this loop needs. It fully parses every file during discovery, renders
an entire branch to understand one event, and then parses the same file again
for accounting.

## Findings

### 1. The proposed input boundary does not match the path an agent naturally has

The plan keeps `index.sh <trace-dir>` and a non-recursive top-level
`list_sessions()` (plan lines 285-309 and 332-353). The path supplied for this
review is the Pi `sessions/` root:

```text
/Users/lars/.local/state/sbxagent/traces/sbxagent-9df4f2fe/sbxpi/sessions
```

Its JSONL files are below escaped-CWD subdirectories. There are no `*.jsonl`
files directly in that root, so the planned starting command would reject the
exact path a user is most likely to provide.

Every discovery/search command should accept any of:

- the `sessions/` root and recurse through escaped-CWD directories;
- one escaped-CWD directory;
- one session JSONL file.

The catalog should report the authoritative header `cwd`, so callers never
need to decode the directory name. A session ID or unambiguous prefix from the
catalog should also be accepted as a selector under a supplied root.

### 2. Separate shell scripts do not follow from separate user questions

Lines 129-153 argue that four questions imply four scripts. They imply four
commands, but not four implementations. The proposed split duplicates schema
dispatch, malformed-line handling, redaction, clipping, file discovery,
session selection, and output formatting across Bash, awk, and jq programs.
The shared jq prelude reduces some duplication but cannot centralize the whole
record model.

One executable can still give each operation the traversal best suited to it:
header-only reads for `sessions`, ripgrep candidates for `search`, a streaming
reduce for `inspect`, and a minimal tree/offset index for `show`. A unified
implementation also gives search results a stable handoff to show—session path,
entry ID, and line number—without teaching four scripts how to agree on those
identifiers.

This is exactly the kind of deterministic repeated logic for which the
skill-creator recommends a script. The script boundary should be around the
Pi trace model, not around each report format.

### 3. Discovery should be cheap; the planned index is a deep audit in disguise

`index.sh` is specified to scan every record of every file to compute span,
prompt count, title, and cost (lines 332-343). On a large trace tree this makes
the recommended first command proportional to all transcript bytes. Most of
that work is wasted when the next action is to select one or two sessions.

Make `sessions` header-only by default. It should return:

- session ID and path;
- header timestamp, cwd, and `parentSession`;
- file size and modification time;
- whether the file currently lacks a terminating newline.

Do not compute cost, prompt count, or a title during cheap discovery. `inspect`
can compute those for selected files. If a richer catalog is eventually shown
to be valuable, make it an explicit `--deep` operation rather than the default.

### 4. A full transcript is the wrong primary drill-down primitive

The planned `transcript.sh` remains centered on rendering a whole root-to-leaf
path (lines 355-409). Clipping individual blocks does not bound total output:
ten thousand clipped blocks still produce a huge tool result. Redirecting the
render to `/tmp` merely moves the problem to a manual `head`/`sed` workflow and
loses semantic boundaries.

The primary retrieval command should be entry-oriented and bounded:

- show one entry by ID or source line;
- show N entries before/after a search hit on its active path;
- show the last N entries on a selected leaf;
- show a compact outline containing IDs, roles, tool names, errors, and short
  previews;
- render the entire branch only with an explicit `--all` option.

Every rendered item should include its entry ID. Search can then lead directly
to `show --entry ID --before 3 --after 5`, which is how I would investigate
"why did this tool fail?" or "what happened after this prompt?" without
loading unrelated history.

Markdown is useful for a final human-readable export, but JSON/JSONL should be
the primary output for an agent. The agent can compose, filter, and summarize
structured records without scraping headings and fenced blocks.

### 5. Accounting belongs in session inspection, not in a separate audit traversal

Usage, model, tool, role, and branch statistics all arise from the same
one-record-at-a-time pass. Keeping `audit.sh` separate (lines 427-463) makes an
agent parse a selected file again after it has already inspected it and forces the
same schema rules into another jq program.

`inspect` should emit one structured summary containing:

- entry/message/content-block counts;
- roots and leaves;
- first/last entry timestamps;
- prompt previews with IDs;
- model changes and assistant models;
- tool calls, failures, unmatched calls/results, and elapsed times;
- conversation, tool-execution, summarization, standalone, and unattributed
  recorded usage buckets;
- warnings for malformed lines, copied fork history, unknown types, and a
  partial tail.

For a directory target it can emit one JSON object per session. It should not
print a directory grand total by default because forks copy usage-bearing
history. An explicit aggregate mode can carry the upper-bound warning.

### 6. The natural implementation language here is Python, not Bash plus awk plus jq

Python 3 is part of this repository's documented toolchain and is verified by
`tests/toolchain_test.sh`. A standard-library implementation gives this task
several concrete advantages:

- one parser, sanitizer, content renderer, usage accumulator, and selector;
- binary offsets for records, allowing `show` to build a minimal
  `id → parent/offset/line` index and seek only the selected path records;
- explicit output budgets and semantic slices;
- recursive path handling without shell glob edge cases;
- ordinary dictionaries for correlation state rather than Bash 3.2/awk
  workarounds;
- unit-testable functions with synthetic streams;
- clearer malformed-record diagnostics carrying file and line number.

The implementation should remain dependency-free. `search` can invoke the
already-installed `rg --json` to find candidate lines quickly, then decode and
sanitize only those records in Python. `jq` remains useful to callers for
post-processing JSON output, but it need not be the implementation language.

One executable does not require one monolithic function. Split internal Python
modules only if the code genuinely benefits, while retaining one public CLI.

### 7. Bounded output must be a command invariant, not a usage suggestion

The current example sessions are only 77 KB and 215 KB, yet their largest
single JSONL records are approximately 26 KB and 39 KB. Large sessions can
contain much larger records and vastly more of them.

Every text-producing subcommand should therefore have both per-field and
whole-command budgets. Defaults should:

- limit result count;
- clip prose, tool arguments, and tool results independently;
- cap total emitted characters/bytes;
- represent images by MIME type and encoded size only;
- never emit thinking signatures, image data, or an entire unknown object;
- report how many entries or bytes were omitted and how to request the next
  slice.

The generic JSON-serialization fallbacks proposed at lines 396-409 are not safe
enough. Serializing an unknown record duplicates a potentially huge payload,
and clipping its prefix can still expose base64 or opaque secrets. Unknown
records should render only a metadata projection such as type/role, ID,
timestamp, field names, and approximate serialized size.

### 8. Do not make trace-controlled paths readable through the helper

`transcript.sh --expand-truncated` would open `fullOutputPath` taken from a
trace record (lines 365 and 387-395). Treating the resulting bytes as data does
not address the authority problem: a forged or extension-produced trace can
name any readable host path, and sandbox-absolute paths are usually meaningless
on the host anyway.

For the first version, report the recorded path and truncation metadata but do
not follow it. If expansion is later required, accept an explicit user-supplied
allowed root, resolve symlinks, and refuse anything outside that root. Reading
an arbitrary path merely because a past transcript names it should never be a
normal trace-rendering operation.

### 9. Search and retrieval should form one composable protocol

The proposed search correctly uses ripgrep to narrow candidates, but its
interface is still report-oriented. Search results should be JSONL records such
as:

```json
{"session":"01a0...","path":"...jsonl","line":11,"entryId":"4fd2...","timestamp":"...","type":"message","role":"toolResult","field":"content.text","excerpt":"..."}
```

That output gives the next command everything it needs. `show` should accept
the path plus entry ID directly. A bounded text view can remain available for
humans, but stable structured identifiers are the important contract.

Be careful with `rg --max-count`: it caps raw JSON-line matches, not sanitized
semantic hits. Matches in ignored image data or structural fields could consume
the cap before later useful hits. Either search a safely constructed set of raw
patterns and document this tradeoff, or continue until the requested number of
decoded semantic hits has been produced while enforcing a separate scan limit.

### 10. Avoid a persistent index until measurements justify one

Very large trace trees make an SQLite cache tempting, but live appends,
rewrites during migration, moved parent paths, and cache invalidation add a
second correctness problem. The first version should stay read-only and
stateless:

- recurse and read headers cheaply for discovery;
- use ripgrep for cross-file narrowing;
- stream only selected sessions for deep inspection;
- build temporary in-memory/temporary-file indexes only for the current
  command.

If real use shows repeated deep scans are the bottleneck, add an optional cache
later keyed by resolved path, device/inode, size, and modification time. Do not
pay that complexity before evidence supports it.

## Preferred interface

I would replace the plan's `scripts/` directory with this public entry point:

```text
.claude/skills/read-pi-session-traces/
├── SKILL.md
├── references/
│   └── schema.md
└── scripts/
    └── pi-trace.py
```

Conceptual CLI:

```text
pi-trace.py sessions PATH [--json]
pi-trace.py inspect PATH [--session ID] [--outline N] [--json]
pi-trace.py search PATH PATTERN [-e] [-i] [--limit N] [--json]
pi-trace.py show FILE (--entry ID | --line N | --leaf ID)
                 [--before N] [--after N] [--tail N]
                 [--thinking] [--no-tools]
                 [--max-field-chars N] [--max-output-chars N]
                 [--format json|text|markdown]
```

All commands should accept the `sessions/` root, a leaf directory, or a file
where that makes sense. Default text output should be compact and bounded;
`--json`/JSONL should be stable enough to pipe through jq. `show FILE` without a
selector may reasonably default to the final leaf and last 20 entries, but it
must not default to the whole branch. `show --leaf ID --all --format markdown`
can preserve the planned full-transcript use case explicitly.

## Workflow I would use

Starting only with the path from the request:

```bash
# 1. Cheap recursive orientation; no full transcript scans.
scripts/pi-trace.py sessions /Users/lars/.local/state/sbxagent/traces/sbxagent-9df4f2fe/sbxpi/sessions --json

# 2. Locate a topic and receive an entry ID, not a raw giant JSON line.
scripts/pi-trace.py search /Users/lars/.local/state/sbxagent/traces/sbxagent-9df4f2fe/sbxpi/sessions 'search term' --limit 20 --json

# 3. Read only the neighborhood that explains the hit.
scripts/pi-trace.py show /path/from/search.jsonl --entry ENTRY_ID --before 3 --after 6 --format text

# 4. Inspect structure, tools, and recorded usage only for the relevant file.
scripts/pi-trace.py inspect /path/from/search.jsonl --outline 40 --json
```

This sequence keeps discovery cheap, makes every handoff machine-readable, and
never requires a full transcript render merely to understand one event.

## What should remain from the current plan

Keep the corrected schema research, pinned-version policy, raw-history versus
model-context warning, fork double-count warning, image/signature redaction,
recorded-usage caveat, security note, and versioned `schema.md` reference. Those
are valuable format knowledge independent of the executable design.

Replace the decision at lines 129-153 and the implementation sections at lines
285-463. The verification plan should then test one CLI end to end with
committed synthetic fixtures or generated fixtures in a real automated test,
including recursive root discovery, entry-to-show handoff, output budgets,
unknown-record sanitization, malformed lines, partial tails, branches, forked
history, and every usage carrier. The real traces should remain smoke-test
inputs, not the only evidence.
