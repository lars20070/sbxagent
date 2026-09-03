# Add a network-block guard to `sbxcodex`

## Context

When the sandbox network policy blocks a request, the agent must **stop** and
tell the user which host to allow — not retry, mirror, vendor, or quietly drop
the step. Today only `sbxclaude` does anything about this. Its guard is a
root-owned jq filter registered as a Claude Code hook via
`/etc/claude-code/managed-settings.json` (`kits/sbxclaude/spec.yaml:189-291`).
`sbxcodex` only *asks* for the behaviour in prose, with a placeholder comment
where the step would go (`kits/sbxcodex/spec.yaml:194-197`) and instructions that
admit "Nothing enforces this for you here" (`kits/sbxcodex/spec.yaml:58-59`).

`.claude/plans/generalise-sbxclaude-to-sbxagent.md:808` lists this as future
work. Research (`tmp/post-tool-call-hooks.md`) said Codex could reproduce it.
A review (`.cursor/plans/codex-nbg-review.md`) then challenged two claims as
Critical. **I verified both against primary sources, and both challenges were
right.** What survives:

- **Detection parity is real.** Codex's `PostToolUse` fires after `Bash`
  *including on non-zero exit*, and hands the hook the same field names the
  Claude filter already reads (`tool_name`, `tool_input`, `tool_response`). The
  filter haystacks the whole payload after `del(.tool_input)`, so it needs no
  Codex-specific fork.
- **Enforcement parity is NOT real.** Codex's docs state that `continue: false`
  makes Codex "replace the tool result with your feedback or stop text and
  **continue from there**." `decision: "block"` behaves the same way. There is
  no hard turn-end available from `PostToolUse` on Codex — unlike Claude Code,
  where `continue: false` ends the turn outright.
- **`allow_managed_hooks_only` is a top-level key**, not a member of `[hooks]`.
  `openai/codex` `docs/config.md` says verbatim: "Admins can set **top-level**
  `allow_managed_hooks_only = true` in `requirements.toml`", and the source
  (`codex-rs/config/src/config_requirements.rs`, `requirements_layers/stack.rs`)
  reads it from a single-segment path. An earlier draft of this plan had it
  under `[hooks]`, which would have shipped a silently inert key.

**So what we are building is a soft guard**: on a blocked request the tool result
the model sees is replaced with our "Stopping — do not retry, mirror, vendor, or
otherwise work around this" text, and the host to allow surfaces to the user.
The model *can* still choose to continue. That is a real improvement over
nothing, but it is weaker than the Claude guard, and every piece of prose we
write must say so rather than claim parity.

Scope: `sbxcodex` only. `sbxcursor` stays as-is (its post-execution hooks are
observation-only and cannot even inject feedback).

## Changes

### 1. `kits/sbxcodex/spec.yaml` — new setup step

Replace the placeholder comment at `kits/sbxcodex/spec.yaml:194-197` with a new
`setup.install` step, mirroring `kits/sbxclaude/spec.yaml:189-291` position-for-
position (after "GitHub MCP server", before "Ruff"). **No `user:` field**, so it
runs as root.

Safe at that position: it writes only to `/etc/codex/` and
`/usr/local/lib/sbxagent/`, never `~/.codex/config.toml` — so it does not
collide with the replicated seeding step (`kits/sbxcodex/spec.yaml:243-284`)
that truncates `config.toml` and which everything appending to that file must
follow.

The step should:

- `install -d -m 0755 /usr/local/lib/sbxagent /etc/codex`
- Write the jq filter to `/usr/local/lib/sbxagent/network-block.jq` via a
  `<<'JQFILTER'` heredoc — **byte-identical content and delimiter** to
  `kits/sbxclaude/spec.yaml:197-252`, at the same 8-space YAML indent (the lint
  check below depends on both). Same install path as the Claude kit
  deliberately: keeps the kits consistent and lets the toolchain test share one
  `GUARD_FILTER` path.
- Write `/etc/codex/requirements.toml` via a `<<'REQUIREMENTS'` heredoc:

```toml
allow_managed_hooks_only = true

[features]
hooks = true

[hooks]
managed_dir = "/usr/local/lib/sbxagent"

[[hooks.PostToolUse]]
matcher = "^Bash$"

[[hooks.PostToolUse.hooks]]
type = "command"
command = "jq -f /usr/local/lib/sbxagent/network-block.jq"
timeout = 5
```

  - **`allow_managed_hooks_only` must be the first line**, before any `[table]`
    header — TOML scopes bare keys to the table above them, so putting it after
    `[hooks]` silently makes it `hooks.allow_managed_hooks_only`, which Codex
    ignores. This is the failure the self-test below exists to catch.
  - `matcher = "^Bash$"`: Codex has no local `WebFetch`, and hosted tools
    (`WebSearch`) do not fire hooks. Network work here goes through `Bash`
    (curl, npm, pip, git). **Known gap:** `PostToolUse` *does* fire for MCP tools
    (`tool_name` like `mcp__context7__query-docs`), and both kits run network-
    touching MCP servers — so a block surfaced only in an MCP response is missed.
    `sbxclaude`'s `Bash|WebFetch` matcher has the identical gap today; keeping
    the same scope keeps the two kits consistent. Record it as future work.
  - `[features] hooks = true` pins hooks on even if a user disabled them locally.
