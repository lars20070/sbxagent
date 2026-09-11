# Plan: four cheap trust signals for `sbxagent`

## Context

A review (`trust-playbook-2026.md`) listed things a small OSS tool should do so
users can check it rather than trust it. Most of the list is already done here:
least-privilege CI, SHA-pinned Actions, Sigstore-signed kits gated on
`sbx kit verify`, hash-checked binary downloads, an honest guard table in the
README. Four items are genuinely missing:

1. `SECURITY.md` — no disclosure policy.
2. Private Vulnerability Reporting — off (`gh api .../private-vulnerability-reporting` → `enabled: false`).
3. Dependabot for `github-actions` — none, so the SHA pins will silently go stale.
4. OpenSSF Scorecard — none.

**Correction to earlier analysis:** release tags are NOT signed. `v0.4.1`–`v0.4.3`
are lightweight tags (`git cat-file -t v0.4.3` → `commit`; `git tag -v` →
"cannot verify a non-tag object"). The signature seen on the tagged commit is
GitHub's web-flow key on the merge commit, not the maintainer's. The
verifiable supply-chain claim today is the keyless signature + provenance on the
published kits — not a signed git tag. Signed tags are a separate follow-up
(Stage 5), not a completed control, and `SECURITY.md` must not claim them.

Goal: add the four items in stages, each stage independently mergeable and
green under `make lint`, so the repo *signals* the hygiene it already
practises.

Constraints from `AGENTS.md`: never commit or push; stage + hand over the
message. Workflows keep the existing pattern — top-level
`permissions: contents: read`, per-job elevation, `persist-credentials: false`,
every `uses:` pinned to a full SHA with a `# vX.Y.Z` trailer. New words go in
`.cspell.json`. User-facing changes go under `## [Unreleased]` in `CHANGELOG.md`.

**Lint gotcha (applies to every stage):** `make lint` enumerates inputs with
`git ls-files`, so an untracked file is invisible to markdownlint, yamllint and
cspell. Always `git add` new files (or `git add -N` for intent-to-add) *before*
running `make lint`, then review `git diff --cached`.

## Stage 1 — files only, no repo-settings changes (~20 min)

### 1a. `SECURITY.md` (repo root)

Short. Sections:

- **Supported versions**: latest release only (`VERSION`); older tags get no fixes.
- **Reporting**: use GitHub Private Vulnerability Reporting
  (`https://github.com/lars20070/sbxagent/security/advisories/new`). No email
  address — keeps the file free of PII and works once PVR is on in Stage 2.
  Ask not to open public issues for security bugs.
- **Scope / threat model** (this is the part that builds trust — the README
  already says "a `yes` means a guard runs, not that it cannot be escaped";
  restate the boundary in one place):
  - What the sandbox is for: contain an agent working on an untrusted repo.
  - What it does **not** protect: the mounted project (read-write; a rogue
    agent can destroy or rewrite it), and anything reachable with the injected
    GitHub token (pushes, PRs — the token itself never enters the sandbox, but
    its *powers* do). Link `docs/setup.md`.
  - Guard enforcement varies per agent, per `docs/agents.md`: Claude Code is a
    hard stop; Codex is soft (nothing enforces the stop); Cursor has no guard;
    Pi's guard can be unregistered by the agent. Link `docs/agents.md` for
    the detail rather than duplicating its table.
