# Plan: bump sbx to v0.49.1, drop the `kit pack` workaround, turn CI validate back on

## Context

Since sbx v0.47.0, `sbx kit validate` and `sbx kit inspect` need `sbx login`
and a running daemon (docker/sbx-releases#685). v0.48.0 did not fix it, so the
repo used `sbx kit pack` as a stand-in check and switched off the CI
`validate` job. v0.49.1 (stable, 2026-10-20) adds `--offline` to
`kit validate` and `kit inspect`. Without the flag they still need a login,
so every caller must pass `--offline`.

Goal: pin v0.49.1 everywhere, pass `--offline`, remove every `kit pack`
use and mention, and turn the CI `validate` job back on.

Decision (user): the wrapper always passes `--offline`.

Other upstream refs checked: #388 (a regression test) and #231 (a design
note) are not workarounds, so they stay. Older CHANGELOG entries are history
and stay. Old notes in `tmp/*.md` and `.claude/plans/stateless-frolicking-peach.md`
also stay as they are.

## v0.49.1 digests (GitHub API asset digests)

- `DockerSandboxes-linux-amd64.tar.gz`:
  `4f2aa3dc6404e3700925e6baeda72ca26d8a36768d2bfe8056f1e8ecdfd4540e`
- `DockerSandboxes-linux-arm64.tar.gz`:
  `3a3feaf4832ffc070c76e5eddd99fb32aa29a9e686ae9c8ac8117c9ecd49920e`
- `DockerSandboxes-linux.tar.gz`: same as amd64 (`4f2aa3dc…`)

## Changes

1. **All four `kits/*/spec.yaml`** (the blocks are the same in each):
   - In the sbx install step, change `v0.48.0` to `v0.49.1` in the comment and
     URL, and swap in the two digests above.
   - Instructions paragraph: replace the "runs only `sbx version` and
     `sbx kit pack` … (docker/sbx-releases#685) … `sbx kit pack <kit>
     --output <file>.zip`" text with the pre-workaround wording, offline
     version: the in-sandbox `sbx` supports only `sbx version`,
     `sbx kit validate --offline` and `sbx kit inspect --offline`. Keep the
     sentence about the commands that need the host CLI and `sandboxd`.
2. **`.github/workflows/release.yml`**: `SBX_VERSION: v0.49.1`,
   `SBX_SHA256: 4f2aa3dc…`, the comment `v0.48.0` → `v0.49.1`, and the fd 3
   comment back to "`sbx kit validate`/`inspect` and oras chatter".
3. **`.github/workflows/ci.yml`**: in the `validate` job, delete `if: false`
   and the "Switched off …" comment block. It already installs `latest` sbx
   (now v0.49.1) and runs `make validate`.
4. **`scripts/sbxagent`**: line 251 (check before `sbx run`) and line 304
   (`kit validate`) become `sbx kit validate --offline "${KIT}"`.
5. **`Makefile`** `validate`: the mixin line becomes
   `sbx kit validate --offline mixins/open-network`. The four wrapper lines
   stay the same.
6. **`scripts/publish-kit.sh`**: replace `sbx kit pack … --output …` and its
   comment with the pre-workaround pair:
   `sbx kit validate --offline "${staged}"` and
   `sbx kit inspect --offline "${staged}"`. The comment goes back to
   "validate and inspect before the dry-run exit, so a dry run still catches a
   broken kit and still shows exactly what would ship". Restore the fd 3
   header comment ("VALID: …" line, inspect report, oras chatter).
7. **`tests/sbxagent_test.sh`**: in the 8 asserts that expect
   `kit\tvalidate\t<KIT>` (lines ~279, 331, 402, 453, 490, 553, 589, 669),
   add `--offline\t`.
8. **`tests/toolchain_test.sh`**: `EXPECTED_SBX_VERSION="v0.49.1"`.
9. **`AGENTS.md`**:
   - Critical Requirement: back to "run `make validate` — it validates every
     kit; it is a static schema check with no Docker, no `sbx login`, and no
     network, so there is no reason to skip it". Drop the `kit pack` and
     "CI job switched off" sentences.
   - Releasing: "It stages, validates and inspects each kit and prints what
     would be pushed, without a registry or credentials."
10. **`docs/toolchain.md`**: `sbx` row → "daemon-free kit commands —
    `version`, `kit validate --offline`, `kit inspect --offline` — so
    `make validate` runs in-sandbox". Pin table: `v0.49.1`.
11. **`README.md`**: "sbx v0.49.1 is required". Command table:
    `sbx<agent> kit validate` → "Check the kit against the current schema
    (offline)".
12. **`docs/published-kits.md`**: "as of `sbx` v0.48.0" → `v0.49.1`, but only
    if v0.49.1 still prints the `mixins` warning (checked below). If it does
    not, rewrite that section to match.
13. **`CHANGELOG.md`** `## [Unreleased]` → `### Changed`:
    - `sbx` v0.49.1 is now required, up from v0.48.0.
    - `sbx<agent> kit validate` and the check before a new sandbox starts now
      run `sbx kit validate --offline`, so they no longer need `sbx login` or
      a running daemon
      ([docker/sbx-releases#685](https://github.com/docker/sbx-releases/issues/685),
      fixed in v0.49.1). Inside a sandbox, `make validate`,
      `sbx kit validate --offline` and `sbx kit inspect --offline` work again.
      `scripts/publish-kit.sh` validates and inspects each kit again instead
      of using `sbx kit pack`.
14. **Memory**: after the work is done, update
    `sbx-047-kit-validate-needs-login.md` to say the pin is now v0.49.1 and
    the workaround is gone.

No `git commit`/`push`. Stage the changes and give the user a commit message.

## Verification

In the sandbox (the `sbx` on PATH is still v0.48.0 and has no `--offline`):

1. Download `DockerSandboxes-linux-arm64.tar.gz` v0.49.1 into the scratchpad,
   check SHA-256 = `3a3feaf4…`, extract it, and put its `docker-sbx/` first on
   `PATH` for steps 2–4.
2. `make validate`: all four kits plus the mixin pass offline. Note whether
   the `mixins` warning still prints (for change 12).
3. `DRY_RUN=1 ./scripts/publish-kit.sh sbxclaude "$(cat VERSION)"`: this
   exercises the new validate/inspect lines. It stages HEAD, so the full
   `make publish-dry-run` only covers the new specs after the user commits.
4. `rg -n "kit pack"`: no hits outside CHANGELOG history, `tmp/` and old plans.
5. `make lint`.
6. `env -u SBXAGENT_LITE -u NETWORK_ALLOWLIST make test-unit`.

User, on the host (needs the host `sbx`):

- Upgrade the host `sbx` to v0.49.1.
- Rebuild each sandbox, then run `make test-toolchain AGENT=<agent>` once per
  agent (it checks `sbx version` = v0.49.1).
- After commit: `make publish-dry-run`. After push: the CI `validate` job
  should go green on both Linux and macOS.
