# Upgrade sbx v0.46.0 → v0.48.0

## Context

We pin sbx v0.46.0 in four kits, the release workflow, a test and the docs.
v0.47.0 was never adopted. v0.48.0 (2026-10-13) becomes the only supported
version. Older versions get no support.

Rules for this upgrade (user + `review-plan.md`):
- Every workaround for an upstream issue that is fixed in v0.48.0 goes
  **completely**: code, comments, tests and docs. No version branches, no
  fallbacks, no "restore if it fails".
- The CI `validate` job stays off (`if: false`, commit ea62539) and the
  `Makefile` stays unchanged, until v0.49.0.

Upstream issues referenced in the repo:

| Issue | Status | Action |
| --- | --- | --- |
| #553 `kit sign` 405 on GHCR | fixed in v0.47.0 | remove workaround (1.2) |
| #629 virtiofs `link()`/`fsync()` | fixed in v0.48.0 | remove workaround (1.4) |
| #420 startup step not replayed after daemon restart | fixed (startup metadata restored after restart) | remove workaround (Phase 2) |
| #25 secret env vars on existing sandbox | closed; fix confirmed for sandbox-scoped **GitHub** credentials only (v0.38.0) | remove workaround, then verify OpenRouter on its own (1.5) |
| #685 `kit validate` needs login | **not** in v0.48.0 (`--offline` in v0.49.0) | temporary `kit pack` preflight (1.3) |
| #231 Copilot token prefix | fixed in v0.42.0 by a separate `copilot` secret | keep: our local GitHub MCP server is a design choice (no Copilot PAT needed), not a #231 workaround. Reword `docs/agents.md:102` to say so |
| #388 nested `:ro` mount | closed | keep: `tests/lifecycle_test.sh` case 5 is a regression test, not a workaround |

Other v0.48.0 changes that matter:
- **CLI refactor**: flags, `--json` shapes, stdout/stderr, prompts need a TTY.
  Every flag the wrapper and tests use still exists (checked: `run --name -e
  --kit-arg --kit`, `create`, `exec -i/-it`, `inspect`, `rm`, `rm --force`,
  `stop`, `policy log`, `policy check network --sandbox`). Nothing parses
  `--json` or pipes `y`.
- `sbx version` prints `sbx version v0.48.0 <sha>` (no colon).
  `tests/toolchain_test.sh` uses `grep -Fqw`, so it still matches.
- `sbx kit pack` takes **one** positional argument; the ZIP goes in
  `--output`. Two positionals → `error: accepts 1 arg(s), received 2`.
- `kit validate` success output is now `✓ <path> — valid (directory)`.

Checked on 2026-10-18 with the real v0.48.0 arm64 binary (SHA-256 verified),
no daemon, no login: all 4 kits and `mixins/open-network` pack fine with
`--output`. A spec with `mixins: [./missing-mixin]` also packs silently, so
`pack` is not a stand-in for `validate`'s warnings.

Digests (GitHub API):
- amd64 and generic `DockerSandboxes-linux.tar.gz`:
  `609a2e4b881ba9a7fd21543077e53d3b863a6b99eebee1f208e51a097ab56a05`
- arm64: `83eb3a2cdebf28b1b8e3e8f5d8e964c60d8bb8323c52447ac947864fdca0fd15`

---

## Phase 1: pin bump, #553, #629, #25, #685

Use the verified v0.48.0 binary from the scratchpad, first on `PATH`.

### 1.1 Pin bump

- `kits/{sbxclaude,sbxcodex,sbxcursor,sbxpi}/spec.yaml`: download URL and
  "Digests of the v0.46.0 release assets" → v0.48.0; new amd64/arm64 digests.
- `.github/workflows/release.yml`: `SBX_VERSION: v0.48.0`,
  `SBX_SHA256: 609a2e4b…6a05`; fix the "v0.46.0 Linux archive" comment.
- `tests/toolchain_test.sh:14`: `EXPECTED_SBX_VERSION="v0.48.0"`.
- `docs/toolchain.md:76` table, `README.md:108` ("v0.48.0 is required").

### 1.2 #553: remove the GHCR 405 exception

- `scripts/publish-kit.sh`: `sbx kit sign` must succeed, else `die`. Delete
  the NOTICE branch, its comments, and header text saying sign's exit code
  "is not trusted". Keep `sbx kit verify` as an independent check.
- `AGENTS.md`: delete the section "A red `sbx kit sign` does not mean the
  release is unsigned".

### 1.3 #685: one temporary offline preflight