- `chmod 0644` both files (root-owned implicitly, since no `user:`).
- **Self-tests, mirroring `kits/sbxclaude/spec.yaml:284-290`** — fail the build
  rather than ship a guard that silently does nothing. Under `set -eu`:
  - Parse the TOML with `python3 -c` + `tomllib` (stdlib on this image's Python)
    and assert, structurally: `allow_managed_hooks_only` is `True` **at the top
    level of the parsed dict** (not under `hooks`), `features.hooks` is `True`,
    and `hooks.PostToolUse[0].hooks[0].command` mentions `network-block.jq`. A
    structural check, not a grep — a key in the wrong table is the exact failure
    mode that would otherwise pass unnoticed.
  - The same end-to-end probe the Claude kit uses: pipe a synthetic blocked-host
    payload through the installed filter with `jq -e -f`, so a fail-open filter
    fails the build.

### 2. `kits/sbxcodex/spec.yaml` — agent instructions, worded for a soft guard

`kits/sbxcodex/spec.yaml:58-59`. Do **not** copy sbxclaude's "A managed hook
enforces this: on a block it ends the turn" — on Codex that is false. Replace
"Nothing enforces this for you here, so it is on you: end the turn and report
the blocked host." with something that describes what actually happens, e.g.:

> A managed hook watches for this: on a block it replaces the tool output with
> a stop notice naming the host. It cannot force you to stop, so honour it —
> end the turn and report the host.

This keeps the instruction honest while telling the agent the injected notice is
authoritative.

### 3. Move the dev mirror out of the kit — one copy, not two

The filter is now shared by two kits, so it should exist once, in a neutral
place:

```bash
git mv kits/sbxclaude/files/network-block.jq kits/network-block.jq
```

This also fixes an existing wart: the file never shipped (kit `files/` can only
be delivered as the agent user; the guard must be root-owned), yet it sat inside
a `files/` directory that implies it does — which is why its header comment has
to spend four lines saying "NOT shipped". Only `files/home/` and
`files/workspace/` subtrees are injected into a sandbox, so a file at the
`files/` root had no defined destination anyway.

`kits/network-block.jq` is a sibling of the kit directories, so it does not
disturb the Makefile's `for kit in kits/*/` loops (the trailing slash matches
directories only) or `kits/*/spec.yaml` globs. `git ls-files -- '*.jq'` still
picks it up for the syntax check at `Makefile:22`.

Update the file's own header comment: it currently names
`kits/sbxclaude/spec.yaml` as the sole shipping copy and gives a `jq -f
kits/sbxclaude/files/network-block.jq` test line. Both need to name the new path
and both kits. Add a line noting the output is read differently by each host CLI
— a hard turn-end on Claude Code, replaced-tool-result feedback on Codex. Keep
the `# BEGIN-SYNCED` / `# END-SYNCED` markers unchanged.

Also update the pointer comment inside `kits/sbxclaude/spec.yaml:193-196`, which
reads "Kept in sync with `kits/sbxclaude/files/network-block.jq` — make lint
checks this." Give the new Codex step the same comment, both naming
`kits/network-block.jq`.

### 4. `Makefile` — generalise the sync check

`Makefile:49-58` currently hardcodes both sbxclaude paths. Rewrite as a loop over
`kits/*/spec.yaml` that skips specs with no `JQFILTER` heredoc (sbxcursor), and
for each remaining spec asserts its heredoc matches the single
`kits/network-block.jq`. One reference file, one loop — which transitively
guarantees the two kits' heredocs match each other too.

Reuse the existing extraction logic verbatim — `awk '/<<.JQFILTER./{f=1; next}
/^        JQFILTER$$/{f=0} f'` + `sed 's/^        //'` for the heredoc side, and
`sed -n '/^# BEGIN-SYNCED/,/^# END-SYNCED/p' | sed '1d;$$d'` to strip the
markers from the reference — only the spec path becomes a loop variable. This is
why the Codex heredoc must use the same `JQFILTER` delimiter and 8-space indent.

Failure message should name the offending spec, e.g.
`lint: <spec> is out of sync with kits/network-block.jq`.

Update the `lint` header comment (`Makefile:9-18`), which says "the dev-only
copy" singular.

### 5. `tests/toolchain_test.sh` — three blocks, explicitly

