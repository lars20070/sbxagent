# Route each agent's session traces into `${PROJECT_DIR}/${SELF}`

## Context

Commit `fa1aee1` gave every sandbox a wrapper-managed state folder:
`PROJECT_DIR` (`${XDG_STATE_HOME:-~/.local/state}/sbxagent/<slug>-<hash>`)
mounted read-only, and this agent's own `AGENT_DIR` (`${PROJECT_DIR}/${SELF}`)
mounted read-write, at the same absolute path inside the sandbox as on the
host. Today nothing writes into it.

This makes each of the four agents write its session traces there, using
its own native on-disk layout, so the host (and, with
`CROSS_SANDBOX_VISIBILITY=true`, sibling sandboxes for the same project) can
read them live. No new trace format, no wrapper-side tailing — the agents'
default files, in the agents' default shape, rooted one level lower.

**Lifecycle, stated once.** `create` (or the first attach) installs the
environment variable and the mounts. The kit entrypoint performs the
linking on the first agent run. `exec` alone never runs the entrypoint. So:
a sandbox that exists today has neither the variable nor the link and must
be rebuilt (`rm`, then `create`/attach) to gain this feature; a sandbox that
was only `create`d links on its first attach; no attach-time repair logic is
added.

## Research: how each agent writes traces today

| Agent | Default trace location (in-sandbox `$HOME`) | Format | Native way to relocate **only** traces | Verdict |
| --- | --- | --- | --- | --- |
| Claude Code | `~/.claude/projects/<encoded-cwd>/<session-uuid>.jsonl` | JSONL, append-only, one file per session | **None.** `CLAUDE_CONFIG_DIR` moves all of `~/.claude` (settings, history, credentials) and has a reported MCP-loading bug; `~/.claude.json` sits outside it. `CLAUDE_CODE_PROJECT_DIR_NAME` only renames the per-project folder. | Symlink `~/.claude/projects` |
| Codex | `~/.codex/sessions/YYYY/MM/DD/rollout-<ts>-<uuid>.jsonl` | JSONL, append-only | **None.** `CODEX_HOME` moves all of `~/.codex` (config.toml, auth.json — both seeded by the parent kit). `CODEX_ROLLOUT_TRACE_ROOT` writes debug bundles, a different thing. | Symlink `~/.codex/sessions` (the recipe from the recovered `tmp/codex-traces.md`, commit `3008aa4`) |
| Cursor CLI | Transcripts: `~/.cursor/projects/<encoded-cwd>/agent-transcripts/…jsonl` ("Claude Code-compatible JSONL", changelog Apr 2026; "persist to disk for tooling and hooks", Jan 2026). Resume store: `~/.cursor/chats/<hash>/<id>/store.db` (SQLite, undocumented). | JSONL + SQLite | **None documented.** | Symlink `~/.cursor/projects` only. The SQLite store stays in-sandbox (decided: SQLite over virtiofs is a locking hazard). |
| Pi | `~/.pi/agent/sessions/--<encoded-cwd>--/<ts>_<id>.jsonl` (encoding from `dist/core/session-manager.js:242` in the pinned 0.84.4) | JSONL, append-only, tree-structured | **Yes, but it changes the layout:** `PI_CODING_AGENT_SESSION_DIR` (= `--session-dir`) is used *flat* — no per-cwd folder — and `--continue` switches to a cwd-filtered lookup (`session-manager.js:1217-1219`). | Symlink `~/.pi/agent/sessions` (decided): identical default behaviour, one code path for all four. |

Two facts that shape the design:

- **Claude Code's `cleanupPeriodDays` (default 30) deletes old transcripts
  on startup.** Through the symlink that deletes host files. Decided: keep the
  default; document it. Never set it to `0` — a known bug makes `0` stop
  transcript writing entirely.
