# Mount a shared, read-write messageboard folder into every sandbox

## Context

`docs/traces.md` documents a wrapper-managed host folder that every sandbox
gets mounted into it, so each coding agent's session history survives sandbox
rebuilds and (optionally) is visible to sibling agents working the same
project. `README.md`'s architecture diagram already anticipates a second,
related piece — a shared **message board** at
`~/.local/state/sbxagent` alongside the session traces, with `/read-traces`,
`/read-message-board` and `/write-message-board` skills listed as the way
agents would use it — but nothing implements it yet.

This plan wires up the mount only: a host folder
`~/.local/state/sbxagent/messageboard/<slug>-<hash>` that gets mounted
**read-write** into every sandbox for a given project, regardless of which
agent (`sbxclaude`, `sbxcodex`, `sbxcursor`, `sbxpi`) it is. Unlike traces,
there is no per-agent subfolder — it's one shared folder every sandbox for
the project can both read and write. The skills that would actually use it
(`/read-message-board`, `/write-message-board`) are out of scope here.

**Decisions locked in with the user:**

- The mount is gated on the existing `CROSS_SANDBOX_VISIBILITY` flag (default
  `true`) — no new env var. When `false`, the folder is neither created nor
  mounted, same as `PROJECT_MOUNT` today.
- Inside the sandbox, the folder appears at the **same absolute path as on
  the host** — a plain mount operand added to the existing `sbx run`/`sbx
  create` invocations in `scripts/sbxagent`. No kit spec (`spec.yaml`) or
  `mount-state.sh` changes: unlike traces, there's no pre-existing
  agent-native folder to relocate/bind-mount over, so the direct-mount
  mechanism already used for the read-only `PROJECT_MOUNT` is sufficient.

## Implementation

### 1. `scripts/sbxagent` — `compute_state_mounts()`

Currently (lines 122–158):

```bash
compute_state_mounts() {
	case "${XDG_STATE_HOME:-}" in
	/*) STATE_HOME="${XDG_STATE_HOME}/sbxagent/traces" ;;
	*) STATE_HOME="${HOME}/.local/state/sbxagent/traces" ;;
	esac
	PROJECT_DIR="${STATE_HOME}/${SLUG:+${SLUG}-}${HASH}"
	AGENT_DIR="${PROJECT_DIR}/${SELF}"
	case "${CROSS_SANDBOX_VISIBILITY}" in
	true) PROJECT_MOUNT="${PROJECT_DIR}:ro" ;;
	false) PROJECT_MOUNT="" ;;
	*) die "CROSS_SANDBOX_VISIBILITY must be true or false, not '${CROSS_SANDBOX_VISIBILITY}'" ;;
	esac
	...
	mkdir -p "${PROJECT_DIR}"
	chmod 700 "${PROJECT_DIR}"
	mkdir -p "${AGENT_DIR}"
	chmod 700 "${AGENT_DIR}"
}
```

Add a parallel `MESSAGEBOARD_HOME`/`MESSAGEBOARD_DIR` block, following the
same `XDG_STATE_HOME` handling as `STATE_HOME` but under a `messageboard`
subfolder instead of `traces`, and fold its creation/mount-operand decision
into the existing `CROSS_SANDBOX_VISIBILITY` case statement.

Only **one** variable is needed here, not the `PROJECT_DIR`/`PROJECT_MOUNT`
pair traces uses — `MESSAGEBOARD_DIR` doubles as both the mkdir/chmod target
and the mount operand itself. That split exists for traces because (a)
`PROJECT_DIR` is needed even when nothing is mounted, since `AGENT_DIR` sits
inside it, and (b) `PROJECT_MOUNT` adds a `:ro` suffix `PROJECT_DIR` doesn't
have. Neither applies here: the messageboard mount is always read-write (no
suffix), and nothing else is nested inside it, so `MESSAGEBOARD_DIR` is
simply set to the empty string when unused:

```bash
	case "${XDG_STATE_HOME:-}" in
	/*) MESSAGEBOARD_HOME="${XDG_STATE_HOME}/sbxagent/messageboard" ;;
	*) MESSAGEBOARD_HOME="${HOME}/.local/state/sbxagent/messageboard" ;;
	esac
	case "${CROSS_SANDBOX_VISIBILITY}" in
	true)
		PROJECT_MOUNT="${PROJECT_DIR}:ro"
		MESSAGEBOARD_DIR="${MESSAGEBOARD_HOME}/${SLUG:+${SLUG}-}${HASH}"
		mkdir -p "${MESSAGEBOARD_DIR}"
		chmod 700 "${MESSAGEBOARD_DIR}"
		;;
	false)
		PROJECT_MOUNT=""
		MESSAGEBOARD_DIR=""
		;;
	*) die "CROSS_SANDBOX_VISIBILITY must be true or false, not '${CROSS_SANDBOX_VISIBILITY}'" ;;
	esac
```

Update the function's header comment (lines 122–132) to describe
`MESSAGEBOARD_DIR` alongside the existing variables — one project-wide
folder, read-write, computed/created/mounted only when
`CROSS_SANDBOX_VISIBILITY` is `true`, empty (so unmounted) when `false`.

### 2. `scripts/sbxagent` — the two `sbx` invocations

Insert `${MESSAGEBOARD_DIR:+"${MESSAGEBOARD_DIR}"}` right after
`${PROJECT_MOUNT:+"${PROJECT_MOUNT}"}` and before `"${AGENT_DIR}"`, in both
call sites:

