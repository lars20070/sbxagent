# Fix: sandbox restart crash caused by symlinked trace paths

## Context

`sbxclaude` (and, by the same shared code, `sbxcodex`/`sbxcursor`/`sbxpi`) fails
to restart after its first successful boot, with a generic
`failed to start runtime: 500 Internal Server Error`. The daemon log (per
`tmp/sbx-runtime-start-failure.md`) shows the real cause one layer down:

```text
OCI runtime create failed: creating `/home/agent/.claude/projects`:
openat2 `home/agent/.claude/projects`: No such file or directory
```

**Independently verified** (not taken on the report's word — two research
passes read the actual code):

- `kits/sbxclaude/files/home/.local/lib/sbxagent/link-state.sh` is real and
  byte-identical across all four kits (enforced by `Makefile` lines 52-63, not
  by `AGENTS.md` as the report guessed). When `SBXAGENT_STATE_DIR` is set, it
  copies existing traces into the wrapper state dir, unmounts the parent kit's
  `~/.claude/projects` volume, then replaces the stock path with a **symlink**
  (`ln -s "$target" "$link"`). This is permanent — nothing ever reverts it.
- Each kit's entrypoint is inline shell embedded directly in `spec.yaml` (no
  separate entrypoint file), confirmed in all four `kits/*/spec.yaml`.
- No `volumes:` key exists in any of this repo's `spec.yaml` files — the
  `~/.claude/projects` persistent volume is provisioned by an external parent
  kit (`extends: claude`), outside this repo.
- The precise claim that OCI recreates the mount destination *before* the
  entrypoint runs is an external runtime detail this repo cannot itself prove
  — but the setup that would make a symlinked destination fatal on restart is
  definitely real and permanent once `link-state.sh` has run once.

**Fix:** stop turning the stock trace path into a symlink. Bind-mount the
wrapper state folder over it instead, on every boot. The stock path then stays
a real directory forever, which is what the runtime needs to keep re-mounting
the parent kit's volume there on every restart.

## Design

Replace `link-state.sh` with `mount-state.sh` in all four kits (rename, keep
byte-identical). New behavior, given `LINK` (stock path) and `SUBDIR`:

1. No-op if `SBXAGENT_STATE_DIR` unset (unchanged).
2. If `LINK` is already a symlink (a sandbox from before this fix), refuse:
   exit 2. This is the one state the new script cannot safely reconcile.
