# Mount a per-project state folder tree, shared read-only across agents

## Context

`tmp/codex-traces.md` documents a manual recipe for watching Codex's session
traces from the host: mount a second host folder into the sandbox alongside
the workspace, at the same absolute path on both sides. Today
`scripts/sbxagent` only ever mounts one path (the project directory) — every
extra-mount workflow has to be done by hand, bypassing the wrapper (`sbx
create` / `sbx run` called directly).

This task lays the foundation for that: give every sandbox a second mount
rooted at

```
STATE_HOME="${XDG_STATE_HOME:-${HOME}/.local/state}/sbxagent"
```

XDG reserves `$XDG_STATE_HOME` for exactly this kind of data (logs, history,
state), and this repo already uses that same base path in
`tmp/codex-traces.md`.

The design goal, refined over two earlier drafts: sandboxes for **the same
project directory** — whether created by `sbxclaude`, `sbxcodex`,
`sbxcursor`, or `sbxpi` — should be able to see each other's state, so one
agent can read another's session data for that project (wiring up any
particular tool's symlink, e.g. Codex's `~/.codex/sessions`, is still
explicit future work). Sandboxes for **different** projects must never see
each other's state at all, and no sandbox may write into another agent's
folder.

This supersedes both prior drafts. One mounted all of `STATE_HOME` read-only
into every sandbox on the host — too broad, it exposed unrelated projects.
The other globbed for sibling folders at create time and mounted each one
individually — but mounts are fixed at creation, so a sandbox created
*before* a sibling existed would never see it. This draft gets both
properties at once, and is simpler than either: nest the mount **per
project**, not per-host, so siblings that appear later are visible through
the parent mount without re-creating anything.

**Note on consolidation:** this plan replaces
`.claude/plans/let-state-home-xdg-state-home-home-local-buzzing-nautilus.md`
outright. Plan mode restricts editing to this file, so as the first step of
implementation, delete that old plan file so only this one remains.

## Design decisions

1. **Folder layout**, one path added per sandbox-creating call:

   ```
   PROJECT_KEY="${SLUG:+${SLUG}-}${HASH}"      # same convention SANDBOX already uses
   PROJECT_DIR="${STATE_HOME}/${PROJECT_KEY}"  # one folder per project, shared by all agents
   AGENT_DIR="${PROJECT_DIR}/${SELF}"          # one subfolder per agent, e.g. .../sbxclaude
   ```

   `SLUG` and `HASH` are the same values already computed for `SANDBOX`
   (`SANDBOX="${SELF}-${SLUG:+${SLUG}-}${HASH}"`) — `PROJECT_KEY` is just
   that same suffix, reused so a project's key doesn't depend on which agent
   is asking. The `${SLUG:+${SLUG}-}` guard is carried over unchanged: it's
   what already makes an empty sanitized basename (e.g. a directory named
   only punctuation) collapse to `HASH` alone instead of a leading `-HASH`.

   Example, on a host where `sbxclaude` and `sbxcodex` have each been run
   in `~/Code/sbxagent`, and `sbxclaude` alone in `~/Code/other-app`
   (default `XDG_STATE_HOME`, illustrative hashes):

   ```
   ~/.local/state/sbxagent/           # STATE_HOME  — never mounted
   ├── sbxagent-3f9a1c/               # PROJECT_DIR — mounted :ro into every
   │   ├── sbxclaude/                 #   sandbox for ~/Code/sbxagent
   │   │   └── ...                    # AGENT_DIR   — mounted rw only into
   │   └── sbxcodex/                  #   sandbox sbxclaude-sbxagent-3f9a1c
   │       └── ...                    # AGENT_DIR   — mounted rw only into
   │                                  #   sandbox sbxcodex-sbxagent-3f9a1c
   └── other-app-b72e04/              # PROJECT_DIR for ~/Code/other-app —
       └── sbxclaude/                 #   invisible to both sandboxes above
           └── ...
   ```

   Inside the `sbxcodex-sbxagent-3f9a1c` sandbox, that means:
   `~/.local/state/sbxagent/sbxagent-3f9a1c/sbxclaude/` is readable,
   `~/.local/state/sbxagent/sbxagent-3f9a1c/sbxcodex/` is writable, and
   `~/.local/state/sbxagent/other-app-b72e04/` does not exist at all.