- **Verifying what you run**: what is signed is the published kit in GHCR
  (keyless Sigstore, provenance from this repo's release workflow). Link
  `docs/published-kits.md` (no line number — the command block moves) for the
  `sbx kit verify` invocation. Do **not** claim signed tags or signed commits.

Lint: markdownlint + cspell run over every tracked `*.md` — so `git add
SECURITY.md` first. Add any new words (e.g. "advisories"; check on first
`make lint`).

### 1b. `.github/dependabot.yml`

```yaml
version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
    # One PR for all action bumps, so a SHA-pin refresh is one review.
    groups:
      actions:
        patterns: ["*"]
```

Dependabot understands the `# vX.Y.Z` comment after a SHA and keeps it
updated. No npm/pip ecosystems: tool pins live in `kits/*/spec.yaml` and
`ci.yml`'s `npm install` line, which Dependabot cannot see — leave those to
`docs/toolchain.md`'s manual process.

Lint: yamllint runs over every tracked `*.yml` — `git add` first.

### 1c. `CHANGELOG.md`

Under `## [Unreleased]` → `### Added`: one line for `SECURITY.md`, one for
Dependabot. (Scorecard goes in Stage 3's entry.)

### 1d. Verify + hand over

`git add SECURITY.md .github/dependabot.yml CHANGELOG.md .cspell.json`, then
`make lint`, then `git diff --cached` to review. Draft commit message, stop.

## Stage 2 — repo settings (user does these in the GitHub UI, ~5 min)

The sandbox PAT got 403 on branch protection, so these cannot be done from
here. Give the user exact clicks:

1. **Private Vulnerability Reporting**: Settings → Code security → "Private
   vulnerability reporting" → Enable. (Makes the `SECURITY.md` link live.)
2. **Dependabot security updates**: same page → Enable. (Alerts are separate
   from the version-update file in 1b; both are wanted.)
3. **CodeQL default setup**: same page → Code scanning → "Set up" → Default.
   Repo is Shell + YAML + a little TS, so CodeQL coverage is thin, but the
   Scorecard `SAST` check credits it and it costs nothing.
4. **Branch protection on `main`** (or a ruleset): require PR before merge,
   block force-push, require status checks. The three CI jobs each run a
   two-OS matrix, so GitHub exposes **six** checks, labelled per matrix leg
   (e.g. `lint (ubuntu-latest)`, `lint (macos-latest)`, and likewise for
   `test` and `validate`). Copy the exact labels from a completed CI run in
   the ruleset UI's picker — do not type them from memory — and require all
   six. Scorecard's `Branch-Protection` check reads this.

Nothing to lint or commit. This stage can happen any time after Stage 1; only
Stage 3 depends on it (for a good score, not for the workflow to run).

## Stage 3 — OpenSSF Scorecard workflow (~20 min)

### 3a. `.github/workflows/scorecard.yml`

Follow the upstream template (`ossf/scorecard-action` README), adapted to
this repo's conventions:

- Triggers: `branch_protection_rule`, weekly `schedule`, `push` to `main`.
- **Permissions — deliberate deviation from upstream, documented in a workflow
  comment.** Upstream's template sets top-level `permissions: read-all`. This
  repo's convention is top-level `contents: read`, and since the single job
  carries its own `permissions:` map the top-level value only matters as a
  default for jobs without one — so keep `contents: read` at the top. The
  job-level map must be complete, because a job-level map resets every
  unlisted scope to `none` (checkout would otherwise have no guaranteed
  content access):

  ```yaml
  permissions:
    contents: read          # checkout
    actions: read           # Scorecard reads workflow runs
    security-events: write  # upload SARIF to code scanning
    id-token: write         # publish_results signs the result for the badge
  ```

  Upstream comments `contents`/`actions` out for public repos; list them
  anyway so the map is explicit. If the first run's Scorecard log shows a
  permission error, add the scope it names and record the tested result in
  the workflow comment — do not fall back to `read-all`.
- Steps: `actions/checkout` (same SHA as `ci.yml`, `persist-credentials:
  false`), `ossf/scorecard-action` with `results_file: results.sarif`,
  `results_format: sarif`, `publish_results: true`; then
  `github/codeql-action/upload-sarif`.
- **Resolve SHAs at execution time**, not from memory:
  `gh api repos/ossf/scorecard-action/git/ref/tags/<latest>` and
  `gh api repos/github/codeql-action/git/ref/tags/<latest>` (annotated tags
  need one more hop to the commit). Write `# vX.Y.Z` trailers like `ci.yml`.

### 3b. README badge

Add next to the existing CI badge (`README.md` top):
`[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/lars20070/sbxagent/badge)](https://scorecard.dev/viewer/?uri=github.com/lars20070/sbxagent)`

### 3c. `.cspell.json`

Add `ossf`, `scorecard`, `sarif` (whatever `make lint` flags).

### 3d. `CHANGELOG.md`

`### Added` line for the Scorecard workflow + badge.

### 3e. Verify + hand over

`git add .github/workflows/scorecard.yml README.md CHANGELOG.md .cspell.json`,
then `make lint`, then `git diff --cached`. Draft commit message, stop. After
the user pushes: the workflow runs on push to `main`; check the score at the
viewer URL and read the per-check findings.

## Stage 4 — react to the first Scorecard run (later, size unknown)

Not planned in detail; depends on the score. Likely findings and the cheap
answers:

- `Pinned-Dependencies`: will flag `curl | sh` in `ci.yml`/`release.yml` sbx
  installs and the `npm install --global x@ver` lines. Accept for `ci.yml`
  (tracking `latest` is deliberate — comment says so); `release.yml` already
  pins a version. `--ignore-scripts` on the npm installs is **an experiment,
  not a default**: `esbuild@0.28.2` declares `postinstall: node install.js`,
  so the flag may leave CI's `esbuild` unusable. Only try it on a branch with
  a fresh npm cache (bump the cache key) and both OS legs green.
- `Token-Permissions`: should already pass.
- `Signed-Releases`: kits are signed in GHCR, but the GitHub Release has no
  signed asset. Optional: attach `git archive` tarball + attest it with
  `actions/attest-build-provenance` in the `github-release` job. Only if the
  score matters enough.
- `Security-Policy`, `Vulnerabilities`, `Dependency-Update-Tool`: fixed by
  Stages 1–2.

## Stage 5 — signed release tags (separate follow-up, not part of this change)

Scoped out of Stages 1–4 so that `SECURITY.md` stays truthful on day one.
When picked up:

- Sign tags with SSH (`git config tag.gpgsign true`, `gpg.format ssh`,
  `user.signingkey <pubkey>`), create them annotated (`git tag -s vX.Y.Z`),
  and publish the verifying public key in `docs/published-kits.md` or
  `SECURITY.md` so users can run `git tag -v`.
- Have `release.yml` verify the tag signature before publishing (a
  `git verify-tag` step with the allowed-signers file checked in), so a tag
  pushed by a compromised account without the key cannot release.
- Note in `AGENTS.md`'s release checklist that tags are annotated and signed.
- Then, and only then, add "release tags are signed" to `SECURITY.md`.

## Verification (whole plan)

- After Stage 1 and 3: new files `git add`-ed, `make lint` green locally; CI
  green on the PR (lint, test, validate — six matrix checks).
- After Stage 2: `gh api repos/lars20070/sbxagent/private-vulnerability-reporting`
  → `enabled: true`; the "Report a vulnerability" button appears on the
  Security tab.
- After Stage 3 push: Actions tab shows a green Scorecard run with the
  narrowed permissions; badge renders a number; SARIF shows under Security →
  Code scanning. If the run fails on permissions, the log names the scope —
  add it, note it, re-run.
- After Dependabot's first weekly run: verify a single grouped PR appears for
  the actions group (whatever its title) and that merging it keeps the
  `# vX.Y.Z` comments in step with the SHAs.

## Files touched

- New: `SECURITY.md`, `.github/dependabot.yml`, `.github/workflows/scorecard.yml`
- Edited: `README.md` (badge), `CHANGELOG.md`, `.cspell.json`
- Not touched: `ci.yml`, `release.yml`, `kits/**`, `scripts/**`
  (Stage 5 would touch `release.yml` and `AGENTS.md`, later)