- attach/`run`, line 238:
  ```bash
  exec sbx run --name "${SANDBOX}" -e "SBXAGENT_STATE_DIR=${AGENT_DIR}" --kit-arg "lite=${SBXAGENT_LITE}" ${NETWORK_KIT:+--kit "${NETWORK_KIT}"} "${KIT}" . ${PROJECT_MOUNT:+"${PROJECT_MOUNT}"} ${MESSAGEBOARD_DIR:+"${MESSAGEBOARD_DIR}"} "${AGENT_DIR}"
  ```
- `create`, line 274: identical change.

When `CROSS_SANDBOX_VISIBILITY=false`, both expand to nothing and the argv is
unchanged from today.

### 3. `tests/sbxagent_test.sh`

This file asserts full `sbx` argv strings via `assert_log`/`printf`, so every
call site that currently ends `...\t.\t%s:ro\t%s` (project dir + agent dir,
10 occurrences — lines 270, 312, 394, 439, 476, 508, 543, 557, 561, 616) needs
a `%s` inserted for the messageboard dir between them, and the matching
`printf` argument list needs `"${MESSAGEBOARD_DIR...}"` added in the right
position. Calls without `:ro` (the `CROSS_SANDBOX_VISIBILITY=false` cases,
e.g. lines 521, 527) stay as-is.

Also add, mirroring the existing `PROJECT_DIR`/`STATE_ROOT` setup (line 181–182,
258, 502):

- A `MESSAGEBOARD_ROOT="${XDG_STATE_HOME}/sbxagent/messageboard"` and
  `MESSAGEBOARD_DIR="${MESSAGEBOARD_ROOT}/${NAME_A#*-}"`-style helper near the
  existing `PROJECT_DIR` computation.
- New assertions parallel to the `CROSS_SANDBOX_VISIBILITY` block (lines
  514–536): `MESSAGEBOARD_DIR` exists with mode `700` when
  `CROSS_SANDBOX_VISIBILITY=true` (the default already covers this via the
  main flow), and does **not** exist when `CROSS_SANDBOX_VISIBILITY=false`
  (parallel to today's check that `PROJECT_DIR`'s read-only mount is dropped).
- Confirm two sibling agents for the same project (e.g. `sbxclaude` and
  `sbxcodex` — same pattern as the existing `PROJECT_DIR` "shared across
  agents" assertions around lines 253–403) resolve to the identical
  `MESSAGEBOARD_DIR`.

No changes needed to `tests/mount_state_test.sh`, `tests/lifecycle_test.sh`,
or `tests/toolchain_test.sh` — those exercise the kit-side `mount-state.sh`
relocation mechanism, which this feature doesn't use.

### 4. Docs and changelog

- **New `docs/messageboard.md`**, short, parallel in spirit to
  `docs/traces.md` but much simpler (no per-agent relocation, no formats
  table): what the folder is, its host path
  (`~/.local/state/sbxagent/messageboard/<slug>-<hash>`), that it's shared
  read-write across every agent's sandbox for the project, that it's gated by
  `CROSS_SANDBOX_VISIBILITY` (link to `docs/traces.md` for that flag's full
  semantics rather than repeating them), and a one-line note that nothing
  reads or writes to it yet — the skills referenced in `README.md`'s diagram
  are future work.
- **`README.md`**: add a row for `docs/messageboard.md` to the doc-index
  table (next to the existing `docs/traces.md` row, ~line 202).
- **`docs/toolchain.md`** (~lines 23–33): extend the paragraph describing the
  wrapper-managed state folder to mention the sibling `messageboard/`
  folder and that it's gated by the same `CROSS_SANDBOX_VISIBILITY` flag.
- **`docs/setup.md`** (~line 46): extend the `CROSS_SANDBOX_VISIBILITY` row's
  description to mention it also gates the messageboard mount.
- **`.env.example`** (~lines 20–23): extend the `CROSS_SANDBOX_VISIBILITY`
  comment the same way.
- **`CHANGELOG.md`**: add an entry under `## [Unreleased]` → `### Added`,
  following the style of the existing `NETWORK_ALLOWLIST` entry.

## Out of scope

- The `/read-message-board` / `/write-message-board` skills themselves, and
  any convention for what agents write into the folder (format, filenames,
  etc.).
- Any kit spec (`spec.yaml`) or `mount-state.sh` changes — not needed since
  this is a direct mount, not a relocation.
- `make validate` is not required for this change (no kit spec touched).

## Verification

- `make lint`
- `make test-unit` (exercises `tests/sbxagent_test.sh` against a fake `sbx`
  CLI — covers the new argv and directory-creation assertions)
- Manual, on the host (needs the real `sbx` CLI, so ask the user to run it):
  1. `NETWORK_ALLOWLIST=true CROSS_SANDBOX_VISIBILITY=true ./scripts/sbxclaude create` (or plain `./scripts/sbxclaude`), then confirm
     `ls ~/.local/state/sbxagent/messageboard/<slug>-<hash>` exists on the
     host, and from inside the sandbox (`sbxclaude exec -- touch ...`) confirm
     a file written there lands on the host and vice versa.
  2. Start a second agent's sandbox for the same project (e.g.
     `./scripts/sbxcodex`) and confirm it sees the same folder and the same
     file.
  3. Rebuild one with `CROSS_SANDBOX_VISIBILITY=false` and confirm the
     messageboard path is absent inside that sandbox.