2. **Mount `PROJECT_DIR` read-only, `AGENT_DIR` read-write**, passed as two
   separate, ordered positional arguments — parent path first, more-specific
   (nested) path second — mirroring ordinary bind-mount stacking, where a
   mount targeting a more specific path shadows the outer mount for that
   subtree:

   ```
   . "${PROJECT_DIR}:ro" "${AGENT_DIR}"
   ```

   Every sandbox for this project, regardless of which of the four agent
   CLIs created it, can therefore read every other agent's folder under
   `PROJECT_DIR`, and can write only inside its own `AGENT_DIR`. This is the
   same nested-mount pattern the very first draft used for the whole of
   `STATE_HOME` — narrowed here to one project's subtree, which is also why
   its correctness still needs a real-host check (see Verification): `sbx
   create --help`/`sbx run --help` document that `[PATH...]` accepts
   multiple extra paths, each independently markable `:ro`, but not what
   happens when one is nested inside another. That can't be verified from
   inside this sandbox (sandbox management needs the host CLI).

   Note the leading `.`: the `create` call already passes it today, but the
   `run` call at `scripts/sbxagent:136` does not — it relies on `sbx run`
   defaulting the workspace to the cwd. Extra paths can only follow an
   explicit workspace operand, so this plan **adds `.` to the `run` call**.
   Same effective workspace, one more argv token; the unit test for that
   path must expect it.

3. **`STATE_HOME` itself is never mounted** — only `PROJECT_DIR`, one
   subfolder of it, is. A sandbox for project A never has any path under
   project B's `PROJECT_DIR` mounted, read-only or otherwise, satisfying "do
   not mount the entire `STATE_HOME` folder."

4. **No sibling discovery/glob logic needed.** Because the read-only mount
   is always "this project's folder" rather than "the whole state tree minus
   some exclusions," whichever other agents have a folder under
   `PROJECT_DIR` are visible through the parent mount — there is nothing to
   enumerate, and no dependency on which of the four agent names exist.
   This holds for folders that appear **after** a sandbox was created, too:
   the host creating `PROJECT_DIR/sbxcodex` later is just a new entry in an
   already-mounted directory, so an older `sbxclaude` sandbox for the same
   project sees it without being re-created. That is the property the glob
   draft could not provide.

5. **Permissions:** `chmod 700` on `AGENT_DIR` only — same host
   defense-in-depth rationale as prior drafts (it's where this agent's own
   output for this project lands). `PROJECT_DIR` is left at whatever `mkdir`
   produces by default; it holds no output of its own, only per-agent
   subfolders that carry their own mode. As before, this chmod is
   host-level defense-in-depth against a different OS account on a shared
   machine — it does not, and is not meant to, enforce the read-only/
   read-write split between sandboxes (the nested mount above does that);
   all sandboxes on one host run as the same host user regardless of this
   folder's mode. That last sentence is an assumption about the sandbox's
   uid mapping — if it's wrong, `700` would stop a sibling sandbox from
   reading this folder, silently defeating the point. The host check in
   Verification reads a real file across sandboxes for exactly this reason;
   if that read fails while the folder is visible, relax the mode and
   re-run.

6. **Computed only in the two sandbox-creating branches** (the
   attach-or-create default when the sandbox is missing, and the explicit
   `create` subcommand) — not unconditionally at the top of the script.
   Read-only subcommands (`name`, `version`, `help`, `inspect`, `rm`,
   `exec`, `policy ...`) never touch the filesystem or require `HOME`/
   `XDG_STATE_HOME` to be set.

7. **`XDG_STATE_HOME` validated as absolute before use**, unchanged from
   prior drafts: the XDG Base Directory spec requires these variables to be
   absolute and says a relative value must be treated as unset. If neither
   `XDG_STATE_HOME` nor `HOME` is set, the script's existing `set -u` makes
   `${HOME}` abort with "HOME: unbound variable" — loud and correct, no
   extra handling added.

## Changes

### `scripts/sbxagent`

New helper function (near the other helpers, e.g. after `require_sbx`):

