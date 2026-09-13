# Fix: sandbox restart crash caused by symlinked trace paths

## Context

`sbxclaude` fails to restart after its first successful boot, with a generic
`failed to start runtime: 500 Internal Server Error`. The daemon log (per
`tmp/sbx-runtime-start-failure.md`) shows the real cause one layer down:

```text
OCI runtime create failed: creating `/home/agent/.claude/projects`:
openat2 `home/agent/.claude/projects`: No such file or directory
```

**Independently verified** (not taken on the report's word — two research
passes read the actual code, plus a critical re-review that caught real bugs
in an earlier draft of this plan):

- `kits/sbxclaude/files/home/.local/lib/sbxagent/link-state.sh` is real and
  byte-identical across all four kits (enforced by `Makefile` lines 52-63, not
  by `AGENTS.md` as the original report guessed). When `SBXAGENT_STATE_DIR` is
  set, it copies existing traces into the wrapper state dir, unmounts the
  parent kit's `~/.claude/projects` volume, then replaces the stock path with
  a **symlink** (`ln -s "$target" "$link"`). This is permanent — nothing ever
  reverts it.
- Each kit's entrypoint is inline shell embedded directly in `spec.yaml` (no
  separate entrypoint file), confirmed in all four `kits/*/spec.yaml`.
- No `volumes:` key exists in any of this repo's `spec.yaml` files — the
  `~/.claude/projects` persistent volume is provisioned by an external parent
  kit (`extends: claude`), outside this repo. **Only this confirmed
  parent-provisioned volume, for sbxclaude, is proven to make a symlinked
  destination fatal on restart.** The other three kits share the same
  `link-state.sh` code and the same design flaw in principle, but nothing in
  this investigation proves their stock paths are forced OCI mount
  destinations the same way. Applying the fix to all four is a consistent
  design correction, not a claim that all four kits are separately confirmed
  broken.
- The precise claim that OCI recreates the mount destination *before* the
  entrypoint runs is an external runtime detail this repo cannot itself prove
  — but the setup that would make a symlinked destination fatal on restart is
  definitely real and permanent once `link-state.sh` has run once.

**Fix:** stop turning the stock trace path into a symlink. Bind-mount the
wrapper state folder over it instead, on every boot. The stock path then stays
a real directory forever, which is what the runtime needs to keep re-mounting
the parent kit's volume there on every restart.

### The bind-mount mechanic is confirmed, not assumed

Verified empirically on 2026-09-13 from inside a Docker Sandbox microVM:

- `sudo -n mount --bind SRC DST` succeeds for the unprivileged `agent` user —
  passwordless sudo carries the mount capability. Independently corroborated by
  upstream `docker/sbx-releases` issue #556, which closed on the premise that a
  sandboxed process can freely `sudo mount -o remount,rw`.
- Binding a **host-backed (virtiofs) source** — the shape `SBXAGENT_STATE_DIR`
  actually has — works in both directions: reads through the mount see host
  content, writes through it land on the host.
- After binding, `stat '%d:%i'` matched on both paths, so the `same_fs()`
  idempotency probe in the script below is a valid bound/not-bound signal.

No open upstream issue matches this repo's exact crash signature
(`openat2 home/agent/.claude/projects: No such file or directory`). The nearest
hits are unrelated: #350 is a Windows daemon wedge, #545/#366 are general
filesystem flakiness.

### Known upstream risk: a bind over a host-backed source can silently detach

`docker/sbx-releases` issue #388 (open, unfixed as of 2026-09-13) reports that a
mount inside a sandbox whose source is a host directory can be **silently
unmounted** when the host modifies that file tree. Applied here: the user's Mac
touching `SBXAGENT_STATE_DIR` could drop the bind mid-session, after which the
agent keeps writing happily — into the now-unbound stock path inside the
sandbox, where those traces die with the sandbox. No error, no log line.

This is a genuine regression in *failure mode* relative to the symlink design: a
symlink cannot fall off. The trade is still clearly worth it (the symlink's
failure is a hard, unrecoverable boot crash on every restart; this one is a rare
silent detach), but it must not be accepted unexamined:

- The design deliberately does **not** add a watchdog or a periodic re-bind.
  That is real daemon complexity inside every kit, for a failure this
  investigation has not yet observed in practice.
- Instead the live tests below must actively try to *provoke* the detach, so we
  learn whether #388 bites this specific usage before users do. If it does
  reproduce, the watchdog question reopens as its own piece of work — and
  `docs/traces.md` gains a warning that host-side edits to the state folder
  during a live session can cost traces.

## Design

Replace `link-state.sh` with `mount-state.sh` in all four kits (rename, keep
byte-identical). Given `LINK` (stock path) and `SUBDIR`:

