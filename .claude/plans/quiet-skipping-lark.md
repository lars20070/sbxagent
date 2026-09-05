# Create the GitHub Release automatically on a version tag

## Context

`.github/workflows/release.yml` already publishes all four kits to GHCR on a
`vX.Y.Z` tag push, and as of `v0.4.0` that path is green end to end. What it
does **not** do is create a **GitHub Release**.

A git tag and a GitHub Release are different objects: a Release is built on top
of a tag and never appears on its own. So the repo currently has three tags and
an empty Releases page, which reads worse than no page at all — a visitor asking
"what changed in 0.4.0?" gets nothing, even though `CHANGELOG.md` answers it in
detail.

This closes that gap. Tagging `vX.Y.Z` should publish the kits **and** create the
Release, with the notes taken from the changelog entry that already exists.

## Decisions (confirmed with the user)

| # | Question | Decision |
|---|---|---|
| 1 | Scope | GitHub Release creation only. Bumping `VERSION`, the four specs and the `CHANGELOG.md` heading stays manual, as `AGENTS.md` describes — `make lint` already fails loudly when the six disagree, so a bad bump cannot reach a tag. |
| 2 | Notes source | The `## [X.Y.Z]` section of `CHANGELOG.md`. One source of truth, matching how `make lint` enforces version agreement everywhere else. |
| 3 | Backfill | No. `v0.2.0`, `v0.3.0` and `v0.4.0` stay tags only; the Releases page starts at the next tag. |

## Design

### `scripts/release-notes.sh` (new)

A pure function — version in, notes out — so it is trivially testable locally and
`make lint` covers it with `shellcheck --enable=all` and `bash -n`, like
`publish-kit.sh` and `check-release-tag.sh` before it.

```text
usage: scripts/release-notes.sh VERSION      (for example: 0.4.1)
```

1. Refuse unless `CHANGELOG.md` exists and `VERSION` looks like `X.Y.Z`.
2. Extract the section with the same awk shape the repo already uses:
   `awk '/^## \[<version>\]/{f=1;next} /^## \[/{f=0} f'`. The version must be
   regex-escaped into the pattern (the dots), so build the pattern from the
   argument rather than interpolating it raw. The heading itself is skipped
   (`next`), so notes start at `### Added` — fine: the Release title is the
   tag, and GitHub already dates the Release.
3. **Fail if the section is missing or blank.** This is the valuable half: it
   catches a version tagged with nothing to describe — exactly the empty-`0.4.1`
   situation that came up and was reverted. Verified against the current file:
   `0.4.0` yields 46 non-blank lines, an absent version yields 0.
4. Print the section on stdout, everything else on stderr, so the caller can
   pipe it straight into `gh release create --notes-file -`.

Portability rules from `AGENTS.md` apply: bash 3.2 floor, no GNU-only flags.
`.shellcheckrc` is `enable=all`, so `[[ ]]` over `[ ]`, braced-and-quoted
variables, and a default `*)` in every `case` are enforced.

### Gate empty notes in `verify` (before publish)

`make lint` only checks that the latest `## [X.Y.Z]` heading exists and matches
`VERSION` — a heading with an empty body still passes. Call the same script in
`verify` after the version is resolved, so an empty section fails the run
**before** any kit is published:

```bash
./scripts/release-notes.sh "${VERSION}" >/dev/null
```

One source of truth for "non-empty notes"; the Release job still runs the
script for real notes. No change to `make lint` itself.

### A third job in `.github/workflows/release.yml`

```text
verify -> publish (matrix, one job per kit) -> github-release
```

- `needs: [verify, publish]`. Both are required: `publish` alone would hide
  `needs.verify.outputs.version` (Actions only exposes outputs from jobs listed
  in `needs`), and a matrix failure leaves `publish` failed so the Release job
  is skipped. Deliberate: never announce a release in which a kit did not
  publish.
- `if: github.event_name == 'push'`. A `workflow_dispatch` is a rehearsal or a
  probe and must never create a Release.
- Job-level `permissions: {contents: write}`, narrowing the top-level
  `contents: read` for this job only. This is the sole job that needs write.
- Version comes from `needs.verify.outputs.version`, which `verify` already
  computes — no second place to parse a tag.