```bash
# Sets STATE_HOME, PROJECT_DIR, and AGENT_DIR. PROJECT_DIR is shared by every
# agent's sandbox for this same project (same SLUG+HASH); AGENT_DIR is this
# agent's own subfolder within it. STATE_HOME itself is never mounted.
compute_state_mounts() {
	case "${XDG_STATE_HOME:-}" in
	/*) STATE_HOME="${XDG_STATE_HOME}/sbxagent" ;;
	*) STATE_HOME="${HOME}/.local/state/sbxagent" ;;
	esac
	PROJECT_DIR="${STATE_HOME}/${SLUG:+${SLUG}-}${HASH}"
	AGENT_DIR="${PROJECT_DIR}/${SELF}"
	mkdir -p "${AGENT_DIR}"
	chmod 700 "${AGENT_DIR}"
}
```

(`mkdir -p "${AGENT_DIR}"` alone creates `STATE_HOME` and `PROJECT_DIR` too,
so no separate `mkdir -p "${STATE_HOME}"`/`"${PROJECT_DIR}"` calls are
needed.)

In the `""` (attach-or-create) branch (currently lines 135–136):

```bash
sbx kit validate "${KIT}" >/dev/null
compute_state_mounts
exec sbx run --name "${SANDBOX}" "${KIT}" . "${PROJECT_DIR}:ro" "${AGENT_DIR}"
```

In the `create` subcommand (currently lines 167–171):

```bash
create)
	shift
	no_args create "$@"
	require_sbx
	compute_state_mounts
	exec sbx create --name "${SANDBOX}" "${KIT}" . "${PROJECT_DIR}:ro" "${AGENT_DIR}"
	;;
```

The re-attach path (existing sandbox, no `KIT`/paths passed) and `rm` are
unchanged — mounts are fixed at creation time, and `rm` never touches
`STATE_HOME` (the shared project folder and this agent's subfolder are both
left behind deliberately; nothing in this task asks for cleanup on `rm`).

### `tests/sbxagent_test.sh`

Because the two extra mount arguments are now always the same fixed shape —
`PROJECT_DIR` and `AGENT_DIR`, never a variable-length list — the existing
tests need no restructuring into fresh per-kit directories the way a
sibling-glob design would have. All four kits' create/attach tests already
share `WORK_A`, and that's fine: they all resolve to the same `PROJECT_DIR`
(same `SLUG`+`HASH`) with different `AGENT_DIR`s.

1. Export an isolated `XDG_STATE_HOME` in test setup so tests never touch the
   real machine's state:

   ```bash
   export XDG_STATE_HOME="${TEST_ROOT}/xdg-state"
   STATE_ROOT="${XDG_STATE_HOME}/sbxagent"
   ```

2. Derive the expected paths from the already-asserted sandbox name, right
   after `SANDBOX="${NAME_A}"` (~line 195). No new helper: `NAME_A` is
   already checked against `^sbxclaude-<slug>-[0-9a-f]{6}$`, and the
   wrapper builds `PROJECT_KEY` from the very same `SLUG`/`HASH`, so
   stripping the agent prefix is exactly the wrapper's own arithmetic:

   ```bash
   PROJECT_DIR="${STATE_ROOT}/${NAME_A#*-}"   # sbxclaude-api-3f9a1c -> api-3f9a1c
   ```

   Every kit's `AGENT_DIR` for `WORK_A` is then `"${PROJECT_DIR}/sbxclaude"`,
   `"${PROJECT_DIR}/sbxcodex"`, etc. — the same `PROJECT_DIR` for all four,
   which is itself the invariant under test. Use `#*-` (first dash), not
   `#sbxclaude-`, so the expression matches how the wrapper and the host
   check in Verification carve the name.

