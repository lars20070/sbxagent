# Upgrade sbx v0.46.0 → v0.47.0

## Context

sbx v0.47.0 shipped on 2026-10-05. We pin v0.46.0 in four kits, the release
workflow, a test and the docs. Two workarounds may go:

- **#553**: `sbx kit sign` fails on GHCR with a 405. **Fixed in v0.47.0**,
  per the release notes and the maintainer, who says the fix is in rc1 and later.
- **#420**: the startup step is skipped after `sbx daemon restart`. The issue
  was closed before v0.47.0-rc2. **It is not in the release notes.**

The user's decisions:
- #553: trust `sign`'s exit code and keep `verify`.
- #420: remove the entrypoint call. This is now gated; see Phase 2.

Checked and left alone:
- **#629** (virtiofs): still open, reproduced on v0.47.0, targeted for v0.48.0.
  Keep the export.
- **#388**: a regression test, not a workaround.
- **#231** and **#25**: not part of v0.47.0.

## Response to `review-plan.md`

**Accepted:**
- Keep `same_fs()`, its early exit, and test case 3.
- Gate the #420 removal on failure propagation.
- Test that `kit validate`/`inspect`/`pack` work with no daemon.
- Run the live checks on sandboxes built from the new specs, for all four kits.
- Run the signing probe twice, once for a first push and once for reuse,
  before any tag.
- Stage the changes; don't leave them unstaged.
- Fix the `BIND_HINT` and the comments in the toolchain and lifecycle tests.

**Pushed back:** a new check-only entrypoint gate. Since `same_fs()` stays,
the existing entrypoint call already checks first and only mounts when needed.
A check-only gate would be new code that is weaker: it could not repair a
missing bind, it could only refuse. So if sbx does not block launch when the
startup step fails, we keep the existing call unchanged.

The work is split into two phases with two commits. Phase 1 does not depend
on the host gates.

---

## Phase 1: pin bump and #553

### 1.0 Gate: is `kit` still daemon-free?

v0.47.0's notes say: "Local kit inspection, validation, and pulling require
the daemon to be running." That would break:
- the claim in `docs/toolchain.md:16`
- `AGENTS.md:58`
- `ci.yml:100`
- the in-sandbox instructions in every `kits/*/spec.yaml` (around lines 80–81)
- `publish-kit.sh`'s preflight

Steps:
- This sandbox is Linux arm64. Download the matching v0.47.0 archive into the
  scratchpad, check the full SHA-256
  (`6a3c45df52ff32722bb33e4d2c66f9920e284b9a3adeba17afcfcea3ad346eff`), and
  put it first on `PATH`.
- Show that no daemon is running: `sbx daemon status`, and check that no
  sandboxd socket exists.
- Run `sbx version`, `sbx kit validate kits/sbxclaude`,
  `sbx kit inspect kits/sbxclaude`, `sbx kit validate mixins/open-network`, and
  `sbx kit pack` (read `sbx kit pack --help` for its arguments first). Note
  whether the `mixins` WARN still prints.
- **If any of these needs a daemon: stop.** Report back. Do not edit, because
  CI and the validation design would need a new decision.
- Linux amd64 and macOS cannot be tested from here. The branch's CI run and
  the release dry run (1.6) cover them.

### 1.1 Pin bump (the same edit in each kit)

- `kits/{sbxclaude,sbxcodex,sbxcursor,sbxpi}/spec.yaml`: URL and comment
  `v0.46.0` → `v0.47.0`; digests amd64 `a89cb438…eab4`, arm64 `6a3c45df…6eff`.
- `.github/workflows/release.yml`: set `SBX_VERSION: v0.47.0` and set
  `SBX_SHA256` to `a89cb4380075ebb20938103bc98ec63327fbeabe43a71f0575ddb285a051eab4`.
  The generic archive is byte-identical to the amd64 one. Update the comment.
- `tests/toolchain_test.sh:14`: set `EXPECTED_SBX_VERSION="v0.47.0"`.
- Update `docs/toolchain.md` (the pinned-versions table) and `README.md:108`.

### 1.2 Remove the #553 workaround

- `scripts/publish-kit.sh`: a failed `sbx kit sign` now calls `die` before
  `verify`. Remove the 405 NOTICE branch and its long comment. Fix the header
  comment that says sign's exit code "is not trusted". Keep `sbx kit verify`
  as it is, with its deferred failure, outputs and summary.
- `AGENTS.md`: remove the section "A red `sbx kit sign` does not mean the
  release is unsigned".

### 1.3 Update the "as of" notes

- `scripts/sbxagent:59`: "no fix as of sbx v0.47.0 (targeted for v0.48.0)".
- `docs/published-kits.md:116`: change to v0.47.0 if 1.0 still shows the WARN.

### 1.4 CHANGELOG, under `[Unreleased]` → `Changed`

"`sbx` v0.47.0 is now required, up from v0.46.0. Every sandbox ships the same
version for its offline `sbx kit` commands."

### 1.5 Check, stage, hand off

- With the new binary first on `PATH`, run:
  - `make lint`
  - `make validate`
  - `env -u SBXAGENT_LITE -u NETWORK_ALLOWLIST make test-unit`
- `git add` only the files changed above. Do not stage
  `.claude/settings.local.json`, `review-plan.md` or the plan file. Draft
  commit message 1. Do not commit or push (AGENTS.md).

### 1.6 Gates the user runs (Phase 1 is not done until they pass)

