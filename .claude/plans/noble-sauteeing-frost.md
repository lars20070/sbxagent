# Add a `CROSS_SANDBOX_VISIBILITY` flag to the wrapper

## Context

The staged (uncommitted) change in `scripts/sbxagent` mounts a per-project
state folder into every sandbox: `PROJECT_DIR`
(`${STATE_HOME}/<slug>-<hash>`) read-only, and this agent's own
`AGENT_DIR` (`${PROJECT_DIR}/${SELF}`) read-write. That gives every agent's
sandbox for one project read access to its neighbours' state folders.

This adds a switch for that read access. `CROSS_SANDBOX_VISIBILITY=true`
(the default) keeps the current behaviour. `false` drops the read-only
`PROJECT_DIR` mount entirely, so a sandbox sees only its own `AGENT_DIR`.
The host-side folder tree is the same either way — only what gets mounted
changes.

## Design decisions

1. **Env-overridable, default `true`**, declared at the top of
   `scripts/sbxagent` next to the existing host-side knob
   (`DOCKER_SANDBOXES_ENABLE_VIRTIOFS_CACHE`):

   ```bash
   CROSS_SANDBOX_VISIBILITY="${CROSS_SANDBOX_VISIBILITY:-true}"
   ```

   Per-call opt-out is then `CROSS_SANDBOX_VISIBILITY=false sbxclaude create`.

2. **Strict values, checked late.** Only `true` and `false` are accepted.
   Anything else `die`s — but the check lives inside `compute_state_mounts`,
   which only the two sandbox-creating paths call, so a typo in the
   environment never breaks `name`, `help`, `version`, `rm`, etc. Silently
   treating `yes`/`1`/`TRUE` as "false" would be a trap; failing is safer.

3. **Same folder tree in both modes.** `mkdir -p "${AGENT_DIR}"` still
   creates `PROJECT_DIR` when the flag is `false`. Flipping the flag later
   and re-creating a sandbox therefore needs no migration.

4. **Mounts are fixed at creation.** The flag affects the next `create` (or
   first attach), never an existing sandbox — the same rule as every other
   mount. Say so in the docs.