```sh
set -eu
[ -n "${SBXAGENT_STATE_DIR:-}" ] || exit 0
link="$1"
target="${SBXAGENT_STATE_DIR}/$2"

# GNU-then-BSD probe, same pattern as scripts/sbxagent's shasum/sha256sum
# fallback — this runs on Linux in production, but tests/mount_state_test.sh
# execs it directly on whatever host runs `make test-unit`, macOS included.
same_fs() {
	one="$(stat -c '%d:%i' "$1" 2>/dev/null || stat -f '%d:%i' "$1" 2>/dev/null)"
	two="$(stat -c '%d:%i' "$2" 2>/dev/null || stat -f '%d:%i' "$2" 2>/dev/null)"
	[ -n "${one}" ] && [ "${one}" = "${two}" ]
}

if [ -L "${link}" ]; then
	echo "mount-state: ${link} is a symlink; this design requires it to stay a real directory — rebuild the sandbox" >&2
	exit 2
fi

mkdir -p "${target}" || { echo "mount-state: could not create ${target}" >&2; exit 1; }
mkdir -p "${link}" || { echo "mount-state: could not create ${link}" >&2; exit 1; }

if same_fs "${link}" "${target}"; then
	exit 0
fi

# Host state is authoritative. Only fill in names it doesn't already have —
# never overwrite an existing host entry with whatever is presently sitting
# at LINK (a freshly re-provisioned parent volume, or a freshly rebuilt
# sandbox's newly seeded files). This one loop, run on every un-bound boot,
# covers first-ever migration AND a later rebuild's new seed files with no
# separate one-time marker: once bound, LINK's own view already equals
# target, so this loop is unreachable and can never re-copy stale content
# over live writes.
for entry in "${link}"/.[!.]* "${link}"/..?* "${link}"/*; do
	[ -e "${entry}" ] || continue
	name="$(basename "${entry}")"
	# A fresh ext4 filesystem's reserved lost+found is root-owned and
	# unreadable by the unprivileged agent user; skip it by name.
	[ "${name}" = "lost+found" ] && continue
	[ -e "${target}/${name}" ] && continue
	if ! cp -R "${entry}" "${target}/"; then
		echo "mount-state: could not copy ${link}/${name} into ${target}" >&2
		exit 1
	fi
done

if ! sudo -n mount --bind "${target}" "${link}"; then
	echo "mount-state: could not bind-mount ${target} onto ${link}" >&2
	exit 1
fi
```

Key design decisions, and the bugs in an earlier draft of this plan that drove
them (a critical review caught these before implementation):

1. **Create `LINK` itself, not just the target, before binding.** A fresh
   sandbox may have neither its native trace directory nor its parents (Pi's
   spec never provisions `~/.pi/agent/sessions` before invoking the helper).
   `mount --bind` requires an existing destination — it does not create one.
   `mkdir -p "${link}"` fixes this; it's a no-op if `LINK` already exists
   (including as an already-mounted parent volume), so it never touches
   ownership or content of something that's already there.
2. **No soft "fallback to stock path" mode, and no migration marker.** An
   earlier draft wrote a marker after copying and let the agent keep running
   at `LINK` if the bind then failed. That allows a real data-loss race: copy
   succeeds, bind fails, the agent writes new traces at the (now unbound)
   stock path, a *later* boot's bind then succeeds and permanently hides those
   writes behind the marker (which suppresses re-copying). The fix is
   structural, not a smarter marker: when `SBXAGENT_STATE_DIR` is configured,
   *any* failure to fully relocate is fatal (exit 1 or 2) — the agent never
   starts at an unbound path, so it can never write traces somewhere this
   script won't find them. `SBXAGENT_STATE_DIR` unset remains the one
   legitimate no-op (exit 0) — that is the explicit stock-storage mode for a
   sandbox created without the wrapper.
3. **No marker at all, host-authoritative merge instead.** A marker stored
   under `SBXAGENT_STATE_DIR` survives `sbx rm`+rebuild for the same project
   (it's host-persisted), so a *rebuilt* sandbox with fresh parent-kit-seeded
   files (Cursor seeds trust/MCP-approval files into its native `projects`
   tree at setup time) would find the marker already set and skip copying
   those new files in forever, silently. Replacing the marker with
   `same_fs` (bound vs. not) as the sole idempotency signal, plus a
   copy-only-if-missing merge that runs on every un-bound boot, fixes this:
   a rebuild's new seed files get merged in (they don't yet exist in host
   state), while anything host state already has is never clobbered. This
   also corrects an inaccurate claim in the original script's own comments —
   "the sandbox's own copy wins" is really "whatever was copied last in loop
   order wins," not anything based on modification time; the new merge rule
   (host wins, gaps get filled) is both simpler and actually well-defined.