1. Commit and push the branch. CI runs `make validate` on Linux and macOS
   with the latest sbx (v0.47.0), so this answers the daemon question for CI.
2. Release dry run with the pinned v0.47.0. It runs `validate` and `inspect`
   on the release runner:
   `gh workflow run release.yml --ref <branch>`
3. After the commit, I run `make publish-dry-run` in the sandbox with the new
   binary. It stages `git archive HEAD`, so it can only run after the commit.
4. Signing probe on the branch, run **twice** with the same fresh package name
   so that run 1 is a first push and run 2 is a reuse. Each run must show
   `sign` exiting 0 and `verify` passing:
   `gh workflow run release.yml --ref <branch> -f dry_run=false -f probe_repo=sbxprobe-047 -f probe_kit=sbxpi`
   (Delete the `sbxprobe-047` GHCR package afterwards.) Only after both runs
   pass: post the promised comment on #553, and allow a version tag.

---

## Phase 2: #420 (only after Phase 1 is committed)

### 2.0 Host gates (the user runs these; the host `sbx` must be v0.47.0)

`sbx daemon restart` stops **every** sandbox, including this session.

**A. Does the startup step replay after a daemon restart?** Run this on the
existing sandbox. It probes upstream only.

```bash
cd ~/Code/sbxagent
sbx daemon restart
./scripts/sbxclaude exec sh -c 'echo ok > "$HOME/.claude/projects/probe-420"'
n="$(./scripts/sbxclaude name)"
ls "${XDG_STATE_HOME:-$HOME/.local/state}/sbxagent/traces/${n#sbxclaude-}/sbxclaude/projects/probe-420" && rm "$_"
```

**B. Does a failing startup step stop the agent from launching?** Use a
throwaway kit. I write it and check it with `sbx kit validate` before handing
it over. Its startup step runs `exit 1`, and its entrypoint prints
`AGENT-LAUNCHED`.
- `sbx run --rm <probe-kit> <tmp-dir>`: does `AGENT-LAUNCHED` print?
- `sbx create` it, then `sbx exec <name> true`: does exec go ahead?

The exec result is for the record only. Exec never runs the entrypoint, so the
kit has no way to control it in either design.

### 2.1 Choose the path

| A | B: launch blocked? | What to do |
| --- | --- | --- |
| pass | yes | **Remove** the entrypoint call (2.2) |
| pass | no | **Keep** the call. Reword: "#420 fixed in v0.47.0; the call stays as the only gate that refuses to launch the agent" |
| fail | any | **Keep** the call. Reword: "#420 still not replayed as of v0.47.0" |

When we keep the call, update only these, then stage and draft commit message 2:
- the comments in the 4 specs
- `docs/traces.md` ("Two call sites", and drop the "Once #420 is fixed"
  paragraph and its flowchart)
- `tests/mount_state_test.sh` case 12
- the `tests/toolchain_test.sh` comment

### 2.2 Removal path

- **Entrypoints**:
  - `sbxclaude`, `sbxcodex`, `sbxcursor`: delete the `mount_state_status`
    block. Keep the token exports and the `exec`.
  - `sbxpi`: change to `entrypoint: [pi]`. Move its session-dir note to the
    startup step and fix the `sandbox:` header comment.
- **`mount-state.sh`**: keep `same_fs()` and the early exit. Update only the
  header: it is called from the startup step, and when it fails, sbx does not
  launch the agent (proven by gate B). Make the same edit in all 4 copies.
- **Startup-step comments** (4 specs): this is the only call site, and it
  replays after a daemon restart since v0.47.0.
- **`tests/mount_state_test.sh`**:
  - Keep cases 1–7, including case 3 (idempotency) and cases 6–7 (helper
    failures).
  - Replace cases 8–11 with a static check: no entrypoint block mentions
    `mount-state.sh`.
  - Case 12: exactly one call, in the startup block, as `agent`.
- **`tests/toolchain_test.sh`**: fix the comments at lines 187 and 192, and
  `BIND_HINT` at line 203, so they name only the startup step.
- **`tests/lifecycle_test.sh`**:
  - Reword the header (line 15), the `run_entrypoint` description, and the
    text of steps 1, 3 and 4. The bind now comes from the startup step, and
    `run_entrypoint` only attaches.
  - Keep step 3's "depth does not grow" assertion.
- **`docs/traces.md`**:
  - Keep steps 1–5 and the first flowchart.
  - On failure, "the startup step fails and sbx does not start the agent".
  - Rename "Two call sites" to "One call site".
  - Delete the "Once #420 is fixed" paragraph and the shorter flowchart.
- **CHANGELOG `Changed`**: "Trace folders are now bound only by each kit's
  startup step. sbx v0.47.0 replays it after a daemon restart."
- Run `make lint`, `make validate` and the unit tests. Stage, and draft commit
  message 2.

### 2.3 Live checks for the removal path (the user runs these)

These run on sandboxes built **from the new specs**.
1. Rebuild all four sandboxes, then run
   `make test-lifecycle AGENT=claude|codex|cursor|pi`. This covers:
   - create without attaching
   - stop and start
   - `exec` without attaching
   - writes reaching the host
   - repeated attaches not adding mount depth
2. On a sandbox built from the new spec: `sbx daemon restart`, then run gate A
   again. It does `exec` without attaching and checks that the write reaches
   the host.
3. `make test-toolchain AGENT=claude` (and each other agent you use).

If a check fails: put the entrypoint `mount_state_status` block back, and the
entrypoint tests (8–11) with it. The guard and case 3 never left, so nothing
else needs restoring.
