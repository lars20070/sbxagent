# Upgrade sbx CLI: v0.39.0 → v0.42.0

Release notes: https://github.com/docker/sbx-releases/releases/tag/v0.42.0

## Context

This repo pins the `sbx` CLI version in several places (release workflow,
in-sandbox kit installers, tests, docs) rather than always tracking
`latest`, because `sbx kit` is EXPERIMENTAL and a release must pin what it
was tested against (see `AGENTS.md`). `sbx` just shipped v0.42.0. v0.40.0
and v0.41.0 were never published as real releases, so this is a direct
v0.39.0 → v0.42.0 jump with one consolidated changelog to account for.

Only one change in that changelog is relevant to this repo's behavior:
kits using `extends:` (all of `sbxclaude`, `sbxcodex`, `sbxcursor`) now
**merge** with their base kit's setup commands / network allowlist /
credentials / volumes / env vars, instead of the child's declarations
fully **replacing** the parent's. Everything else in the release (cloud
sandboxes, `tcp4`-default ports, new `sbx run <kit-ref>` shorthand) either
doesn't apply to this repo (no declared ports) or is a non-breaking
deprecation (old `sbx run --name X --kit Y Z` syntax this repo uses still
works — it may now print a deprecation notice, which is harmless since
`tests/sbxagent_test.sh` dispatches against a fake `sbx` stub, not the real
CLI).