- `scripts/publish-kit.sh:132-133`: replace `sbx kit validate` and
  `sbx kit inspect` with:
  ```bash
  sbx kit pack "${staged}" --output "${stage}/${kit}.zip"
  ```
  One short comment: offline schema check until sbx ships `--offline`
  (docker/sbx-releases#685). Fix line 76's `"VALID: ..."` mention.
- `AGENTS.md` (Critical Requirement, Releasing): `make validate` needs the
  host (`sbx login`) until #685 ships; in the sandbox, run
  `sbx kit pack <kit> --output <scratch>.zip` instead. CI `validate` is off.
- In-sandbox instructions in each `kits/*/spec.yaml` (~lines 80–88) and
  `docs/toolchain.md:16`: in-sandbox `sbx` runs `sbx version` and
  `sbx kit pack`; `kit validate`/`inspect` need a host sign-in (#685).
- `scripts/sbxagent:259,312` run on the host → unchanged.

### 1.4 #629: remove the virtiofs cache export

- `scripts/sbxagent:56-62`: delete the comment block and
  `export DOCKER_SANDBOXES_ENABLE_VIRTIOFS_CACHE=0`. Nothing else references
  it (`.env.example` neither).

### 1.5 #25: one OpenRouter secret

The kit already declares `OPENROUTER_API_KEY` as `proxyManaged`
(`kits/sbxpi/spec.yaml:170-175`). The second, sandbox-scoped
`sbx secret set-custom` in `docs/setup.md` exists only for #25. #25's closing
comment confirms a fix for sandbox-scoped **GitHub** credentials, not for
OpenRouter, so the check in 1.9 verifies OpenRouter on its own.

`docs/setup.md` "OpenRouter" section (lines 52–68), so it documents only the
single-secret setup:
- Replace the "Store the key on the host twice … works around #25"
  introduction with one sentence: store the key once on the host as the
  `openrouter` secret; the proxy injects it.
- Code block: only `echo "$OPENROUTER_API_KEY" | sbx secret set openrouter`.
- Delete the now-orphaned paragraph "`--sandbox` wants that project's real
  sandbox name … `sbxpi name`".
- Keep the model and routing paragraphs that follow.

No fallback: if the 1.9 check fails, it is an unresolved v0.48.0 issue. I
report it upstream, and it must be resolved before release. The old
instructions do not come back automatically.

### 1.6 Mixins note in `docs/published-kits.md:114-125`

`pack` silence proves nothing. Gate (user, host, signed in): a fixture kit
with `mixins: [<path to a small mixin>]`, run `sbx kit validate` on it, then
`sbx run` it and check the mixin's effect is there.
- Composition works → delete the "cannot yet derive" paragraph, the WARN
  block and the "copy the spec.yaml" advice.
- Still unsupported → keep the paragraph, change "as of v0.46.0" to v0.48.0,
  and paste the current `validate` output.

### 1.7 CHANGELOG `[Unreleased]`

- `Changed`: "`sbx` v0.48.0 is now required, up from v0.46.0."
- `Changed`: "Inside a sandbox, `sbx kit validate` and `sbx kit inspect` need
  a Docker sign-in (docker/sbx-releases#685). Use `sbx kit pack` there."
- `Removed`: "The virtiofs cache workaround (docker/sbx-releases#629)."
- `Changed`: "OpenRouter setup needs one secret, not two."

### 1.8 Check, stage, hand off

- `make lint`
- `env -u SBXAGENT_LITE -u NETWORK_ALLOWLIST make test-unit`
- `sbx kit pack <each kit and the mixin> --output <scratch>/<name>.zip`
- `git add` only the changed files (not `.claude/`, not `review-plan.md`).
  Draft commit message 1. No commit or push (AGENTS.md).

### 1.9 User gates (Phase 1 is not done until they pass)

1. Host sbx v0.48.0, signed in: `make validate`.
2. Commit + push. CI `lint` and `test` green; `validate` stays off.
3. Release dry run: `gh workflow run release.yml --ref <branch>` (runs the
   new `kit pack` preflight on the runner).
4. After the commit, I run `make publish-dry-run` in the sandbox.
5. Signing probe, run **twice** with the same fresh package (first push,
   then reuse). Each run: `push` works with no `sbx login`, `sign` exits 0,
   `verify` passes.
   `gh workflow run release.yml --ref <branch> -f dry_run=false -f probe_repo=sbxprobe-048 -f probe_kit=sbxpi`
   Delete `sbxprobe-048` afterwards. If `push` or `sign` needs `sbx login`:
   stop, no release on v0.48.0.
6. #629 smoke check on macOS: first check `env | grep VIRTIOFS` in the shell
   and `grep VIRTIOFS .env` both show nothing. Rebuild one sandbox,
   `git clone` a repo into the mounted workspace, then
   `make test-toolchain AGENT=claude`.
7. OpenRouter check (1.5): with only `sbx secret set openrouter` on the host
   (no `set-custom`), create a fresh `sbxpi` sandbox.
   `./scripts/sbxpi exec printenv OPENROUTER_API_KEY` shows a sentinel, not
   the real key, and a Pi call to an OpenRouter model answers. Fail →
   unresolved v0.48.0 issue (see 1.5); no release until it is resolved.

---

## Phase 2: #420, a single startup call site (after Phase 1 is committed)

**Goal:** the trace bind is made only by each kit's `setup.startup` step.
The duplicate entrypoint call goes.

### 2.1 Code

- **Entrypoints** (`kits/{sbxclaude,sbxcodex,sbxcursor}/spec.yaml`): delete
  the `mount_state_status` block and its "bind mount does not survive a stop"
  comment. Keep the token exports and `exec <agent> "$@"`.
- **`kits/sbxpi/spec.yaml`**: `entrypoint: [pi]`. Move the
  `PI_CODING_AGENT_SESSION_DIR` note onto the startup step. Fix the
  `sandbox:` header comment.
- **Startup step comments** (4 specs, ~line 457 in sbxclaude): one call site.
  It runs on every sandbox start, including after a daemon restart. Drop the
  "this step cannot refuse to launch the agent the way the entrypoint does"
  sentence; state what 2.3 proves about failure.
- **`mount-state.sh`** (4 copies under `kits/*/files/`): header only. Called
  from the startup step; drop "the caller must refuse to start the agent".
  Keep `same_fs()` and its early exit: restarts and `exec` still run it on an
  already-bound path.

### 2.2 Tests and docs

- `tests/mount_state_test.sh`:
  - Keep cases 1–7.
  - Delete cases 8–11 (they run the entrypoint blocks).
  - Case 12: exactly **one** `mount-state.sh` call per spec, inside the
    startup block, as `user: "agent"`, with the right path and subdir; and
    the entrypoint does not mention `mount-state.sh`. Rewrite the comment
    (drop the #420 text at line 297).
- `tests/toolchain_test.sh:187-203`: comments and `BIND_HINT` name only the
  startup step.
- `tests/lifecycle_test.sh`: header (line 15), `run_entrypoint` text and
  cases 1, 3, 4: the bind comes from the startup step; `run_entrypoint` only
  starts the agent. Keep case 3's "depth does not grow" check.
- `docs/traces.md`: rename "Two call sites" (line 261) to "One call site",
  delete the #420 text, the "Once #420 is fixed" paragraph and the second
  flowchart. Keep steps 1–5 and the first flowchart; update "on failure" to
  match 2.3.
- CHANGELOG `Changed`: "Trace folders are bound only by each kit's startup
  step."
- `make lint`, unit tests, `sbx kit pack` on all kits. Stage, draft commit
  message 2.

### 2.3 Host checks (user, host sbx v0.48.0)

`sbx daemon restart` stops **every** sandbox, this session included.

1. **Replay after restart** on a sandbox built from the new specs:
   ```bash
   cd ~/Code/sbxagent
   sbx daemon restart
   ./scripts/sbxclaude exec sh -c 'echo ok > "$HOME/.claude/projects/probe-420"'
   n="$(./scripts/sbxclaude name)"
   ls "${XDG_STATE_HOME:-$HOME/.local/state}/sbxagent/traces/${n#sbxclaude-}/sbxclaude/projects/probe-420" && rm "$_"
   ```
2. **Failure propagation**, one focused check. I write a throwaway kit
   (checked with `sbx kit pack`). Its startup step writes a marker file to
   a mounted host dir (proof it ran), then `exit 1`. Its entrypoint prints
   `AGENT-LAUNCHED`. Run `sbx run --rm <probe-kit> <tmp-dir>`.
   - Marker present, no `AGENT-LAUNCHED` → done; docs say "sbx does not
     start the agent".
   - `AGENT-LAUNCHED` prints → a v0.48.0 defect. I report it upstream, and
     you decide before any release how traces stay safe. The old entrypoint
     call does **not** come back automatically.
3. Rebuild all four, `make test-lifecycle AGENT=<each>`, then
   `make test-toolchain AGENT=<each>`.
4. `make validate` on the signed-in v0.48.0 host, on the final Phase 2
   state. The 1.9 run does not cover the Phase 2 spec and helper edits, and
   `kit pack` lacks `validate`'s diagnostics. The upgrade is not done until
   this passes.

---

## Next upgrade (v0.49.0)

Turn CI `validate` back on, pass `--offline` in `make validate`, put back
`validate --offline` + `inspect --offline` in `publish-kit.sh` instead of
`kit pack`, and revert the 1.3 doc notes.
