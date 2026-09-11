# Plan: four cheap trust signals for `sbxagent`

## Context

A review (`trust-playbook-2026.md`) listed things a small OSS tool should do so
users can check it rather than trust it. Most of the list is already done here:
least-privilege CI, SHA-pinned Actions, GPG-signed tags, Sigstore-signed kits
gated on `sbx kit verify`, hash-checked binary downloads, an honest guard table
in the README. Four items are genuinely missing:

1. `SECURITY.md` — no disclosure policy.
2. Private Vulnerability Reporting — off (`gh api .../private-vulnerability-reporting` → `enabled: false`).
3. Dependabot for `github-actions` — none, so the SHA pins will silently go stale.
4. OpenSSF Scorecard — none.

Goal: add them in stages, each stage independently mergeable and green under
`make lint`, so the repo *signals* the hygiene it already practises.

Constraints from `AGENTS.md`: never commit or push; stage + hand over the
message. Every workflow must keep the existing pattern — top-level
`permissions: contents: read`, per-job elevation, `persist-credentials: false`,
every `uses:` pinned to a full SHA with a `# vX.Y.Z` trailer. New words go in
`.cspell.json`. User-facing changes go under `## [Unreleased]` in `CHANGELOG.md`.

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
    its *powers* do). Cite `docs/setup.md`.
  - Guard strength differs per agent; `sbxcursor` has no network-block guard.
    Link `docs/agents.md` rather than duplicating it.
- **Verifying what you run**: one-line pointer to the `sbx kit verify` command
  in `docs/published-kits.md:63`.

Lint: markdownlint + cspell run over every tracked `*.md`. Add any new words
(e.g. "advisories" is fine; check on first `make lint`).

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

Lint: yamllint runs over every tracked `*.yml`.

### 1c. `CHANGELOG.md`

Under `## [Unreleased]` → `### Added`: one line for `SECURITY.md`, one for
Dependabot. (Scorecard goes in Stage 3's entry.)

### 1d. Verify + hand over

`make lint`. Stage with `git add`, draft commit message, stop.

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
   require CI status checks (`lint`, `test`, `validate`), block force-push.
   Scorecard's `Branch-Protection` check reads this.

Nothing to lint or commit. This stage can happen any time after Stage 1; only
Stage 3 depends on it (for a good score, not for the workflow to run).

## Stage 3 — OpenSSF Scorecard workflow (~20 min)

### 3a. `.github/workflows/scorecard.yml`

Follow the upstream template (`ossf/scorecard-action` README), adapted to
this repo's conventions:

- Triggers: `branch_protection_rule`, weekly `schedule`, `push` to `main`.
- Top-level `permissions: read-all` is what upstream asks for; the job then
  elevates `security-events: write` (upload SARIF), `id-token: write`
  (`publish_results: true` signs the result so the badge can show it).
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

`make lint`. Stage, draft message, stop. After the user pushes: the workflow
runs on push to `main`; check the score at the viewer URL and read the
per-check findings.

## Stage 4 — react to the first Scorecard run (later, size unknown)

Not planned in detail; depends on the score. Likely findings and the cheap
answers:

- `Pinned-Dependencies`: will flag `curl | sh` in `ci.yml`/`release.yml` sbx
  installs and the `npm install --global x@ver` lines. Accept for `ci.yml`
  (tracking `latest` is deliberate — comment says so); `release.yml` already
  pins a version. Possibly add `--ignore-scripts` to the npm installs.
- `Token-Permissions`: should already pass.
- `Signed-Releases`: kits are signed in GHCR, but the GitHub Release has no
  signed asset. Optional: attach `git archive` tarball + attest it with
  `actions/attest-build-provenance` in the `github-release` job. Only if the
  score matters enough.
- `Security-Policy`, `Vulnerabilities`, `Dependency-Update-Tool`: fixed by
  Stages 1–2.

## Verification (whole plan)

- After Stage 1 and 3: `make lint` green locally; CI green on the PR (lint,
  test, validate on both OSes).
- After Stage 2: `gh api repos/lars20070/sbxagent/private-vulnerability-reporting`
  → `enabled: true`; the "Report a vulnerability" button appears on the
  Security tab.
- After Stage 3 push: Actions tab shows a green Scorecard run; badge renders a
  number; SARIF shows under Security → Code scanning.
- After Dependabot's first weekly run: a grouped PR titled like
  "Bump the actions group…" appears; merging it keeps the `# vX.Y.Z` comments
  in step with the SHAs.

## Files touched

- New: `SECURITY.md`, `.github/dependabot.yml`, `.github/workflows/scorecard.yml`
- Edited: `README.md` (badge), `CHANGELOG.md`, `.cspell.json`
- Not touched: `ci.yml`, `release.yml`, `kits/**`, `scripts/**`