3. `mkdir -p "$SBXAGENT_STATE_DIR/$SUBDIR"` (the target).
4. One-time migration, gated on a marker file
   `$SBXAGENT_STATE_DIR/.sbxagent-migrated-$SUBDIR` (sibling of the trace
   folder itself, so agents' own session-file scanning never sees it): copy
   any pre-existing content at `LINK` into the target (same collision policy
   as today — newest copy wins, skip `lost+found`), then touch the marker.
   Must be gated because a fresh mount namespace exists on every boot, so
   `LINK` reverts to its pre-bind snapshot each time — without the marker,
   every later boot would splice stale content back in over live writes.
5. Skip the actual bind if already bound this boot (detect via matching
   device+inode of `LINK` vs the target — `mountpoint -q` can't tell "bound
   this boot" from "never touched" once the namespace has reset).
6. `sudo -n mount --bind "$target" "$link"`. Passwordless `sudo` is already
   granted at the base image (confirmed: no sudoers file in this repo, and
   the sandbox's own baked-in instructions state `sudo` is passwordless) — no
   new permission needed, same as today's `sudo -n umount`.
7. Exit codes: 0 = bound this boot; 1 = not bound but `LINK` is untouched and
   usable (copy/mount failure — retried next boot); 2 = `LINK` is a legacy
   symlink, refuse to start.

This drops the `.sbxagent-aside`/rollback/`mv`/`ln`/`mountpoint` machinery
entirely — nothing is ever renamed or removed from `LINK`, so there is nothing
left to roll back. The parent kit's volume is never unmounted; `cp` treats a
mounted or plain directory identically, so no special-casing is needed.

`stat` needs a GNU-then-BSD fallback probe (`stat -c '%d:%i' || stat -f
'%d:%i'`) — same capability-probe pattern `scripts/sbxagent` already uses for
`shasum`/`sha256sum` — because `tests/mount_state_test.sh` execs this script
directly on the host, and CI runs `make test-unit` on macOS too.

## Files to change

- **`kits/{sbxclaude,sbxcodex,sbxcursor,sbxpi}/files/home/.local/lib/sbxagent/link-state.sh`**
  → rename to `mount-state.sh` in each kit, all four byte-identical, with the
  new logic above (comment thoroughly on *why*: the symlink-vs-restart
  failure, the marker-file rationale, the stat fallback).
- **`kits/{sbxclaude,sbxcodex,sbxcursor,sbxpi}/spec.yaml`** — in each
  entrypoint block: call `mount-state.sh` instead of `link-state.sh`; rename
  `link_state_status` → `mount_state_status`; reword the exit-1 message to
  "could not bind-mount ... onto the state folder; ... stay at the stock path
  this boot"; reword the exit-2 message to "... is not a real directory;
  refusing to start ... until the sandbox is rebuilt" (no longer references a
  path "trapped" in the state dir — there isn't one anymore). `sbxpi/spec.yaml`
  also has a comment at its `link-state.sh` call mentioning "symlink" by name
  — update it to describe the bind-mount instead.
- **`Makefile`** — line 52's shared-file list: `link-state.sh` →
  `mount-state.sh`. Line 147's `test-unit` target: point at the renamed test
  file.
- **`tests/link_state_test.sh`** → rename to `tests/mount_state_test.sh`.
  Point `HELPER` at `mount-state.sh`. Drop cases that only existed for the old
  `mv`/`ln`/`umount`/aside machinery (the ones simulating unmount, `mv`
  failures, aside-blocks-migration, and post-unmount restore — none of those
  code paths exist anymore). Keep and reword the cases that still apply
  (no-op without env, first bind, repeat-run idempotency, directory migration,
  collision policy, `lost+found` skip, copy failure leaves `LINK` untouched,
  the four kits' entrypoint safe/unsafe extraction). Add: a case proving the
  one-time marker actually prevents re-migration on a second boot (write
  through the target between "boots", assert it survives); a case proving the
  same-fs check skips a redundant bind attempt (point a failing `sudo` stub at
  it, assert no failure because the bind is already in place); a case for the
  new exit-2 legacy-symlink refusal.
- **`tests/toolchain_test.sh`** lines 146-162 — currently assert `TRACE_LINK`
  is a symlink pointing at the state folder; replace with: `TRACE_LINK` is a
  real directory (`-d` and not `-L`), and its device+inode match
  `SBXAGENT_STATE_DIR/TRACE_SUBDIR`'s (bind-mounted), still writable.
- **New: a live lifecycle regression test** (e.g. `tests/lifecycle_test.sh`,
  plus a `test-lifecycle` Makefile target, in the same "needs a live `sbx`
  daemon" bucket as `test-toolchain`, not part of `make test`/`test-unit`).
  Per kit: create a sandbox, write a trace marker file through the stock path,
  stop it, reattach (`sbx exec` auto-restarts a stopped sandbox), verify the
  marker survived and a second write succeeds, reattach again and verify
  exactly one bind mount exists at the stock path (no stacking). Run once with
  `CROSS_SANDBOX_VISIBILITY=true` and once with `=false`. Clean up the
  disposable sandbox on exit.
- **`docs/traces.md`** — add a short note that each stock path stays a real
  directory at all times and the wrapper bind-mounts the matching state
  subfolder over it at every start (rather than replacing it with a symlink),
  and why: the parent kit's own persistent volume at that path has to stay a
  valid, re-mountable destination across restarts.
- **`CHANGELOG.md`** `[Unreleased]` — reword the existing `### Fixed` bullet
  (currently about rollback-failure refusal) to describe the new legacy-symlink
  refusal instead; add a new `### Fixed` bullet describing the actual restart
  crash this closes, in plain language (no raw runtime error strings, so no
  `.cspell.json` dictionary update is needed).

## Verification

1. `make lint` — shellcheck/`bash -n` over the new script, the byte-identical
   check across all four kits, changelog/version consistency.
2. `make test-unit` — must pass with the default bash and with
   `BASH=/bin/bash` (the macOS CI leg), proving the `stat` fallback works.
3. `make validate` — schema-checks all four edited `spec.yaml` files.
4. Rebuild all four sandboxes (`./scripts/sbx<kit> rm` then `./scripts/sbx<kit>`)
   and run `make test-toolchain AGENT=<kit>` for each — proves the new
   bind-mount assertion in `toolchain_test.sh` passes live.
5. Run the new `make test-lifecycle AGENT=<kit>` for each kit — proves a
   trace marker survives a real stop/start/reattach cycle with no stacked
   mounts, under both `CROSS_SANDBOX_VISIBILITY` settings. This is the actual
   reproduction-and-fix proof for the reported crash: before the fix this
   would reproduce the 500 on the second boot; after, it passes.