4. **A literal symlink at `LINK` is refused outright, not self-healed.**
   An earlier draft added a self-heal path (remove the symlink, recreate a
   plain directory, proceed normally) for kits where `LINK` isn't a forced
   OCI mount destination. That machinery is not worth its own complexity and
   tests: it cannot help the one confirmed, severe case (sbxclaude), since
   the container never reaches the entrypoint there at all — the symlink
   makes OCI's own mount-destination creation fail before any script runs.
   For every case the self-heal *could* reach, a clear refusal with a rebuild
   instruction is simpler and just as effective. **An already-wedged sandbox
   from before this fix has exactly one recovery path: remove and recreate
   it.** This fix's job is to stop that state from recurring after a sandbox
   is (re)built with it — not to revive one already stuck.

This drops the `.sbxagent-aside`/rollback/`mv`/`ln`/`mountpoint`/marker
machinery entirely. Nothing is ever renamed or removed from `LINK`, so there
is nothing to roll back, and the parent kit's volume is never unmounted —
`cp` treats a mounted-volume directory and a plain directory identically, so
no special-casing is needed either way.

## Files to change

- **`kits/{sbxclaude,sbxcodex,sbxcursor,sbxpi}/files/home/.local/lib/sbxagent/link-state.sh`**
  → rename to `mount-state.sh` in each kit, all four byte-identical, with the
  script above (comment on *why*: the symlink-vs-restart failure, the
  host-authoritative merge, the refuse-don't-fallback contract, the stat
  fallback).
- **`kits/{sbxclaude,sbxcodex,sbxcursor,sbxpi}/spec.yaml`** — in each
  entrypoint block, replace the link-state call-and-branch with a single
  refuse-on-any-failure form (no more soft exit-1-continue path to branch on):
  ```sh
  mount_state_status=0
  sh "$HOME/.local/lib/sbxagent/mount-state.sh" "$HOME/.claude/projects" projects ||
    mount_state_status=$?
  if [ "${mount_state_status}" -ne 0 ]; then
    echo "sbxclaude: could not relocate ~/.claude/projects onto the state folder; refusing to start claude" >&2
    exit "${mount_state_status}"
  fi
  exec claude "$@"
  ```
  (same shape for the other three kits, with their own paths/agent names).
  `sbxpi/spec.yaml` also has a comment mentioning "symlink" by name at its
  call site — update it to describe the bind-mount instead.
- **`Makefile`** — line 52's shared-file list: `link-state.sh` →
  `mount-state.sh`. Line 147's `test-unit` target: point at the renamed test
  file.
- **`tests/link_state_test.sh`** → rename to `tests/mount_state_test.sh`.
  Point `HELPER` at `mount-state.sh`. Drop cases that only existed for the old
  `mv`/`ln`/`umount`/aside/marker machinery. Keep and reword cases that still
  apply: no-op without env, first bind (including from a completely missing
  `LINK` and missing parents — this is the regression test for finding #1
  above), repeat-run idempotency via `same_fs`, `lost+found` skip, the four
  kits' entrypoint extraction (now checking the single refuse-on-any-failure
  branch). Add: a case proving a name already present in host state is never
  overwritten by a stale/rebuilt native copy (finding #4's regression test —
  simulate a "rebuild": bind once, unbind by resetting `LINK` to a *different*
  fresh directory with an old file of the same name plus one new file, run
  again, assert the old-content file in host state is untouched and the new
  file got merged in); a case proving a failed bind is fatal — the agent must
  not launch (finding #2's regression test: stub `sudo` to fail, assert
  `mount-state.sh` exits non-zero and the extracted entrypoint refuses to
  launch, not just logs a warning); a case for the exit-2 symlink refusal
  (no self-heal — any symlink is refused).
- **`tests/toolchain_test.sh`** lines 146-162 — currently assert `TRACE_LINK`
  is a symlink pointing at the state folder; replace with: `TRACE_LINK` is a
  real directory (`-d` and not `-L`), and its device+inode match
  `SBXAGENT_STATE_DIR/TRACE_SUBDIR`'s (bind-mounted), still writable. This
  test runs live inside an already-built sandbox via `sbx exec`, so
  unconditional GNU `stat -c` is fine here (unlike the unit test).
  **Also add a detach probe for upstream #388**: after the assertion above
  passes, have the *host* modify the state tree (create and delete a scratch
  file directly under `SBXAGENT_STATE_DIR/TRACE_SUBDIR`, from outside the
  sandbox), then re-run the same device+inode assertion through a fresh
  `sbx exec`. If the inodes no longer match, the bind silently detached and
  the test must fail loudly with a message naming issue #388 — this is the
  cheap early-warning signal for the one failure mode the bind-mount design
  introduces, and it costs a handful of lines in a test that is already
  standing up a live sandbox.