5. **Optional argv without arrays.** `compute_state_mounts` sets
   `PROJECT_MOUNT` to `"${PROJECT_DIR}:ro"` or to the empty string. Call
   sites use `${PROJECT_MOUNT:+"${PROJECT_MOUNT}"}`, which expands to one
   quoted word when set and to nothing when empty. bash 3.2 safe, no array.
   Verified during planning: a minimal script using exactly this line passes
   `shellcheck --enable=all` (the repo's setting) with no findings, so no
   `# shellcheck disable` is needed or acceptable.

## Changes

### `scripts/sbxagent`

Top of file, after the `DOCKER_SANDBOXES_ENABLE_VIRTIOFS_CACHE` export:

```bash
# Whether a sandbox can read the state folders of its neighbours — the other
# agents' sandboxes for this same project. true mounts the shared project
# folder read-only alongside this agent's own read-write subfolder; false
# mounts only the subfolder. Takes effect at create time.
CROSS_SANDBOX_VISIBILITY="${CROSS_SANDBOX_VISIBILITY:-true}"
```

`compute_state_mounts` gains one `case` that validates the flag and sets
`PROJECT_MOUNT` in the same breath. It runs after the paths are computed
(so the error can't be reached with them unset) but **before** `mkdir`, so
a bad value creates nothing on disk:

```bash
compute_state_mounts() {
	case "${XDG_STATE_HOME:-}" in
	/*) STATE_HOME="${XDG_STATE_HOME}/sbxagent" ;;
	*) STATE_HOME="${HOME}/.local/state/sbxagent" ;;
	esac
	PROJECT_DIR="${STATE_HOME}/${SLUG:+${SLUG}-}${HASH}"
	AGENT_DIR="${PROJECT_DIR}/${SELF}"
	case "${CROSS_SANDBOX_VISIBILITY}" in
	true) PROJECT_MOUNT="${PROJECT_DIR}:ro" ;;
	false) PROJECT_MOUNT="" ;;
	*) die "CROSS_SANDBOX_VISIBILITY must be true or false, not '${CROSS_SANDBOX_VISIBILITY}'" ;;
	esac
	mkdir -p "${AGENT_DIR}"
	chmod 700 "${AGENT_DIR}"
}
```

No `[[ ]] &&` last-line trap, no `return 0`. Update the function's header
comment to say `PROJECT_MOUNT` is empty when the flag is `false`.

Both call sites (the `""` branch and `create`) become:

```bash
exec sbx run    --name "${SANDBOX}" "${KIT}" . ${PROJECT_MOUNT:+"${PROJECT_MOUNT}"} "${AGENT_DIR}"
exec sbx create --name "${SANDBOX}" "${KIT}" . ${PROJECT_MOUNT:+"${PROJECT_MOUNT}"} "${AGENT_DIR}"
```

### `tests/sbxagent_test.sh`

All existing assertions keep passing unchanged (default is `true`). Add,
after the "each directory gets its own project state folder" test, using
`WORK_B` again (its folder already exists, which is fine — the test is about
argv, not `mkdir`):

- `CROSS_SANDBOX_VISIBILITY=false run_claude "${WORK_B}" create` →
  `assert_log` expects `create\t--name\tNAME_B\tKIT\t.\tPROJECT_DIR_B/sbxclaude`
  — no `:ro` token anywhere. Also assert `"${PROJECT_DIR_B}/sbxclaude"`
  still exists (folder tree unchanged by the flag).
- The same with `false` on the attach path, because that is a separate
  `exec` line and a typo there would not be caught by the `create` test:
  `CROSS_SANDBOX_VISIBILITY=false SBX_SKIP_INSPECT_LOG=1 SBX_INSPECT_STATUS=1
  run_claude "${WORK_B}"` → expects
  `kit\tvalidate\tKIT\nrun\t--name\tNAME_B\tKIT\t.\tPROJECT_DIR_B/sbxclaude`.
- `CROSS_SANDBOX_VISIBILITY=bogus reject_without_call "${WORK_B}" create`
  — dies, prints an error, makes no `sbx` call. `reject_without_call`
  already exists and the `VAR=x func` env-prefix pattern is already used at
  the "new sandbox attach" test. Also assert `${STATE_ROOT}` still lists
  only the folders it had before — a bad value must create nothing.
- `CROSS_SANDBOX_VISIBILITY=bogus run_claude "${WORK_B}" name` must still
  succeed and print `NAME_B` — proves the check is on the creating paths
  only.

One `pass` line: "CROSS_SANDBOX_VISIBILITY=false drops the shared mount and
rejects other values".

### `docs/toolchain.md`

Extend the state-folder sentence already staged: "...that only that agent's
own sandbox can write. Set `CROSS_SANDBOX_VISIBILITY=false` when creating a
sandbox to mount only its own subfolder and hide its neighbours'. Other
projects' folders are never mounted, and `rm` leaves all of this in place."

### `CHANGELOG.md`

Extend the already-staged `Added` entry with one clause: "...writable only
by that agent's own sandbox. `CROSS_SANDBOX_VISIBILITY=false` at create
time mounts only the agent's own subfolder."

## Verification

1. `make test-unit` — 25 tests expected (24 today + 1).
2. `make lint` — shellcheck must stay clean without any `disable` comment;
   if it flags the `${PROJECT_MOUNT:+"${PROJECT_MOUNT}"}` line, that's a
   sign the idiom was mistyped, not a reason to suppress.
3. Host check (yours, on the Mac): the eight-`OK` script from the previous
   plan still applies for the default. Add one run with the flag off:

   ```bash
   cd /path/to/some/project
   sbxcodex rm
   CROSS_SANDBOX_VISIBILITY=false sbxcodex create
   STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}/sbxagent"
   X="$(sbxcodex name)"; PROJECT_DIR="${STATE_HOME}/${X#*-}"
   sbxcodex exec sh -c '
     [ -e "$1/sbxclaude" ] && echo "FAIL: neighbour visible with flag off" || echo "OK: neighbour hidden"
     echo x >"$2/probe" 2>/dev/null && echo "OK: own folder writable" || echo "FAIL: own folder not writable"
   ' -- "${PROJECT_DIR}" "${PROJECT_DIR}/sbxcodex"
   ```

   Both must print `OK`. Note the subtlety this checks: with the parent not
   mounted, `$1/sbxcodex` is reachable only because `sbx` creates the mount
   point path inside the sandbox — `$1/sbxclaude` must not exist there.
4. No kit spec changes, so `make validate` is not required.
