# Upgrade sbx v0.45.0 → v0.46.0, and drop workarounds that upstream fixed

## Context

sbx v0.46.0 is out (released 2026-09-28). The repo pins v0.45.0 in several
places. Some upstream issues we work around have since been closed. This plan
bumps the pin and removes only the workarounds that are really safe to remove.

### Upstream status (checked 2026-09-29)

| Issue | State | In v0.46.0? | What it means for us |
|---|---|---|---|
| #420 startup steps don't replay after a daemon restart | **open** | no | Keep both `mount-state.sh` call sites. Only bump the "as of" text. |
| #479 `sbx exec` skips the MCP gateway | closed | fix said "v0.44" | No workaround in the repo. Nothing to do. |
| #526 `cp` out of the workspace writes NUL bytes | closed | fixed in **v0.45.0** (maintainer). Checked here: `SEEK_DATA=0`, `SEEK_HOLE=EOF`, `st_blocks>0` | The `cat` hack in the unit test goes. The cache export **stays** (see #629). |
| #629 virtiofs cache breaks `git clone` (`link()` / `fsync` ENOTEMPTY) | **open**, maintainer targets a fix in **v0.48.0** | no | Now the real reason for `DOCKER_SANDBOXES_ENABLE_VIRTIOFS_CACHE=0`. |
| #553 `sbx kit sign` exits 1 on GHCR (405) | closed, still labelled `awaiting-release` | **unknown**, not in the release notes | Must be proven with a probe publish before touching `publish-kit.sh`. |
| #581 `setup.files` `source:` + `user:` | **open** | no | Heredocs, mirrors and the `make lint` sync check all stay. |
| #637 codex kit writes `type`/`headers` | closed 2026-09-29, "upcoming release" | no | No workaround in the repo. Nothing to do. |
| #388, #25, #231 | open | no | Unchanged. |

v0.46.0 release notes, one doc change:
- On **Linux arm64** hosts the default CPU allocation is now capped at 16.
  No kit sets `cpus`, so this changes our default there, and
  `docs/toolchain.md:38` ("every host CPU") becomes wrong. Fix it in Part A.
  No resource override is needed.

v0.46.0 release notes, other items: none need a code change.
- The secret `--command` breaking change: we never use `--command`.
- The `balanced` preset now allows `cdn.playwright.dev`: our kits allowlist it
  themselves, so it works under any preset. Keep it.
- The skills-dir, dash `SIGTERM` and `kit add` fixes: we have no workaround for
  any of them.

## Part A — Bump the pin (do now)

v0.46.0 digests (from the GitHub release assets):
- `linux-amd64.tar.gz` = `linux.tar.gz` (byte-identical, as before):
  `edd86e2f21559e190723fd884c3a1dced161a555afdff85c5921ed45e7d6d56e`
- `linux-arm64.tar.gz`:
  `b20da2e5e2ba7a67151a19821960c657c08d8fa8dcfdf5e9751f284d6e55ffa8`

Follow the existing procedure in `docs/toolchain.md` ("To bump a pin"):

1. All four `kits/*/spec.yaml` (the "sbx CLI for offline kit commands" step):
   the version in the comment and URL, plus both `expected_sha256` values.
2. `.github/workflows/release.yml`: `SBX_VERSION: v0.46.0` and `SBX_SHA256`
   (the amd64 digest). Update the "v0.45.0 Linux archive" comment.
3. `tests/toolchain_test.sh:14`: `EXPECTED_SBX_VERSION="v0.46.0"`.
4. `README.md:108`: "sbx v0.46.0 is required".
5. `docs/toolchain.md:75`: table row → `v0.46.0`.
6. Change "still open as of sbx v0.45.0" to v0.46.0 for #420 in: all four kit
   specs (startup comment), `tests/mount_state_test.sh:297`,
   `docs/traces.md:271`.