- Explicit checkout (needed for `CHANGELOG.md` and the script).
  `persist-credentials: false` is fine: `gh` authenticates via `GH_TOKEN`,
  not the checkout credentials.
- `gh` is preinstalled on `ubuntu-latest`; it needs `GH_TOKEN` set to
  `secrets.GITHUB_TOKEN`.

**Re-runs must be safe**, matching the reuse-on-collision behaviour
`publish-kit.sh` already has: if the Release exists, skip it with a loud notice
rather than failing. `gh release create` errors on an existing release, and a
re-run after a partial failure is a normal thing to do here.

```bash
# Kits are already published by this point; a failure here leaves GHCR intact
# and only the Releases page missing. Say so before anything else.
echo "NOTICE: creating GitHub Release ${TAG} (kits already published)"

if gh release view "${TAG}" >/dev/null 2>&1; then
  echo "NOTICE: release ${TAG} already exists — not modifying it"
  exit 0
fi
./scripts/release-notes.sh "${VERSION}" |
  gh release create "${TAG}" --title "${TAG}" --verify-tag --notes-file -
```

`--verify-tag` refuses to invent a tag that does not exist, which turns a typo
into a failure instead of a stray tag.

## Files touched

| File | Change |
|---|---|
| `scripts/release-notes.sh` | new — extract one changelog section, fail if empty |
| `.github/workflows/release.yml` | call the script in `verify`; new `github-release` job after `publish` |
| `AGENTS.md` | one bullet under Releasing: a tag now also creates the Release, and an empty changelog section fails `verify` before publish |

Unchanged: `scripts/publish-kit.sh`, `scripts/check-release-tag.sh`,
`Makefile`, `ci.yml`, the kit specs, `VERSION`.

## Verification

Local, before anything is pushed:

```bash
./scripts/release-notes.sh 0.4.0     # prints the 46-line section
./scripts/release-notes.sh 9.9.9     # fails: no such section
./scripts/release-notes.sh 0.4.0 | head -3
make lint                            # shellcheck + bash -n on the new script,
                                     # yamllint + the workflow
make validate && make test-unit      # unchanged, prove nothing regressed
```

Also confirm the extractor stops at the next heading — the `0.4.0` output must
not contain `## [0.3.0]`, and must not contain the `## [0.4.0]` heading itself.

In CI, the job cannot be rehearsed by dispatch by design, so the first real
exercise is the next tag. Three things make that safe rather than a gamble:
empty notes fail in `verify` before publish; the Release job runs last, so a
failure there cannot affect the already-published kits; and the
existing-release check makes a re-run harmless.

End to end on the next release:

```bash
git tag v0.4.1 && git push origin v0.4.1
gh run watch
gh release view v0.4.1        # notes match the CHANGELOG section body
```

## Risks

1. **The Release job runs after publishing.** If it fails for a reason other
   than empty notes (auth, `gh` outage, race), the kits are already public and
   only the Release page is missing. That ordering is correct — the artifacts
   are the product, the Release is the announcement — but it means a red run
   does not imply a failed publish. The job's opening NOTICE says so.
2. **An empty changelog section fails `verify`.** Intended. `make lint` still
   cannot catch it locally (it only checks that the heading exists), so a
   tag push is the first automated check unless the script is run by hand.
   Mitigation remains procedural: `AGENTS.md` already says to cut the
   changelog entry in the same commit as the version bump; the local
   Verification commands above catch it before tagging.
3. **Notes are taken from the tagged commit's `CHANGELOG.md`**, not from the
   branch. Correct, and worth stating so nobody edits the changelog after
   tagging and expects the Release to change.

## Out of scope

- Backfilling `v0.2.0`, `v0.3.0`, `v0.4.0` (decision 3).
- Automating the version bump, `release-please`, or conventional commits
  (decision 1). The changelog prose here is hand-written and detailed; commit
  derived notes would be a downgrade.
- Attaching assets to the Release. The kits are OCI artifacts on GHCR; there is
  no tarball anyone should download from GitHub instead.
- Extending `make lint` to require a non-empty changelog body. The verify-job
  call is enough; a local lint check can wait until empty headings actually
  bite.
