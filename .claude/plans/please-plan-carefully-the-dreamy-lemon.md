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
works).

Goal: bump every pinned reference to v0.39.0 up to v0.42.0, keep the four
kits' checksum-verified installers correct, and specifically verify the
`extends:` merge behavior doesn't silently change what ships in the three
extending kits.

## Files to change

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
  is accepted and then ignored". Bump the version number; re-confirm the
  quirk itself is still true during verification (0.42.0's changelog lists
  no fix matching this) rather than assuming.
- `scripts/sbxagent:6` — comment citing upstream issue #526 ("no fix as of
  sbx v0.39.0"). 0.42.0's changelog lists no matching fix for this virtiofs
  cache bug either, so bump the version number only, unless verification
  shows otherwise.

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

**Changelog** — add a `### Changed` entry under `## [Unreleased]` in
`CHANGELOG.md`, following the precedent of the existing `[0.4.1]` entry
that documented the original `v0.39.0` pin with checksums. Something like:
"Bump the pinned in-sandbox `sbx` CLI (and its release-workflow install) to
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
  against that exact argv shape stay valid.
- No kit declares `ports:`, so the new `tcp4`-default for
  `sbx ports --publish` doesn't affect anything here.

## Verification

1. `make lint` — confirms nothing is left referencing `0.39.0` incorrectly
   and that the changed YAML/shell still passes shellcheck/yamllint.
2. `make validate` — schema-validates all four kit specs against the (now
   0.42.0) `sbx kit validate` — catches any spec schema drift.
3. `make test-unit` — fake-`sbx` dispatch tests; should be unaffected, run
   to confirm.
4. `make test-toolchain` — runs the *real* `sbx` inside a live sandbox and
   checks `sbx version` against `EXPECTED_SBX_VERSION`; this is what
   proves the checksum/URL bump actually installs and runs v0.42.0
   end-to-end inside each kit.
5. **Extends-merge check (the one real risk):** for each of `sbxclaude`,
   `sbxcodex`, `sbxcursor` (all three use `extends:`), inspect the
   effective built sandbox after `make validate`/a live build — e.g.
   `sbx kit inspect` on each spec, or build a sandbox and check the actual
   network allowlist / setup commands that ran — and compare against what
   the spec alone declares. If the base kit (`claude`/`codex`/`cursor`)
   now contributes extra setup commands, network hosts, or env vars on top
   of the repo's own (because merge replaced replace-semantics), confirm
   nothing duplicates destructively or breaks; only edit a kit spec if
   something actually misbehaves; otherwise just note the findings.
6. Re-check the two version-tied prose claims (`docs/published-kits.md:109`
   ignored-field quirk, `scripts/sbxagent:6` virtiofs cache comment)
   against actual 0.42.0 behavior if convenient during testing; reword only
   if they turn out to have changed.