7. `docs/published-kits.md:116` ("mixins accepted then ignored, as of
   v0.45.0"). None of our kits declares `mixins:`, so validating them proves
   nothing. Instead, write a throwaway kit in the scratchpad that lists
   `mixins:` and a tiny mixin (e.g. one that sets an env var). Run
   `sbx kit validate` on it with v0.46.0. If the "not yet implemented"
   warning is still there, change the doc to "as of v0.46.0". If it's gone,
   ask the user to `sbx run` the throwaway kit on the host to see whether
   the mixin is really applied. Rewrite the doc only on that runtime
   evidence.
8. `tests/lifecycle_test.sh:66` says "from sbx v0.45.0". That is a historical
   fact, so leave it.
9. `docs/toolchain.md:38`: "every host CPU" → every host CPU, except on
   Linux arm64 hosts where sbx caps the default at 16 (from v0.46.0).
10. `CHANGELOG.md` under `## [Unreleased]` → `### Changed`: requires sbx
    v0.46.0; the sandboxes ship v0.46.0 for the offline `sbx kit` commands; on
    Linux arm64 hosts a sandbox now gets at most 16 CPUs by default.

## Part B — Remove the #526 workaround, re-justify the cache flag (do now)

1. `scripts/sbxagent:56-61`: keep `export DOCKER_SANDBOXES_ENABLE_VIRTIOFS_CACHE=0`.
   Rewrite the comment: #526 is fixed in v0.45.0. The flag now guards against
   #629 (with the cache on, a `link()`ed name is missing from `readdir` and
   `fsync` returns ENOTEMPTY, which breaks `git clone` into the workspace on
   macOS). Remove the export once #629 is fixed in the pinned release.
2. `tests/sbxagent_test.sh:680-687`: go back to
   `cp "${AGENT_SCRIPT}" "${COPIED}"` and delete the #526 comment.

## Part C — Signing workaround for #553 (only after the probe proves the fix)

Part C is optional. It is not needed for the pin bump.

**Gate first: probe the upstream CLI.** Once Part A is committed and pushed on
a branch, the user runs the release workflow by hand:
- `workflow_dispatch` on **that branch** (pick it in "Use workflow from").
- `dry_run: false`, `probe_kit: sbxpi`, and a **fresh** `probe_repo` such as
  `sbxprobe-046`. Don't use the old `sbxprobe`: the publisher reuses an
  existing tag, and `verify` could pass on the old signature.

A fresh package also recreates the #553 case: `kit push` attaches provenance
as the first referrer, and `sign` adds the second.

Read three things in the job log:
1. `sbx version` prints `v0.46.0`.
2. The sign step prints `sign reported success …`, **not** the three
   `NOTICE:` lines. (The current script logs which of the two happened.)
   Ideally there is also the new upstream warning about a dangling referrers
   index.
3. `sbx kit verify` prints `VERIFIED`.

All three → the fix shipped. `VERIFIED` alone proves nothing about #553.

If it passes, edit `scripts/publish-kit.sh:254-329`. The behavior:
- Always run both `sign` and `verify`. `signed` stays the result of
  **verify** only (as today, line 285).
- New flag `sign_failed`, set when `sbx kit sign` exits non-zero. The three
  `NOTICE:` lines go.
- Failure stays deferred to the end (line 326), so the outputs and job
  summary still get written. There, in this order:
  - `sign_failed` → `die "… sbx kit sign failed …"`
  - `verify_failed` → the existing "could not be verified" message.
  So the message always names the command that really failed.