- **`~/.cursor/projects/<slug>/` is not transcripts-only.** The parent
  `cursor` kit seeds `.workspace-trusted` there, and this kit's own startup
  step writes `mcp-approvals.json` there, both before any entrypoint runs.
  So the helper must migrate an existing real directory. This is the *only*
  migration the helper supports; it is not a general sync facility.

## Design decisions

1. **The sandbox learns `AGENT_DIR` through one env var, `SBXAGENT_STATE_DIR`.**
   Inside the sandbox `$HOME` is `/home/agent`, so the host path cannot be
   derived; the wrapper passes it. `sbx run --help` (checked): `-e KEY=VALUE`
   "applies to the agent session, so it takes effect on a re-attach too; also
   baked into the sandbox when this run creates it" — passed at create time
   only, on the two creating paths. When the variable is absent (plain `sbx
   run`, or `make test-unit`'s fake), every kit keeps the agent's stock
   location — nothing changes.

2. **Linking happens in each kit's entrypoint.** Startup steps run with a
   minimal environment (the cursor kit's startup comment documents `HOME`/
   `PATH` missing) and it is unverified whether `-e` vars reach them; the
   entrypoint is where `sbx` guarantees the agent-session env, and the mount
   is in place by then. The link is a filesystem fact, so once made it also
   serves an agent launched by hand from `exec bash`.

3. **One shared POSIX-sh helper, shipped as a kit file, not a root heredoc.**
   No security role, so no need to be root-owned. Ships as
   `files/home/.local/lib/sbxagent/link-state.sh` in every kit, added to
   `make lint`'s shared-files loop (byte-identical across kits, existing
   convention). Invoked as `sh <path> LINK SUBDIR` so it does not depend on
   the copy preserving an executable bit.

4. **Native layout under `AGENT_DIR`.** The subfolder name is the agent's own
   (`projects`, `sessions`):

   ```
   ~/.local/state/sbxagent/sbxagent-3f9a1c/
   ├── sbxclaude/projects/-Users-lars-Code-sbxagent/<uuid>.jsonl
   ├── sbxcodex/sessions/2026/09/12/rollout-<ts>-<uuid>.jsonl
   ├── sbxcursor/projects/Users-lars-Code-sbxagent/agent-transcripts/…
   │                                          ├── mcp-approvals.json
   │                                          └── .workspace-trusted
   └── sbxpi/sessions/--Users-lars-Code-sbxagent--/<ts>_<id>.jsonl
   ```

   What is preserved is the layout *beneath the relocated root*: any tool
   that accepts a trace root, or is pointed at the per-agent state
   directory, consumes the agent's native layout unchanged. (The host's own
   `~/.claude/projects` etc. are not touched or redirected.)

5. **The helper is non-destructive.** The original path is never deleted
   until the replacement symlink exists; on any failure the original is put
   back and the message says what state the path is in. Concretely:

   - Already the right symlink → exit 0.
   - A symlink to *anything else* → refuse, leave it untouched, exit 1
     with a message naming both targets. (Conservative rule; nothing in
     this repo creates such a link.)
   - A real directory → copy its contents into the target, *rename* the
     directory aside (`mv` within the same filesystem, atomic), create the
     symlink, then delete the renamed copy. If the symlink cannot be
     created, rename the directory back and exit 1: the agent's stock
     location is intact and the message says so. If the copy fails, nothing
     has been moved yet; exit 1.
   - Nothing at the path → create parent dirs, create the symlink.

   **Merge policy on collision (decided):** when a file exists both in the
   real directory and already in the target (a sandbox re-created after
   `rm`, state having survived on the host), the **sandbox's copy wins**.
   The sandbox being created is authoritative for its own config files
   (`.workspace-trusted`, `mcp-approvals.json` — the latter is regenerated
   by the startup step every start anyway); transcripts never collide (UUID
   / timestamp names). `cp -R src/. dst/` does exactly this. `-R`, not
   `-a`: `-a` tries to preserve ownership, which a virtiofs mount may
   refuse.