Today guard behaviour, managed-settings registration, and Claude MCP assertions
all sit inside one `if KIT_NAME == sbxclaude` block (`:136-266`). Since both kits
now install the *same filter at the same path*, split into three gates — writing
the control flow out here so coverage cannot be lost by a careless split:

```bash
if [[ "${KIT_NAME}" == "sbxclaude" || "${KIT_NAME}" == "sbxcodex" ]]; then
    # GUARD_FILTER path; guard / check_guard_blocks / check_guard_ignores
    # helpers (:163-188); all eight behavioural cases (:190-231).
    # The WebFetch cases stay here: they prove the shared filter is identical,
    # not that Codex has a WebFetch tool.
fi

if [[ "${KIT_NAME}" == "sbxclaude" ]]; then
    # MANAGED_SETTINGS assertions (:147-161), incl. the
    # PostToolUse/PostToolUseFailure loop, plus the ~/.claude.json MCP
    # assertions (:233-264) — unchanged, just no longer wrapping the above.
fi

if [[ "${KIT_NAME}" == "sbxcodex" ]]; then
    # Existing config.toml / MCP / seeding assertions (:273-307), plus new:
    # /etc/codex/requirements.toml exists, parses as TOML, registers a
    # PostToolUse hook whose command mentions network-block.jq, and sets
    # allow_managed_hooks_only at the TOP LEVEL (assert the parsed key is not
    # nested under hooks — same trap as the setup self-test).
fi
```

Use `${REBUILD_HINT}` (`:127`) in new failure messages and `pass` on success, to
match the existing style. Rewrite both banner comments (`:129-135`, `:268-272`),
which currently state Codex ships no guard.

### 6. Docs — describe a soft guard, not parity

- `README.md:65-69` — Supported agents table: `sbxcodex`'s "Network-block guard"
  cell `no` → `yes (soft)`. Not a bare `**yes**`: that column currently implies
  Claude's hard stop.
- `README.md:71-75` — rewrite the "exists only for `sbxclaude`" paragraph to
  state three things plainly: `sbxclaude` hard-ends the turn; `sbxcodex` replaces
  the blocked tool's result with a stop notice but cannot force the agent to
  stop, because Codex's `PostToolUse` has no turn-ending output; `sbxcursor` has
  neither. Name the MCP coverage gap (shared by both guards) here too.
- `README.md:93-94` — the "`sbxclaude` only:" bullet → both commands, with the
  same soft/hard distinction.
- **Call out the stricter lockdown**: `allow_managed_hooks_only = true` means
  `sbxcodex` ignores *all* user, project, session and plugin hooks — deliberate,
  but stricter than `sbxclaude`, which leaves user hooks alone. Say so in the
  README and the CHANGELOG entry so it is not an unnoticed side effect.
- `CHANGELOG.md` — new bullet under `## [Unreleased]` / `### Added`, matching the
  voice of the original guard entry (`CHANGELOG.md:104-108`), and honest about
  the soft stop. `CHANGELOG.md:54-57` records the old "sbxclaude only" claim;
  that's historical and stays, the new entry supersedes it. The
  `network-block.jq` move is a developer-facing refactor, so per `AGENTS.md` it
  needs no entry of its own.
- `.cspell.json` — add any new words (e.g. `tomllib`, `PostToolUse` if not
  already accepted).

## Verification

```bash
make lint          # jq syntax + the generalised sync check
make validate      # all three kit specs against the schema
make test-unit     # wrapper dispatch, unaffected but must stay green
```

Then rebuild and exercise the real sandbox — `setup:` runs only on create, so
re-attaching would test the old kit:

```bash
sbxcodex rm && sbxcodex create
make test-toolchain AGENT=codex
make test-toolchain AGENT=claude   # regression: the test split must not drop coverage
```

Manual checks the suite cannot cover:

- The agent (uid 1000) **cannot** edit `/etc/codex/requirements.toml` or
  `/usr/local/lib/sbxagent/network-block.jq`.
- Codex reports the guard as a **managed** hook (hook browser / `codex` config
  dump) — this is what proves the admin tier and the top-level
  `allow_managed_hooks_only` key actually took effect. If the hook shows as
  user-scoped or absent, the key placement or `[features] hooks` pin is wrong.
- **Trigger a real block** — `curl` a host that is not on the allowlist and
  observe what the agent actually receives and does. Expect the tool result to be
  replaced by the stop notice naming the host, and the `sbx policy allow network
  "<host>"` line to reach the user. Confirm the agent does not then try a mirror.
  If it does work around the block anyway, that is the known soft-stop limit, not
  a bug in the wiring — and the fallback to weigh is a complementary `PreToolUse`
  deny (the one Codex output that *can* hard-block), which is out of scope here
  because it must guess the host from the command text before the command runs.
