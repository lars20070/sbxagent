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

There is no way to hand this to the runtime instead and skip the in-sandbox
mount entirely. `sbx run`'s workspace operands take `PATH[:ro]` only, with no
destination syntax (confirmed from `sbx run --help` on the pinned CLI), so the
wrapper cannot ask for `${AGENT_DIR}/projects` to be mounted *at*
`~/.claude/projects`. If a future `sbx` grows destination mounts, that becomes
the simpler design and this helper can go away — so do not re-litigate it now,
just revisit it then.

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
- Binding **over a path that is already a mount point** — the confirmed
  sbxclaude shape, where the parent kit's volume occupies `LINK` — works. The
  bind stacks on top, `/proc/self/mountinfo` then shows exactly two entries for
  that path, and running the script a second time leaves it at two. So
  `same_fs` is a valid probe over a stack too, and the script does not grow the
  stack on repeat runs.
- Every process in the sandbox shares one mount namespace, PID 1 included, so a
  bind made by the entrypoint is visible to a later `sbx exec` session rather
  than trapped in the process that made it. This is what the live tests below
  depend on when they assert the mount through a separate `sbx exec`.

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

### Settled: the helper is called from *both* `setup: startup:` and the entrypoint

This fix changes relocation from **once ever** to **once per container start**,
so where the helper is called from is load-bearing, not a detail.

Under the symlink design one attach was enough for the sandbox's whole life:
the symlink is on disk, so every later session saw the relocated path, however
it got in. A bind mount lives and dies with the container's mount namespace, so
it has to be re-made after every `sbx stop`.

**The entrypoint alone is not enough — confirmed, not suspected.** The kit
`entrypoint` is the *agent launch command*, not a per-start hook: PID 1 in a
live sandbox is `tini`, and this repo's own comment at
`kits/sbxclaude/spec.yaml:27` already records the consequence — "This only
covers the agent session this entrypoint starts; a `claude` launched by hand
from `sbxclaude exec bash` does not inherit it." A bind made only there is
absent for every `sbx exec` session and for any sandbox started but not
attached, and the agent would then write traces to the unbound stock path with
no error at all. `make test-toolchain` would be the first thing to trip over
it, because it runs through `sbx exec` rather than through an attach.

**`setup: startup:` is the per-start hook.** Upstream `docker/sbx-releases`
issue #420 quotes the documented contract: startup commands "run on every
sandbox start and replay on container restarts". This repo already relies on
that hook for MCP registration (`kits/sbxclaude/spec.yaml:405`).

**But it has two known upstream gaps**, both open as of 2026-09-13:

- **#420** — startup commands do *not* replay after `sbx daemon restart`; the
  daemon reuses cached state and the command never runs.
- **#479** — `sbx exec` against a *stopped* sandbox starts it without
  provisioning, so startup steps can be skipped on that path too.

**Decision: call `mount-state.sh` from both places.** The script is already
idempotent — once bound, `same_fs` matches and it exits 0 without touching
anything — so the second call site costs one invocation and no new machinery.
Either path firing is enough to establish the bind, which closes both #420 and
#479 for this use without a watchdog. This is deliberately belt-and-braces:
the failure it guards against is silent trace loss, which is exactly the class
of bug that must not depend on a single upstream behaviour staying true.

Consequences to carry into the code:

- The `setup: startup:` step must fail loudly if the helper fails. It cannot
  `exec` the agent, so it cannot enforce the refuse-to-start contract the
  entrypoint does — the entrypoint remains the enforcement point, and the
  startup step is the one that makes the bind exist for non-attach sessions.
- The entrypoint keeps its full refuse-on-any-failure branch unchanged. It is
  the last line of defence before the agent actually starts writing traces.

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

  **Add a second call site in each kit's `setup: startup:` block** (per the
  decision above), before or alongside the existing startup steps:
  ```sh
  sh "$HOME/.local/lib/sbxagent/mount-state.sh" "$HOME/.claude/projects" projects
  ```
  running as the agent user (`user: "1000"`, matching the other steps that
  touch `$HOME`). Let a non-zero exit fail the startup step rather than
  swallowing it — a startup step cannot refuse to launch the agent the way the
  entrypoint can, but it must not report success when the bind is missing.
  Comment at both call sites that the duplication is deliberate and safe: the
  helper is idempotent via `same_fs`, the startup step covers `sbx exec` and
  started-but-not-attached sessions, the entrypoint covers the upstream gaps
  in #420/#479 where the startup step may not run at all, and neither one is
  sufficient alone.
- **`Makefile`** — line 52's shared-file list: `link-state.sh` →
  `mount-state.sh`. Line 147's `test-unit` target: point at the renamed test
  file.
- **`.github/workflows/ci.yml`** — set `SBXAGENT_REQUIRE_BIND=1` on the
  `ubuntu-latest` leg of the `test` job's matrix, so the two bind cases below
  are enforced somewhere instead of being skippable on every runner. Leave the
  two macOS invocations (including the bash 3.2 one) alone; they skip those
  cases by capability probe.