6. **Entrypoint calls are soft-failed, and the message is honest.** The
   helper prints the precise resulting state on every non-zero path; the
   entrypoint adds only `"<kit>: trace folder not linked (see above);
   continuing"` and `exec`s the agent regardless. A broken link never makes
   a sandbox unusable.

7. **`CROSS_SANDBOX_VISIBILITY` is unchanged.** It only decides whether
   `PROJECT_DIR:ro` is mounted; `AGENT_DIR` and `SBXAGENT_STATE_DIR` are
   passed in both modes.

## Stages

Three stages, each independently green (`make lint`, `make test-unit`) and
each a reasonable commit. Stage 3 is the only one that touches kit specs
and therefore the only one that needs `make validate` and a host check.

### Stage 1 — the helper, with its own unit test

Nothing calls it yet. No kit spec, wrapper, or docs change.

**`kits/sbxclaude/files/home/.local/lib/sbxagent/link-state.sh`** (and
byte-identical copies in `sbxcodex`, `sbxcursor`, `sbxpi`):

```sh
#!/bin/sh
# Point an agent's trace folder at this sandbox's state mount.
# Usage: sh link-state.sh LINK SUBDIR
#   LINK    the agent's stock trace folder, e.g. ~/.codex/sessions
#   SUBDIR  the folder under $SBXAGENT_STATE_DIR to link it to
# No-op without SBXAGENT_STATE_DIR, so a sandbox created by plain `sbx run`
# keeps the agent's default location. Idempotent. The only migration it
# knows is a real directory at LINK (the cursor parent kit seeds files
# there): its contents are copied into the target, the sandbox's copy
# winning on a name clash, and the directory is renamed aside until the
# symlink exists, so a failure leaves the stock location intact.
set -eu
[ -n "${SBXAGENT_STATE_DIR:-}" ] || exit 0
link="$1"
target="${SBXAGENT_STATE_DIR}/$2"

if [ -L "$link" ]; then
	current="$(readlink "$link")"
	if [ "$current" = "$target" ]; then
		exit 0
	fi
	echo "link-state: $link is already a symlink to $current, not $target; left untouched" >&2
	exit 1
fi

mkdir -p "$target"
if [ -d "$link" ]; then
	aside="$link.sbxagent-aside"
	if [ -e "$aside" ]; then
		echo "link-state: $aside exists from an earlier interrupted run; remove it by hand. $link left untouched" >&2
		exit 1
	fi
	if ! cp -R "$link"/. "$target"/; then
		echo "link-state: could not copy $link into $target; $link left untouched" >&2
		exit 1
	fi
	mv "$link" "$aside"
	if ! ln -s "$target" "$link"; then
		mv "$aside" "$link"
		echo "link-state: could not create symlink $link; original directory restored" >&2
		exit 1
	fi
	rm -rf "$aside"
	exit 0
fi

parent="$(dirname "$link")"
mkdir -p "$parent"
if ! ln -s "$target" "$link"; then
	echo "link-state: could not create symlink $link; nothing changed" >&2
	exit 1
fi
```

(`set -e` plus explicit `if ! cmd` on every step that has a rollback, so
the rollback actually runs. `mv` on the aside step is bare: same
filesystem, same directory, and if it fails `set -e` stops before anything
is removed. `parent=` is a separate assignment because the repo's
`shellcheck --enable=all` flags a `$(…)` inside an argument as a masked
return.)

**`tests/link_state_test.sh`** — new, host-side, `bash`, same
`pass`/`fail` style as `tests/sbxagent_test.sh`. Runs the helper with
`sh`, against a `mktemp -d` root, with `SBXAGENT_STATE_DIR` set to
`"${TEST_ROOT}/state"` unless a case says otherwise. Cases:

1. **No env var** — `SBXAGENT_STATE_DIR` unset: exit 0, `LINK` untouched,
   no `state/` created.
2. **First link** — nothing at `LINK`, parent dir absent: exit 0, `LINK` is
   a symlink to `state/sub`, `state/sub` exists.