This merge fix is not cosmetic: it's the fix for
[docker/sbx-releases#415](https://github.com/docker/sbx-releases/issues/415),
a real regression. A kit `extends: claude` (or `codex`/`cursor`) that
declares its own `setup:` block was silently dropping the parent kit's own
setup commands — for Claude kits, that included the step that fixes
ownership of `/home/agent/.claude/*` state directories, so the agent
couldn't write its own session/transcript files. This was fixed once in a
nightly build, then regressed again in the v0.39.0 this repo currently
pins. All three of `sbxclaude`, `sbxcodex`, `sbxcursor` declare their own
`setup:` blocks on top of `extends:`, so this repo is squarely in the
blast radius — this upgrade is a real bug fix, not just routine pin churn.

### Why two stages

This plan was originally one change. Splitting it in two isolates risk:

- **Stage 1** (version/checksum bump) is mechanical and low-risk — the
  existing `#415` workarounds keep working fine on v0.42.0, so nothing
  behaves differently yet.
- **Stage 2** (revert the `#415` workarounds) is the part that needs real,
  per-kit, live-sandbox verification, and can fail independently per kit.

If Stage 2 turns out to misbehave for, say, `sbxcursor`, that shouldn't
hold back the version bump or the two kits where it does work. Land Stage
1 first (its own PR/commit), confirm it's good, then do Stage 2 as a
separate PR/commit — per kit if useful — on top of it.

## Stage 1 — Bump the pinned version

### Files to change

**Mechanical version-string bump** (v0.39.0 → v0.42.0), one pattern
repeated across these locations — found via full-repo search:

- `.github/workflows/release.yml:201` — `SBX_VERSION: v0.39.0` env var used
  by the pinned install step (comment above it at line ~193 explains why
  this one is pinned while `ci.yml` tracks `latest`; leave that comment as
  is, it's still accurate).
- `tests/toolchain_test.sh:13` — `EXPECTED_SBX_VERSION="v0.39.0"`, asserted
  against real `sbx version` output in `make test-toolchain`.
- `docs/toolchain.md:57` — table row documenting the pinned version.
- `docs/published-kits.md:109` — prose note: "...but as of `sbx` v0.39.0 it
  is accepted and then ignored" (the `mixins:` field). Bump the version
  number only after the live check in Verification step 5 below confirms
  the quoted WARN text is still accurate.
- `scripts/sbxagent:6` — comment citing upstream issue #526 ("no fix as of
  sbx v0.39.0"). Confirmed issue #526 is still open upstream, so bump the
  version number with no wording change.
- `tests/sbxagent_test.sh:446` — the exact same `#526` comment pattern,
  repeated ("unaffected. Open upstream, no fix as of sbx v0.39.0:"). Same
  treatment.

**Per-kit installer blocks** — identical pattern in all four
`kits/{sbxclaude,sbxcodex,sbxcursor,sbxpi}/spec.yaml`, each with:
1. A comment `# Digests of the v0.39.0 release assets.` → bump to v0.42.0.
2. Two `expected_sha256` values (amd64, arm64) → replace with the v0.42.0
   digests, already computed and verified locally by downloading both
   `DockerSandboxes-linux-{amd64,arm64}.tar.gz` assets from the v0.42.0
   release and running `sha256sum`:
   - amd64: `a88c56f02435974145a86d983beab4458b412c2133d5da0df7f12e117d8152e7`
   - arm64: `5f16183d26f90dc98014c2abac83e4a1d13aa04390a9512b54867096ef87db89`
3. The download URL's `v0.39.0` path segment → `v0.42.0`.

All four kits share the same two digests (confirmed identical across kits
today), so this is the same 3-line edit repeated in each file. Representative
file/line anchors: `kits/sbxclaude/spec.yaml:138,141,144,154`.

**Caution:** each kit spec has a *second*, unrelated `expected_sha256` pair
further down, for `github-mcp-server` — not `sbx`. Edit inside the block
headed by the "Digests of the vX.Y.Z release assets" comment only; don't
blind-replace by checksum value alone, since that could accidentally touch
the wrong pair.

**Changelog** — add a `### Changed` entry under `## [Unreleased]` in
`CHANGELOG.md`, following the precedent of the existing `[0.4.1]` entry
that documented the original `v0.39.0` pin with checksums: "Bump the
pinned in-sandbox `sbx` CLI (and its release-workflow install) to
`v0.42.0`, with updated SHA-256 digests." Do **not** bump `VERSION` or any
kit `version:` field as part of this — that's a separate release-cutting
decision per `AGENTS.md`, out of scope here unless the user asks for it
next.

**No change needed:**
- `.github/workflows/ci.yml` — intentionally installs `latest`, unpinned,
  by design (confirmed via its own comment and `.coderabbit.yaml`'s note
  telling reviewers not to flag it).
- `scripts/sbxagent`'s `sbx run`/`sbx create` invocations (lines 133, 136,
  171) — the old `--name X --kit Y Z` form they use is deprecated in
  0.42.0 but still works; `tests/sbxagent_test.sh`'s `assert_log` checks
  against that exact argv shape stay valid. (Migrating to the new
  `sbx run <kit-ref>` form is a reasonable separate follow-up — deliberately
  out of scope for both stages of this plan, to keep the bump and the
  `#415` revert the only two things changing.)
- No kit declares `ports:`, so the new `tcp4`-default for
  `sbx ports --publish` doesn't affect anything here.
- `CHANGELOG.md:299` — the existing, already-published `[0.4.1]` entry's
  own historical text ("in-sandbox `sbx` `v0.39.0` with SHA-256
  verification..."). This is a past record, not a current pin — Keep a
  Changelog entries are append-only history. Do **not** rewrite it; only
  add a new entry under `[Unreleased]`.

### Verification

1. `rg -n "0\.39\.0"` across the whole repo, expecting only the
   `CHANGELOG.md:299` historical entry left — this is the actual check that
   nothing was missed. (`make lint` does *not* grep for stray version
   strings — it only checks markdownlint/yamllint/shellcheck and a
   `VERSION`/kit-`version:`/changelog-heading agreement check, which this
   change doesn't touch. Still run `make lint` afterward to confirm the
   edited YAML/shell stays clean, just don't rely on it to catch leftovers.)
2. **Upgrade your own host `sbx` CLI to v0.42.0 first, and record
   `sbx version`'s output** — `make validate` and any ad-hoc
   `sbx kit inspect` run against whatever `sbx` binary is on the host's
   `$PATH`, which is entirely separate from the in-sandbox pinned copy this
   plan edits in `kits/*/spec.yaml`. Editing the kit specs alone does not
   upgrade the host CLI. Then run `make validate` — schema-validates all
   four kit specs against the real v0.42.0 `sbx kit validate` — catches
   any spec schema drift.
3. `make test-unit` — fake-`sbx` dispatch tests; should be unaffected, run
   to confirm.
4. **`make test-toolchain` — once per kit, against a freshly rebuilt
   sandbox each time, not a reused one:**
   `./scripts/sbx<agent> exec ./tests/toolchain_test.sh` (what
   `make test-toolchain AGENT=<agent>` runs) only runs a command *inside
   the sandbox that already exists under that name* — it does not rebuild
   anything. If `sbxclaude`/`sbxcodex`/`sbxcursor`/`sbxpi` sandboxes from
   before this upgrade are still sitting around, this step would silently
   test the *old* pre-upgrade sandbox and falsely "confirm" v0.42.0 is
   installed. For each of the four kits: remove any existing sandbox of
   that name first (`./scripts/sbx<agent> rm` — destructive, asks to
   confirm, get the user's go-ahead before running it for real), then
   `./scripts/sbx<agent> create` (or just attach) to force a fresh build
   from the *edited* spec, then run:
   ```bash
   make test-toolchain AGENT=claude
   make test-toolchain AGENT=codex
   make test-toolchain AGENT=cursor
   make test-toolchain AGENT=pi
   ```
   Each checks the real `sbx version` inside that sandbox against
   `EXPECTED_SBX_VERSION` — this is what actually proves the checksum/URL
   bump installed v0.42.0, not just that the spec file says so. Keep these
   four freshly rebuilt sandboxes around — Stage 2's verification reuses
   them.
5. **`docs/published-kits.md:109`'s `mixins:` WARN text — verify live
   before bumping its version number:** "the 0.42.0 release notes don't
   mention a fix" is not enough evidence for a claim this specific — the
   exact WARN string could have changed wording even if the underlying
   behavior didn't. On one of the freshly rebuilt sandboxes from step 4,
   run `sbx kit validate` against a spec with a `mixins:` field and
   confirm the warning text verbatim. If the wording changed, update the
   quoted text to match; if not, just bump the version number.

Land this stage (commit/PR) once 1-5 pass, before starting Stage 2.

## Stage 2 — Revert the `#415` workarounds

### The workarounds already in the code

All three `extends:`-based kits already carry a hand-written compensation
for issue #415, each explicitly marked as temporary:

- `kits/sbxclaude/spec.yaml:10-41` — the `sandbox.entrypoint` is a custom
  `sh -c` script, headed by `# OLD CODE: # entrypoint: [claude] ...` /
  `# TEMPORARY: works around sbx dropping the parent claude kit's setup...`
  `# Revert to entrypoint: [claude] once sbx merges parent and child setup
  instead of replacing.`. The script does two unrelated things: (1) a
  `sudo chown -hR` fixup of `$HOME/.claude` and `$HOME/.claude.json` — this
  is the #415 compensation, replacing a step the parent `claude` kit
  normally runs itself; (2) exporting `GH_TOKEN` as `GITHUB_TOKEN` before
  `exec claude "$@"` — unrelated plumbing for the GitHub MCP server,
  added later (`git log`, commit `75b9eae`, well after the #415 workaround
  was introduced in the kit's very first commit `b5ab604`).
- `kits/sbxcodex/spec.yaml:10-42` — same shape: a `sudo chown -hR` fixup of
  `$HOME/.codex` (the #415 part) plus `GH_TOKEN`/`GITHUB_PERSONAL_ACCESS_TOKEN`
  export (unrelated, keep) before `exec codex "$@"`. **Additionally**,
  `kits/sbxcodex/spec.yaml:377-427` and `:472-494` are two more setup steps
  explicitly commented `(replicated parent step)` / `"Replicated verbatim
  from the embedded codex parent kit... drop it once #415 is fixed"` — one
  seeds `~/.codex/config.toml` and `auth.json`, the other registers the
  sandbox MCP gateway in `startup:`. Both exist only because #415 used to
  drop the parent's own install/startup steps.
- `kits/sbxcursor/spec.yaml:10-43` — the entrypoint here has **no chown at
  all** ("No chown here, deliberately" — cursor's workaround lives
  elsewhere), so the entrypoint body itself doesn't need to change; only
  its now-stale `OLD CODE`/`TEMPORARY` comment block does. The real
  workaround is `kits/sbxcursor/spec.yaml:124-165`, an explicit
  `# ---- Replicated from the embedded cursor parent kit ----` /
  `# ---- End replicated parent steps ----` block of **three** setup
  steps (ensure `~/.cursor` ownership, pre-trust the workspace, seed
  `cli-config.json` for HTTP/1.1) — each tagged "replicated parent step"
  and the surrounding comment says plainly: "Keep them in sync with the
  parent when bumping the pinned sbx version, and drop them once #415 is
  fixed."
- `kits/sbxpi/spec.yaml` has no workaround (no `extends:`, confirmed
  clean: `entrypoint: [pi]` with a comment noting there's no #415
  collision to work around).

**Important nuance:** do not take the stale "OLD CODE" comments literally.
For `sbxclaude` and `sbxcodex`, reverting to the bare one-line
`entrypoint: [claude]` / `entrypoint: [codex]` shown in those comments
would also delete the unrelated `GH_TOKEN` export logic that was added
afterward and is still needed. Only remove the chown/ownership-fixup
lines; keep the custom `sh -c` wrapper and the token-export block.

### Files to change

Do these **one kit at a time** (one commit/PR per kit is reasonable, given
each needs its own live-sandbox test and can pass or fail independently):

- `kits/sbxclaude/spec.yaml` — from the entrypoint script, remove the
  `owner="$(id -u):$(id -g)"` line and both `chown` blocks (`$HOME/.claude`
  and `$HOME/.claude.json`). Keep the `sh -c` wrapper, the `GH_TOKEN`
  export block, and `exec claude "$@"`. Replace the stale
  `OLD CODE`/`TEMPORARY`/`Revert to...` comment with a short note that this
  entrypoint only exists now for the token export, not for #415.
- `kits/sbxcodex/spec.yaml` — same entrypoint treatment (remove the
  `$HOME/.codex` chown, keep the token-export wrapper). Then remove the two
  replicated steps at `:377-427` (config.toml/auth.json seeding) and
  `:472-494` (MCP gateway registration) — but only after verifying the
  parent `codex` kit's own equivalent steps actually run and produce the
  same `config.toml`/`auth.json`/gateway registration (the kit's own
  comment references a "Stage 2 spike" that verified this by diffing
  output byte-for-byte; repeat that comparison).
- `kits/sbxcursor/spec.yaml` — remove the stale `OLD CODE`/`TEMPORARY`
  comment above the entrypoint (the entrypoint body itself is unaffected,
  it never had a chown). Remove the three-step
  `---- Replicated from the embedded cursor parent kit ----` block at
  `:126-164`, after verifying the parent `cursor` kit's own `install`,
  `startup`, and `files` entries now run and produce working
  `~/.cursor` ownership, workspace pre-trust, and `cli-config.json` seeding
  without them.
- `kits/sbxpi/spec.yaml` — no change (no `extends:`, nothing to revert).

If any single kit's revert doesn't hold up under testing, leave that one
workaround in place (it's still correct and safe, just no longer
necessary-in-theory) and land the other kits' reverts without it — don't
block the kits that do work on the one that doesn't.

**Changelog** — add a `### Fixed` entry under `## [Unreleased]` in
`CHANGELOG.md` for whichever kits' reverts actually land: "`sbxclaude`/
`sbxcodex`/`sbxcursor` no longer carry a hand-written workaround for
[docker/sbx-releases#415](https://github.com/docker/sbx-releases/issues/415)
now that `sbx` v0.42.0 merges a child kit's `setup:` with its parent's
instead of replacing it." Only name the kits this actually holds true for,
per the per-kit test results — if, say, only `sbxclaude` and `sbxcodex`
land and `sbxcursor` doesn't, say so.

**Considered and declined — keep the custom entrypoint wrapper, don't
restructure it.** One reviewer suggestion was to fully revert
`sbxclaude`/`sbxcodex`'s entrypoint to the bare `[claude]`/`[codex]` form
and move the GH_TOKEN export into a separate setup/startup hook instead.
Declined for this plan: the token export's own comment already documents
its scope is entrypoint-only by design ("only covers the agent session
this entrypoint starts"), that's a pre-existing, unrelated design
decision, and redesigning it isn't necessary to fix #415 — only the chown
lines were ever the #415 workaround. Moving it would add risk (unverified
whether a `startup:` hook sees the same runtime env vars an entrypoint
does) for no benefit tied to this upgrade. Keeping the wrapper, minus the
chown, is the smaller and safer change. Revisit only if the user wants
that separately.

### Verification

1. **Extends-merge check — run this first, before touching any workaround
   code, with the workarounds still in place, on the same freshly rebuilt
   sandboxes from Stage 1 step 4:** for each of `sbxclaude`, `sbxcodex`,
   `sbxcursor`, inspect the effective built sandbox (`sbx kit inspect`, or
   check the actual setup commands/network allowlist that ran) and compare
   against what the spec alone declares. Confirm the parent kit's setup
   commands now run *in addition to* the child's (not replaced). While
   here, also check two things the merge can affect beyond the entrypoint
   workaround:
   - **Network allowlist breadth:** the effective allowlist may now be
     broader than the child spec alone shows (parent + child, merged).
     Compare it against each kit's own `permissions.network.allow` list
     and confirm nothing outside the intended least-privilege set snuck
     in via the parent.
   - **Credential/env/volume collisions:** check whether the parent kit
     declares its own `GITHUB_TOKEN`/credential handling that might now
     run alongside this repo's own GH_TOKEN export logic, and whether
     that's a harmless duplicate or an actual conflict.
2. **Per-kit revert + re-test, one kit at a time:** for each kit, make just
   that kit's revert from "Files to change" above, rebuild, and re-check
   the exact symptom its workaround existed for — reusing issue #415's own
   repro steps and this repo's existing checks:
   - `sbxclaude`: `sbx exec <sandbox> -- stat -c '%U:%G %a %n' /home/agent/.claude/projects /home/agent/.claude/sessions /home/agent/.claude/todos /home/agent/.claude/shell-snapshots /home/agent/.claude/statsig` should show `agent:agent`, not `root:root` (the exact #415 repro check); also confirm `sbx exec <sandbox> -- mkdir /home/agent/.claude/projects/revert-test` succeeds.
   - `sbxcodex`: confirm `~/.codex/config.toml` and `auth.json` are seeded correctly for each `SBX_CRED_OPENAI_MODE`, and the MCP gateway registers when `MCP_GATEWAY_URL` is set — compare byte-for-byte against the version with the workaround still in, the way the kit's own comment says the original "Stage 2 spike" did.
   - `sbxcursor`: confirm `~/.cursor` is agent-owned, the workspace pre-trust file is created, and `cli-config.json` exists with HTTP/1.1 enabled — `tests/toolchain_test.sh` already asserts some of this per the kit's own comment, so lean on that test rather than re-deriving the check.
   If a kit's re-test fails, revert just that kit's code change and keep
   its workaround; land the other kits' reverts on their own.
3. `make lint` and `make validate` after every spec edit in this stage —
   cheap, catches YAML/schema mistakes immediately per kit.