- **New: a live lifecycle regression test** (e.g. `tests/lifecycle_test.sh`,
  plus a `test-lifecycle` Makefile target, in the same "needs a live `sbx`
  daemon" bucket as `test-toolchain`, not part of `make test`/`test-unit`).
  Per kit:
  1. Create a sandbox and let its **configured entrypoint** actually launch
     the agent once (not just any `sbx exec` command) — the test must prove
     the real entrypoint ran, not merely that the container process exists.
  2. Through that session (or a follow-up `sbx exec`), write a marker file at
     the *native* stock path and confirm it also appears at the host state
     path — proving the bind is real, not just that some file exists.
  3. `sbx stop`; reattach in a way that re-triggers the configured entrypoint
     (verify this is actually what `sbx exec`/`sbx run` does after a stop for
     this `sbx` version — don't assume, confirm from `sbx --help` output
     and/or by observing the entrypoint's own log lines on the reattach).
  4. Confirm the marker survived and a second write still lands in host
     state; confirm from a **separate** exec session that the mount is
     visible there too (not just in the process that wrote it).
  5. Record the mount count at the stock path after step 1 as a baseline
     (Claude's case will legitimately show more than one mount — the parent
     kit's own volume plus this bind, stacked). Reattach several times and
     assert the count does not *grow* past that baseline — this is the
     no-stacking check, not an assertion that the count equals exactly one.
  6. Run the whole sequence twice: once with `CROSS_SANDBOX_VISIBILITY=true`
     (confirm a sibling sandbox for the same project can actually read the
     trace content, not just that the flag was accepted) and once with
     `=false` (confirm a sibling genuinely cannot read it).
  7. **Detach probe across a restart (upstream #388).** With the sandbox
     running and the bind confirmed, write to the state tree from the *host*,
     then confirm from a fresh `sbx exec` that (a) the stock path is still
     bound (device+inode match) and (b) a subsequent in-sandbox write still
     lands in host state. A failure here does not block the fix — it is
     strictly better than the crash being replaced — but it must be reported,
     not swallowed, because it changes what `docs/traces.md` has to warn
     users about.
  8. Clean up the disposable sandbox(es) on exit.

  **This test needs a live `sbx` daemon and a real Mac host with `sbx`
  installed — this development sandbox has no access to that.** It is a
  hand-off to the user to run, not something this session can execute itself
  (see Verification below).
- **`docs/traces.md`** — add a short note that each stock path stays a real
  directory at all times and the wrapper bind-mounts the matching state
  subfolder over it at every start (rather than replacing it with a symlink),
  and why: the parent kit's own persistent volume at that path has to stay a
  valid, re-mountable destination across restarts.
- **`CHANGELOG.md`** `[Unreleased]` — reword the existing `### Fixed` bullet
  (currently about rollback-failure refusal) to describe the new refusal:
  only when `LINK` is found to be a symlink at all (no self-heal), not the
  old rollback-failure case, which no longer exists; add a new `### Fixed`
  bullet describing the actual restart crash this closes, in plain language
  (no raw runtime error strings, so no `.cspell.json` dictionary update is
  needed).

## Verification

**Runnable from this development sandbox** (no live `sbx` daemon needed):

1. `make lint` — shellcheck/`bash -n` over the new script, the byte-identical
   check across all four kits, changelog/version consistency.
2. `make test-unit` — runs on Linux by default here. Note: this sandbox
   cannot itself exercise the BSD branch of the `stat` fallback (no BSD
   `stat` available) or bash 3.2 — that leg only gets genuine coverage from
   the project's macOS CI runner (`make test-unit BASH=/bin/bash` on
   `macos-latest`, per `.github/workflows/ci.yml`). Call this out rather than
   claim local verification proves macOS portability.
3. `make validate` — schema-checks all four edited `spec.yaml` files.

**Hand off to the user, on their Mac with a live `sbx` daemon** (this
development sandbox has no access to it):

4. Rebuild all four sandboxes (`./scripts/sbx<kit> rm` then `./scripts/sbx<kit>`)
   and run `make test-toolchain AGENT=<kit>` for each — proves the new
   bind-mount assertion in `toolchain_test.sh` passes live.
5. Run the new `make test-lifecycle AGENT=<kit>` for each kit, using
   disposable sandbox names/state directories so it doesn't disturb the
   user's real sandboxes — this is the actual reproduction-and-fix proof for
   the reported crash: before the fix this would reproduce the 500 on the
   second boot; after, it should pass, including the mount-count and
   cross-sandbox-visibility checks described above.
6. Report the outcome of the #388 detach probes (step 7 of the lifecycle test,
   and the host-side-write probe added to `toolchain_test.sh`) explicitly —
   pass or fail. If the bind does detach on host-side writes, that is new
   information about an open upstream bug: it decides whether `docs/traces.md`
   needs a user-facing warning, and whether a re-bind watchdog becomes its own
   follow-up task. Do not let a green overall run bury a red detach probe.