3. **Repeat** — run again: exit 0, target unchanged, no `.sbxagent-aside`.
4. **Real-directory migration** — `LINK` is a dir holding a file, a dotfile,
   and a nested dir with a file: exit 0, all three readable through
   `LINK/`, `LINK` is a symlink, no `.sbxagent-aside` left.
5. **Collision policy** — `state/sub/a/x` exists with content `old`,
   `LINK/a/x` with `new`: after the run `LINK/a/x` reads `new`. Also a
   file only in `state/sub` survives (merge, not replace).
6. **Unexpected symlink** — `LINK` → some other dir: exit 1, still points
   at the other dir, target dir *not* created (the check runs before
   `mkdir -p`), stderr mentions "left untouched".
7. **Symlink creation fails** — put a fake `ln` (`exit 1`) first on `PATH`,
   `LINK` a real dir with a file: exit 1, `LINK` is still a real directory
   with the file, no `.sbxagent-aside`, stderr mentions "restored".
8. **Copy fails** — `state/sub` created read-only (`chmod 555`), `LINK` a
   real dir with a file: exit 1, `LINK` still a real dir, no aside, stderr
   mentions "left untouched". (Skip with a note if running as root, where
   `chmod 555` does not deny writes.)
9. **Leftover aside** — `LINK.sbxagent-aside` pre-exists, `LINK` a real
   dir: exit 1, both untouched, stderr mentions "interrupted run".

**`Makefile`**: `test-unit` runs both scripts; the `lint` shared-files list
gains `home/.local/lib/sbxagent/link-state.sh`. `'*.sh'` already puts the
helper and the test under `shellcheck --enable=all` and `bash -n`.

Verify: `make lint`, `make test-unit`, `make test-unit BASH=/bin/bash`.

### Stage 2 — the wrapper hands the path to the sandbox

**`scripts/sbxagent`**: both creating call sites gain `-e
"SBXAGENT_STATE_DIR=${AGENT_DIR}"` after `--name "${SANDBOX}"`. One
sentence in the `compute_state_mounts` header comment: the same path is
exported into the sandbox as `SBXAGENT_STATE_DIR` for the kits' trace
folders.

**`tests/sbxagent_test.sh`**: every create/attach `assert_log` (the two
Claude ones, codex, cursor, pi, `WORK_B`, empty-slug, the two
`CROSS_SANDBOX_VISIBILITY=false` cases) gains
`\t-e\tSBXAGENT_STATE_DIR=%s` after `--name\t%s`, with that call's
`AGENT_DIR`. One pattern, nine sites.

Verify: `make lint`, `make test-unit`. Nothing observable changes yet (no
kit reads the variable), so this stage is safe to commit alone.

### Stage 3 — kits link, tests assert, docs describe

**Kit entrypoints.** Same line shape in all four, before the `exec`:

```sh
# <stock path>: no native sessions-only override (CLAUDE_CONFIG_DIR would
# drag settings and credentials along), so a symlink into the state mount.
sh "$HOME/.local/lib/sbxagent/link-state.sh" "$HOME/.claude/projects" projects ||
  echo "sbxclaude: trace folder not linked (see above); continuing" >&2
```

- `sbxclaude`: `"$HOME/.claude/projects" projects`
- `sbxcodex`: `"$HOME/.codex/sessions" sessions` (comment: `CODEX_HOME`
  would drag config.toml and auth.json along)
- `sbxcursor`: `"$HOME/.cursor/projects" projects` (comment: no knob at all;
  the SQLite resume store under `~/.cursor/chats` deliberately stays
  in-sandbox)
- `sbxpi`: replace `entrypoint: [pi]` with the sibling `sh -c` shape and
  `"$HOME/.pi/agent/sessions" sessions` (comment: `PI_CODING_AGENT_SESSION_DIR`
  exists but flattens the layout and changes `--continue`). Update the
  comment above it, which currently says a plain entrypoint is right
  because there is nothing to wrap.