- **`tests/link_state_test.sh`** → rename to `tests/mount_state_test.sh`.
  Point `HELPER` at `mount-state.sh`. Drop cases that only existed for the old
  `mv`/`ln`/`umount`/aside/marker machinery. Keep and reword cases that still
  apply: no-op without env, first bind (including from a completely missing
  `LINK` and missing parents — this is the regression test for finding #1
  above), repeat-run idempotency via `same_fs`, `lost+found` skip, the four
  kits' entrypoint extraction (now checking the single refuse-on-any-failure
  branch). Add: a case asserting **both** call sites exist in all four
  `spec.yaml` files — the entrypoint one with its refuse-on-any-failure branch,
  and the `setup: startup:` one running as the agent user — so a future edit
  cannot quietly drop one and reintroduce the silent-no-bind hole; a case proving a name already present in host state is never
  overwritten by a stale/rebuilt native copy (finding #4's regression test —
  simulate a "rebuild": bind once, unbind by resetting `LINK` to a *different*
  fresh directory with an old file of the same name plus one new file, run
  again, assert the old-content file in host state is untouched and the new
  file got merged in); a case proving a failed bind is fatal — the agent must
  not launch (finding #2's regression test: stub `sudo` to fail, assert
  `mount-state.sh` exits non-zero and the extracted entrypoint refuses to
  launch, not just logs a warning); a case for the exit-2 symlink refusal
  (no self-heal — any symlink is refused).

  **Only two of those cases need a real bind mount, and they have to be gated.**
  This test runs the helper directly on whatever machine ran `make test-unit`,
  and `.github/workflows/ci.yml` runs it on `macos-latest` as well as
  `ubuntu-latest`. macOS has no `mount --bind` at all, so on a Mac the script
  cannot perform the one action it exists to perform. Details, all four measured
  rather than assumed:

  - **Gate on the capability, not the OS name.** `AGENTS.md` forbids a `uname`
    branch, and a probe is better here anyway: it also catches a plain Linux
    machine without password-free `sudo`, which an is-this-Linux check would
    wave through and then fail on. The probe is: `mkdir` two scratch
    directories, try `sudo -n mount --bind` one onto the other, unmount, and
    treat any failure as unavailable.
  - **Almost everything still runs everywhere.** With `sudo` stubbed to
    succeed, the script completes and performs the whole merge without creating
    any mount, so the no-env no-op, the exit-2 symlink refusal, the
    fatal-failed-bind case, the host-authoritative merge, the `lost+found`
    skip and the four entrypoint extractions are all unaffected. Only "a fresh
    bind really happened" and "a second run sees itself as already bound" need
    a genuine mount, because `same_fs` compares device and inode numbers, which
    only match after a real bind. Faking that would mean stubbing `stat` too,
    at which point the case tests the stub instead of the script — so gate,
    don't fake.
  - **Skip loudly.** Print a `skip - …` line, the way this test already does
    for its root-user cases, so a Linux run that quietly lost the ability to
    mount does not look identical to a fully green one.
  - **Let Linux CI demand the real thing.** Honour a
    `SBXAGENT_REQUIRE_BIND=1` environment variable that turns the skip into a
    failure, and set it on the Linux half of the CI matrix. Without that, a
    future permissions change could make *every* runner skip both cases and
    nothing would ever say so.

  **Also make the cleanup trap mount-aware.** The current trap goes straight to
  `rm -rf "${TEST_ROOT}"`; doing that over a live bind mount deletes content
  *through* the mount. Here the source also lives under `TEST_ROOT`, so the
  damage is contained, but a case that fails midway would otherwise leave a
  stray mount on the developer's machine. Unmount everything the test mounted
  before removing anything.
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
  3b. **Prove the startup call site independently of the entrypoint.** After a
     `sbx stop`, reach the sandbox with `sbx exec` *only* — never attaching,
     so the entrypoint never runs — and assert the stock path is already bound
     there. This is the regression test for the hole that drove the two-call-site
     decision; without it, a green suite would not distinguish "both call sites
     work" from "the entrypoint is silently carrying the whole design".
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
  valid, re-mountable destination across restarts. Say plainly that the bind is
  re-made on **every** sandbox start (it does not persist on disk the way the
  old symlink did), which is why it is established from two places.
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
2. `make test-unit` — runs on Linux here, where `sudo -n mount --bind` works,
   so this is the environment that covers the two real-bind cases; run it with
   `SBXAGENT_REQUIRE_BIND=1` to prove they were not skipped. Two legs it cannot
   cover, to state rather than gloss over: the BSD branch of the `stat`
   fallback and bash 3.2 only get genuine coverage from the macOS CI runner
   (`make test-unit BASH=/bin/bash` on `macos-latest`), and that same runner
   necessarily skips the two bind cases, because macOS has no bind mounts. A
   green local run therefore proves neither macOS portability nor macOS
   coverage of the mount itself.
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