- `sbx kit verify` stays as the identity gate.
- Rewrite the comment block: sign's exit code can be trusted again as of sbx
  v0.46.0 (#553). Verify still checks the signer is this repo's workflow.
- Remove the `AGENTS.md` section "A red `sbx kit sign` does not mean the release
  is unsigned" (lines ~150-179).
- Keep `docs/published-kits.md:28-32`. GHCR still has no referrers API, so the
  `sha256-<digest>` tag still exists.
- Test the edited script's two branches. There is no publish-kit test, and
  `make publish-dry-run` exits before signing. So:
  - One-off runs in the scratchpad with stub `sbx` and `oras` scripts on
    `PATH`. They are not committed. Three cases, with only **one** stub
    failing in each:
    | stub `sign` | stub `verify` | expect |
    |---|---|---|
    | exit 1 | exit 0 | non-zero, `signed=yes`, message names **sign** |
    | exit 0 | exit 1 | non-zero, `signed=no`, message names **verify** |
    | exit 0 | exit 0 | zero, `signed=yes` |
    The first case is the one that matters: today's script passes it, the new
    one must fail it. If stubbing the steps before signing gets too heavy,
    stop and ask the user.
  - Success branch: a second probe dispatch with the edited script and
    another fresh `probe_repo` (e.g. `sbxprobe-046b`). The job must be green
    with `signed=yes`.
- The user reports the result on #553. They said they would.

If the probe fails, first find **which** command failed and read its error.
Only if `sbx kit sign` fails with the 405 "failed to delete dangling referrers
index" error is it #553. Then leave `publish-kit.sh` alone, change the AGENTS.md
text to "still present in v0.46.0", and the user reopens #553. Any other
failure (auth, push, provenance, verify) is a different problem and does not
touch #553.

## Verification (in this order)

The `sbx` on `PATH` in this sandbox is the in-sandbox copy, still v0.45.0.
Editing the kits does not change it. So every schema or runtime check that
counts must run against v0.46.0.

0. **Temporary v0.46.0 CLI here.** Download
   `DockerSandboxes-linux-${arch}.tar.gz` for v0.46.0 into the scratchpad,
   check its SHA-256 against the digest above, extract `docker-sbx/sbx`, and
   put that directory first on `PATH` for steps 1, 3 and 7. Confirm
   `sbx version` prints `v0.46.0`. (If github.com downloads are blocked, stop
   and report it.)
1. Me, on the working tree, with v0.46.0 on `PATH`: `make lint`,
   `make test-unit` (the `cp` change in `sbxagent_test.sh`), `make validate`.
2. I stage the changes and draft the commit message. The user commits. No
   commits or pushes by me.
3. On that commit, with v0.46.0 on `PATH`: `make publish-dry-run`. This
   checks that each staged kit validates. Plain `sbx kit inspect` does not
   print install bodies, so check the pins separately:
   `git show HEAD:kits/<kit>/spec.yaml | rg 'v0\.46\.0|edd86e2f|b20da2e5'` for
   each of the four kits. Each must show the new URL and both digests.
4. **Host upgrade** (needed for the runtime checks only). User upgrades the host
   `sbx`, runs `sbx daemon restart`, and confirms `sbx version` prints
   `v0.46.0`.
5. User on the host, once per agent (the digest check runs at kit-build time):
   `./scripts/sbxclaude rm`, `./scripts/sbxclaude create`, then
   `make test-toolchain AGENT=claude` (checks the in-sandbox
   `EXPECTED_SBX_VERSION`). Repeat for codex, cursor, pi.
6. Runtime checks for Part B, in one rebuilt sandbox on a macOS host (host
   v0.46.0, cache flag set). These show the flag protects us. They do **not**
   show #629 is fixed upstream, and the export stays whatever they print.
   - #526: `cp` a nonempty workspace file to `/tmp`, then `cmp` it with the
     original. Must match.
   - #629 fault 1 (link): the issue's Python repro in a scratch folder of the
     mounted workspace. Create `a.tmp` with `O_CREAT|O_EXCL`, `link` it to
     `a`, `unlink` `a.tmp`, then list the folder. Loop 200 times. `a` must
     be listed every time.
   - #629 fault 2 (fsync): `git clone --no-local file://…` of a local repo
     whose pack is about **19 MB** into the mounted workspace, about 20
     times. A small repo never triggers it, the reporter says. Every clone
     must succeed. Build the repo in `/tmp` from random data so no network
     is needed.
   - Delete the scratch folders afterwards.
7. User on the host: `make test-lifecycle AGENT=claude` (and any other agent
   whose trace mounts we rely on). This covers normal stop/start and both
   `mount-state.sh` call sites. It never restarts the daemon, so it does
   **not** reproduce #420. That's fine: we keep the #420 workaround, and this
   pin bump doesn't add a daemon-restart test.
8. Part A step 7: the throwaway `mixins:` kit, validated with the v0.46.0 CLI
   from step 0.
9. User pushes the branch → Part C probe (optional).