**`tests/toolchain_test.sh`**: in the shared section,
`STATE_KEY="${SANDBOX_NAME#*-}"`. In each kit block, the same four lines
with the kit's `LINK` and subfolder:

```bash
LINK="${HOME}/.claude/projects"
[[ -L "${LINK}" ]] || fail "${LINK} is not a symlink — the kit entrypoint links it on the first agent run; attach once, then rerun (an older sandbox needs a rebuild)"
[[ "$(readlink "${LINK}")" == */sbxagent/"${STATE_KEY}"/"${KIT_NAME}"/projects ]] ||
	fail "${LINK} points at $(readlink "${LINK}"), not this sandbox's state folder"
[[ -w "${LINK}/" ]] || fail "${LINK} is not writable through the link"
pass "${LINK} is linked into the state mount"
```

The existing cursor `mcp-approvals.json` assertion now resolves through the
symlink; it still passing is the migration's live proof.

**`docs/toolchain.md`**: a "Session traces" subsection after the
state-folder paragraph — one table (agent, stock path, path under the
per-agent state folder) and three notes: the lifecycle paragraph from
Context (create installs, first run links, existing sandboxes need a
rebuild); Claude Code prunes transcripts older than `cleanupPeriodDays`
(default 30), now including the host copies; Cursor's `agent resume` store
stays inside the sandbox.

**`README.md`**: one sentence under "Supported agents" linking to that
table. No new column.

**`CHANGELOG.md`**, `## [Unreleased]` → `### Added`: every kit now writes
the agent's session traces into the sandbox's state folder in the agent's
own layout (Claude Code `projects/`, Codex `sessions/`, Cursor `projects/`,
Pi `sessions/`), readable live from the host; existing sandboxes need a
rebuild to pick this up.

**`.cspell.json`**: add only what the final `make lint` actually rejects.

Verify:

1. `make lint`, `make test-unit`, `make validate`.
2. **Host smoke, one per agent** (yours, on the Mac): in a project,
   `sbx<kit> rm; sbx<kit>`, ask something trivial, exit, then

   ```bash
   STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}/sbxagent"
   S="$(sbx<kit> name)"; find "${STATE_HOME}/${S#*-}/<kit>" -name '*.jsonl' | head
   ```

   Expect a file under `sbxclaude/projects/…`, `sbxcodex/sessions/…`,
   `sbxcursor/projects/…/agent-transcripts/…`, `sbxpi/sessions/…`. Then
   `make test-toolchain AGENT=<kit>`.
3. **Resume checks where relocation could change lookup** — not Claude:
   `sbxcodex exec codex resume` lists the session (archiving may say
   "cross-device link"; harmless, documented); `sbxcursor exec agent ls`
   lists the chat and `agent mcp list` still shows both servers approved
   (the migration kept `mcp-approvals.json`); `sbxpi` `--continue` picks
   up the session.
4. **Visibility**: from `sbxcodex exec bash`, `ls
   "${STATE_HOME}/${S#*-}/sbxclaude/projects"` lists Claude's folder,
   read-only. Then `sbxcodex rm; CROSS_SANDBOX_VISIBILITY=false sbxcodex
   create` and confirm the path does not exist inside — and that flipping
   the variable *without* the `rm` changed nothing, which is the create-time
   rule.

If Cursor rejects a symlinked `~/.cursor/projects`, the fallback is one
level deeper (`~/.cursor/projects/<slug>/agent-transcripts`), which needs
the slug computed in the entrypoint from `$PWD` — the same `/`→`-` rule the
kit's startup step relies on implicitly. Not planned unless the smoke check
forces it.

## Not addressed here

Review point 1 (documenting that with visibility on, siblings can read
full conversations, and that the switch is create-time) is out of this
plan's scope as requested; it is a documentation-only change that fits
naturally into the Stage 3 `docs/toolchain.md` subsection if wanted.