3. Update the existing `assert_log` expectations. Two shapes:

   - "new sandbox attach" (~204): the `run` line gains **three** tokens —
     `\t.\t%s:ro\t%s` — because `.` is new on that call (see design
     decision 2). Expected: `run\t--name\tS\tKIT\t.\tPROJECT_DIR:ro\tAGENT_DIR`.
   - The four `create` cases ("create" ~241, "codex create" ~321, "cursor
     create" ~359, "pi create" ~396) already end in `\t.`; each gains
     `\t%s:ro\t%s` with `"${PROJECT_DIR}"` and that kit's `AGENT_DIR`.
   - "existing sandbox attach" (~209) is unchanged — no paths are passed on
     a plain re-attach.

4. New assertions for the behavior this plan is actually about — reuse
   `WORK_A` since all four kits already create sandboxes there in sequence.
   Placement matters for the absence checks, so it's spelled out:

   - **Before the first creating call** (i.e. right after the `name` and
     `version` tests, before ~line 202): assert `${STATE_ROOT}` does not
     exist at all. This proves `name`/`version` never touch the filesystem,
     and can only be asserted here — nothing removes the tree afterwards.
   - Immediately after "new sandbox attach" (~204): assert
     `"${PROJECT_DIR}/sbxclaude"` exists (covers the `""`-branch call).
   - Before the explicit `create` test (~239): `rm -rf "${STATE_ROOT}"`,
     run `create`, assert `"${PROJECT_DIR}/sbxclaude"` exists again. This
     covers the `create`-branch call **independently** — without the wipe,
     an accidentally omitted `compute_state_mounts` in one branch could hide
     behind the other having already created the directory.
   - Assert that directory's mode is `700`, using the portable probe
     `"$(stat -f%Lp "$d" 2>/dev/null || stat -c%a "$d")"` (BSD form first,
     GNU fallback — same capability-probe style as shasum/sha256sum).
   - After "codex create" (~321): assert both `"${PROJECT_DIR}/sbxclaude"`
     and `"${PROJECT_DIR}/sbxcodex"` exist under the **same** `PROJECT_DIR`.
     This is the "shared per project, not per agent" invariant.
   - Project isolation: `PROJECT_DIR_B="${STATE_ROOT}/${NAME_B#*-}"` must
     differ from `PROJECT_DIR`; run `create` in `WORK_B` once, then assert
     `"${PROJECT_DIR_B}/sbxclaude"` exists and `PROJECT_DIR` still contains
     exactly the agent subfolders it had before (no cross-talk).

   These are filesystem-level checks against the fake `sbx`'s logging —
   they confirm the wrapper computes and creates the right paths and passes
   the right arguments, not that `sbx` actually enforces the nested
   read-only/read-write split at runtime. That enforcement is real-host-only
   (see Verification).

### `docs/toolchain.md`

Extend the existing "Your project is mounted as the workspace..." sentence:
each sandbox also gets a wrapper-managed state folder under
`${XDG_STATE_HOME:-~/.local/state}/sbxagent/<slug>-<hash>/`, shared read-only
across every agent's sandbox for that same project directory, with a
per-agent subfolder (`.../sbxclaude`, `.../sbxcodex`, etc.) writable only by
that agent's own sandbox. A different project's folder is never mounted, and
`rm` does not remove any of this. (`README.md`'s architecture diagram is not
being redrawn as part of this change — call this out to the user as an
optional follow-up.)

### `CHANGELOG.md`

Add one line under `## [Unreleased]` → `### Added`:

```
- All four kits: mount a wrapper-managed, per-project state folder under
  `${XDG_STATE_HOME:-$HOME/.local/state}/sbxagent`, shared read-only across
  every agent's sandbox for the same project, with a per-agent subfolder
  writable only by that agent's own sandbox.
```

## Verification

1. `make test-unit` (and `make test-unit BASH=/bin/bash` per AGENTS.md's
   bash-3.2 floor).
2. `make lint`.
3. **Load-bearing manual check, only possible on the user's host** (this
   sandbox can't run sandbox-management commands). **Passing this check is
   a prerequisite for accepting the design** — it is the only place the
   sharing contract is actually exercised. The fake-`sbx` unit tests can
   only confirm argv and host-side directories.

   The check proves five things, using real probe files under the normal
   sandbox agent user, not just `-d` existence checks:

   1. An **older** sandbox (Claude) can **read the contents** of a folder
      that was created **after** it (Codex's) — the live-visibility property
      from design decision 4, and the proof that `chmod 700` on `AGENT_DIR`
      does not block cross-sandbox reads under the sandbox's uid mapping.
   2. That older sandbox can neither modify the sibling's file nor add one.
   3. The same holds in the other direction (Codex reads Claude's, cannot
      write).
   4. The project root itself is read-only.
   5. An unrelated project's folder is not mounted at all.

   The sandbox name is `SELF-SLUG-HASH` (or `SELF-HASH`), so `${C#*-}` —
   strip everything up to and including the **first** dash — yields the
   `PROJECT_KEY` the wrapper used. (`${C%-*}` would strip from the end and
   name the wrong folder.) Both `create` calls must succeed; if `sbx` rejects
   a nested path at create time, that is a `FAIL` outcome too.

   ```bash
   cd /path/to/some/project
   STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}/sbxagent"
   C="$(sbxclaude name)"
   PROJECT_DIR="${STATE_HOME}/${C#*-}"
   rm -rf "${PROJECT_DIR}"   # fresh start: Claude must be created before Codex's folder exists

   sbxclaude create
   sbxcodex create           # Codex's AGENT_DIR now appears under an already-mounted parent

   # Codex writes a probe in its own folder.
   sbxcodex exec sh -c '
     echo codex-probe >"$1/probe" 2>/dev/null &&
       echo "OK: codex writes own folder" ||
       echo "FAIL: codex cannot write own folder"
   ' -- "${PROJECT_DIR}/sbxcodex"

   # The older Claude sandbox reads it, and cannot change it or add to it.
   sbxclaude exec sh -c '
     sib="$1"
     [ "$(cat "${sib}/probe" 2>/dev/null)" = "codex-probe" ] &&
       echo "OK: claude reads codex probe (folder created after claude)" ||
       echo "FAIL: claude cannot read codex probe"
     echo x >>"${sib}/probe" 2>/dev/null &&
       echo "FAIL: claude modified codex probe" ||
       echo "OK: claude cannot modify codex probe"
     echo x >"${sib}/intruder" 2>/dev/null &&
       echo "FAIL: claude created a file in codex folder" ||
       echo "OK: claude cannot create in codex folder"
   ' -- "${PROJECT_DIR}/sbxcodex"

   # Reverse direction, plus the project root.
   sbxclaude exec sh -c '
     echo claude-probe >"$1/probe" 2>/dev/null &&
       echo "OK: claude writes own folder" ||
       echo "FAIL: claude cannot write own folder"
   ' -- "${PROJECT_DIR}/sbxclaude"
   sbxcodex exec sh -c '
     sib="$1"; root="$2"
     [ "$(cat "${sib}/probe" 2>/dev/null)" = "claude-probe" ] &&
       echo "OK: codex reads claude probe" ||
       echo "FAIL: codex cannot read claude probe"
     echo x >>"${sib}/probe" 2>/dev/null &&
       echo "FAIL: codex modified claude probe" ||
       echo "OK: codex cannot modify claude probe"
     echo x >"${root}/intruder" 2>/dev/null &&
       echo "FAIL: project root is writable" ||
       echo "OK: project root is read-only"
   ' -- "${PROJECT_DIR}/sbxclaude" "${PROJECT_DIR}"
   ```

   All eight lines must print `OK`. Then confirm project isolation: create
   a sandbox for a second, unrelated directory, and check **from the first
   project's sandbox** (still in `/path/to/some/project`) that the second
   project's folder is not mounted:

   ```bash
   (cd /tmp && mkdir -p other-project && cd other-project && sbxclaude create)
   OTHER="$(cd /tmp/other-project && sbxclaude name)"
   sbxclaude exec sh -c \
     '[ -e "$1" ] && echo "FAIL: unrelated project is visible" || echo "OK: not mounted"' \
     -- "${STATE_HOME}/${OTHER#*-}"
   ```

   **Any `FAIL` blocks this plan. Do not ship a reduced version.**
   Cross-sandbox read visibility within a project is the requirement, not
   a nice-to-have, so there is no own-folder-only fallback. Instead, report
   which line failed and revisit the mount arrangement with that
   requirement intact. The failing line points at the cause:

   - `create` errors, or "cannot write own folder" → `sbx` does not honour
     a read-write path nested inside a read-only one (rejects it, or the
     parent shadows the child). The mount arrangement needs rethinking.
   - "cannot read … probe" while the folder is visible → the `chmod 700`
     in design decision 5 is blocking reads under the sandbox's uid
     mapping. That is a one-line knob (relax the mode), not a mount
     problem — fix it and re-run the check before proceeding.
   - "modified … probe" / "created a file" / "project root is writable" →
     `:ro` is not being applied to the parent. Mount arrangement problem.

   Clean up afterwards with `sbxclaude rm` / `sbxcodex rm` in both
   directories if desired; the probe files under `STATE_HOME` are harmless
   and can be deleted by hand.
4. No kit spec changes, so `make validate` is not required by AGENTS.md for
   this plan as scoped.
