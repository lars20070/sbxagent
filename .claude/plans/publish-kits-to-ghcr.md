# Publish the four kits to `ghcr.io` on every release

## Context

Today a kit only exists as a directory in this repo. `scripts/sbxagent` passes
`kits/<name>/` to `sbx run --kit`, so using these kits means cloning the repo
and symlinking the wrapper — the entire install story in `README.md`. Nothing is
published anywhere, and `AGENTS.md` says so outright:

> Pushing the tag and publishing the kit itself are separate steps this repo
> does not yet define; confirm before pushing a tag anywhere.

This defines them. Cutting `vX.Y.Z` publishes all four kits as OCI artifacts to
GHCR, so `sbx run --kit ghcr.io/lars20070/sbxclaude:0.4.0 claude` works on a
machine that has never seen this repository.

## Decisions (confirmed with the user)

| # | Question | Decision |
|---|---|---|
| 1 | Package names | Flat: `ghcr.io/lars20070/<kit>`. The package name is the kit name, the directory name and the command. No `-kit` suffix — upstream needs one only because it also publishes `<kit>-image`; this repo publishes no images. |
| 2 | Tags | `<version>` (immutable) plus `latest`, re-pointed at the **same digest**. Publishing only happens on releases, so `latest` means "newest release". |
| 3 | Visibility | Public, via a one-time manual flip per package after the first release. GHCR creates every new package private. |
| 4 | Wrapper | Unchanged. `scripts/sbxagent` and `tests/sbxagent_test.sh` keep using the local `kits/<name>/`. |
| 5 | Consumer docs | **A short README section** — reversing the earlier "no consumption guide" call. Publishing artifacts with no documented way to load them is a poor result. |
| 6 | Signing | **A separate step after the push**, not `--sign` on the push. See "The signing trap" below — this is the one design change neither source plan had. |
| 7 | Probe | One throwaway package (`ghcr.io/lars20070/sbxprobe`), one kit (`sbxpi`), deleted afterwards. The four real packages are never used as a test target. |

## The signing trap (why decision 6 exists)

Upstream's `PUBLISHING.md` documents, verbatim:

> `--sign` needs its own `sbx login`, separate from the `docker login` the job
> already does for the plain push. Attaching a signature is an OCI-referrer
> write that resolves credentials from sbx's own session rather than the Docker
> credential store, so without it `--sign` fails with "user is not authenticated
> to Docker" — **after the unsigned manifest has already been pushed**, since
> the push itself doesn't need this login.

Two consequences this plan is built around:

1. **There is no `sbx login` for GHCR.** `sbx login --help` is "Sign in to
   Docker" with only `--username` / `--password-stdin` — no registry operand.
   `sbx secret set --registry ghcr.io` exists but its help scopes it to *pull*
   credentials. So upstream's fix has no GHCR equivalent, and whether a keyless
   signature can be attached to a GHCR referrer with only `docker login` is
   **open**.
2. **`--sign` plus skip-if-tag-exists is a silent-failure machine.** If signing
   fails after the push lands, the re-run sees the tag, skips, reports "reused",
   and the kit stays unsigned forever.

So: push unsigned, then sign as its own step. `sbx kit sign REFERENCE` is
documented to attach a signature to an already-pushed OCI reference, and its own
help example is `ghcr.io/org/my-kit:1.0`. Push and sign then fail and retry
independently, and a signing failure is fixable in place with no version bump.

## Verified facts

**Verified locally against `sbx v0.39.0`:**

- `sbx kit push DIRECTORY REFERENCE`, flags `--sign`, `--key`,
  `--identity-token`, `--identity-token-file`, `--tlog-upload`.
- **`kit push` is daemon-free.** `sbx kit push kits/sbxpi "not a valid ref"`
  loads and packs the kit, then fails only at `connect to registry ... invalid
  reference`. No `sandboxd`, no Docker daemon — CI needs just the `sbx` binary,
  the same install `ci.yml`'s `validate` job already does.
- Push auth is the Docker credential store, so `docker/login-action` covers the
  push. (Signing is a *different* credential path — see above.)
- `sbx kit sign REFERENCE` attaches to an OCI referrer; keyless in CI, "the
  token is minted automatically by the detected platform (GitHub Actions, …)",
  so `id-token: write` and no secret.
- `kit.allowedSources` is a real setting: *"JSON array of allowed kit source
  prefixes (e.g. `["docker.io/", "ghcr.io/docker/"]`). Use `["*"]` to allow any
  remote source."* Its **default value is open** — the docker.io-only claim
  comes from the research docs, not from the binary.
- **`.DS_Store` hazard is real.** `kit push` packs the directory as-is and
  ignores `.gitignore`. Four `.DS_Store` files sit under `kits/` right now
  (`kits/.DS_Store`, `kits/sbxclaude/.DS_Store`,
  `kits/sbxclaude/files/.DS_Store`, `kits/sbxpi/.DS_Store`). Anything published
  must come from a tracked-files-only staging copy.
- All four specs are `schemaVersion: "2"`, `kind: sandbox`, `version: "0.3.0"`.

**Verified against upstream `docker/sbx-kits-contrib` `PUBLISHING.md`:**

- The digest-divergence claim is upstream's own: *"`oras.PackManifest` stamps
  `org.opencontainers.image.created`, so re-pushing the same tree yields a
  different manifest digest even though the layer is byte-stable … That
  annotation has one-second resolution, so two pushes within the same second do
  match: the divergence is intermittent, which is worse than reliable."* Hence
  one push and `oras tag`, never a second push for `latest`.
- *"`oras tag` needs **pull as well as push** on the repository — it fetches the
  manifest before re-PUTting it under the new tag."* `GITHUB_TOKEN` with
  `packages: write` also grants read, so this is fine here; it is the failure
  mode to look for if the token is ever narrowed.
- Upstream discovers kits rather than listing them, and runs one job per kit so
  they "publish in parallel and fail independently".
- `oras-project/setup-oras` exists and is maintained (v2.0.1, not archived).

**Deliberate divergences from upstream:** they tag per kit
(`<kit>/vX.Y.Z`) and keep `latest` tracking `main`; we have one repo-wide
version, so one tag publishes all four and `latest` tracks the newest release.
They treat a colliding tag as fatal; we skip and reuse, because one tag
publishing four kits must be re-runnable.

## Stage 1 — the scripts

### `scripts/publish-kit.sh` (new) — one kit, one release

All logic here rather than in workflow YAML, so `make lint` shellchecks it and a
rehearsal runs locally. Note `.shellcheckrc` is `enable=all` with only
SC2310/SC2311/SC2312 disabled, so `[[ ]]` over `[ ]` (SC2292), braced-and-quoted
variables (SC2248) and a default `*)` in every `case` (SC2249) are enforced.
AGENTS.md portability still applies: bash 3.2 floor, no `readlink -f`, no
`mapfile`, no `declare -A`, no GNU-only flags.

```text
usage: scripts/publish-kit.sh <kit> <version>          # e.g. sbxpi 0.4.0
env:   REGISTRY=ghcr.io  NAMESPACE=lars20070  LATEST_TAG=latest
       SIGN=1  DRY_RUN=  REPO_NAME=          # REPO_NAME overrides the package
                                             # name — probe use only
```

Order of operations:

1. Resolve the repo root from `$0` (not symlinked, so plain `dirname` — no need
   for the 40-hop `resolve_dir` walk `scripts/sbxagent` needs).
2. Refuse unless `kits/<kit>/spec.yaml` exists.
3. **Compose the reference from the directory name**, `${REGISTRY}/${NAMESPACE}/${REPO_NAME:-<kit>}`
   — never from an argument or from the spec. `sbx kit push` uses the reference
   verbatim: it derives nothing and validates nothing against the kit, so a
   wrong value pushes a kit manifest over an unrelated tag.
4. **Clean-tree gate**, enforced only when actually publishing: refuse if
   `git status --porcelain -- "kits/<kit>" VERSION` is non-empty. Published
   bytes must be committed bytes. In `DRY_RUN` a dirty tree only warns, and the
   warning says staging reads `HEAD`, so uncommitted edits are *not* what would
   ship.
5. **Stage.** `git archive HEAD -- "kits/<kit>" | tar -x -C "$stage"` into a
   `mktemp -d` with a `trap … EXIT`. Everything downstream uses
   `$stage/kits/<kit>`. This is the `.DS_Store` fix, and it matches the
   `git ls-files` philosophy the `Makefile` already uses everywhere.
6. `sbx kit validate` **and** `sbx kit inspect` the staged copy — both **before**
   the dry-run exit, so a dry run catches a broken kit and the log shows exactly
   what would ship.
7. Assert the staged spec's `version:` equals `<version>`. Cheap, and catches a
   stale spec that `make lint` would have caught only repo-wide.
8. `DRY_RUN` → print the plan (ref, both tags, sign yes/no) and exit 0. No
   network, no credentials.
9. **Probe the version tag with `oras manifest fetch --descriptor`**, not
   `docker manifest inspect`: a kit is an OCI manifest with a custom
   `artifactType` and a non-image config, which image-oriented tooling may
   reject — and a rejection is indistinguishable from "absent", which would wave
   through the overwrite the probe exists to prevent. Match
   `not found|manifest unknown|name unknown|404` for absent; **anything else is
   a hard failure**, not an assumed absence.
   - Absent → push. Present → skip the push, reuse the digest, and say so
     loudly in the step summary.
10. `sbx kit push "$stage/kits/<kit>" "<ref>:<version>"` — **no `--sign`**.
11. Read the digest back with `oras manifest fetch --descriptor`. Fail if empty
    or `null`, written as an `if`, not `[[ -n … ]] && …` (under `set -e` a
    failing first test of an `&&` list falls through).
12. **Re-point `latest` by digest:** `oras tag "<ref>@<digest>" "${LATEST_TAG}"`.
    Addressing the digest also stops a racing push from swapping what `latest`
    names.
13. **Sign, as its own step, always run** (even on the reuse path — that is the
    point of separating it): `sbx kit sign "<ref>@<digest>"` when `SIGN` is set.
    Sign by digest so it is unambiguous. If signing fails, the step fails loudly
    but the artifact is already correctly published; a re-run signs in place.
14. Emit `ref=`, `digest=`, `pushed=`, `reused=`, `signed=` **on fd 3**, with
    `exec 3>&1 1>&2` at the top, so `sbx kit validate`'s `VALID: …`, `inspect`'s
    output and `oras`'s chatter cannot land in `$GITHUB_OUTPUT` and fail the
    step with "Invalid format". Append a human summary to
    `$GITHUB_STEP_SUMMARY` when set. The workflow calls it as
    `./scripts/publish-kit.sh … 3>>"$GITHUB_OUTPUT"`.

Two things to settle during the probe (Stage 4), noted in the script as
comments: whether `sbx kit sign` accepts a `@sha256:` reference (fall back to
the tag if not), and whether re-signing an already-signed kit attaches a
duplicate referrer (if it does, gate step 13 behind a `sbx kit verify` check).

### `scripts/check-release-tag.sh` (new)

Takes a tag name, asserts `^v[0-9]+\.[0-9]+\.[0-9]+$`, asserts the version
matches `VERSION`, emits `version=` on fd 3. It does **not** re-check the specs
or the changelog — `make lint` already fails when `VERSION`, any
`kits/*/spec.yaml` `version:` or `CHANGELOG.md`'s latest release heading
disagree, and the `verify` job runs `make lint`.

**Only the tag-triggered path calls it.** On `workflow_dispatch`,
`GITHUB_REF_NAME` is a branch, so running it there would fail the shape check; a
dispatch takes its version from `VERSION`.

### `Makefile`

```make
publish-dry-run:
	for kit in kits/*/; do \
		DRY_RUN=1 ./scripts/publish-kit.sh "$$(basename "$${kit%/}")" \
			"$$(cat VERSION)"; \
	done
```

Add to `.PHONY`. No network, no Docker, no login. Do **not** add a `publish`
target that pushes — a foot-gun next to `make lint` is how accidental releases
happen.

## Stage 2 — `.github/workflows/release.yml`

```yaml
on:
  push:
    tags: ["v[0-9]+.[0-9]+.[0-9]+"]
  workflow_dispatch:
    inputs:
      dry_run:    {type: boolean, default: true}
      sign:       {type: boolean, default: true}
      probe_repo: {type: string,  default: ""}   # publish under this package name
      probe_kit:  {type: string,  default: ""}   # publish only this one kit
```

Top-level `permissions: contents: read`, matching `ci.yml`. Two jobs.

**`verify`** — `ubuntu-latest`. Checkout; on a tag push only
(`if: github.event_name == 'push'`) run `scripts/check-release-tag.sh
"${GITHUB_REF_NAME}"`; then `make lint`.

`make lint` here is the whole point: a tag whose `VERSION`, specs and changelog
disagree must not publish. **It needs its tools installed first** — a bare
`ubuntu-latest` has no `markdownlint-cli2`, `cspell` or `esbuild`, so copy the
npm-cache and pinned-install steps from `ci.yml`'s lint job and pass
`ESBUILD=esbuild` (skip its `brew` step; that leg is macOS-only). `shellcheck`,
`jq` and `yamllint` are already present.

Outputs `version` (from the tag on a push, from `VERSION` on a dispatch) and
`kits`. **`kits` is discovered, not hardcoded**, so a fifth kit needs no
workflow edit — matching `make lint`, `make validate` and `make publish-dry-run`,
which all iterate `kits/*/`. When `probe_kit` is set it collapses to that one
kit.

```yaml
- id: kits
  run: |
    set -euo pipefail
    if [ -n "${{ inputs.probe_kit }}" ]; then
      printf 'kits=["%s"]\n' "${{ inputs.probe_kit }}" >> "$GITHUB_OUTPUT"
    else
      for d in kits/*/; do basename "${d}"; done |
        jq -R . | jq -sc . | sed 's/^/kits=/' >> "$GITHUB_OUTPUT"
    fi
```

**`publish`** — `needs: verify`, `ubuntu-latest`,
`strategy: {fail-fast: false, matrix: {kit: ${{ fromJSON(needs.verify.outputs.kits) }}}}`,
job-level `permissions: {contents: read, packages: write, id-token: write}`.
`fail-fast: false` so one kit's failure does not cancel the others mid-release;
the skip-and-reuse in Stage 1 step 9 makes the re-run clean.

Steps: checkout (`persist-credentials: false`, as everywhere in `ci.yml` —
`git archive HEAD` needs the repo, not the token) → install sbx (copy the Linux
leg of `ci.yml`'s `validate` job verbatim, including its `releases/latest`
download and the comment saying why latest is intentional) → `setup-oras`
(SHA-pinned, v2.0.1) → `docker/login-action` (SHA-pinned; `registry: ghcr.io`,
`username: ${{ github.actor }}`, `password: ${{ secrets.GITHUB_TOKEN }}`) → the
publish step:

```yaml
- name: Publish
  run: ./scripts/publish-kit.sh "${{ matrix.kit }}" "${{ needs.verify.outputs.version }}" 3>>"$GITHUB_OUTPUT"
  env:
    # A tag push always publishes; a dispatch only when dry_run is cleared.
    DRY_RUN: ${{ github.event_name == 'workflow_dispatch' && inputs.dry_run && '1' || '' }}
    SIGN: ${{ (github.event_name != 'workflow_dispatch' || inputs.sign) && '1' || '' }}
    REPO_NAME: ${{ inputs.probe_repo }}
```

`setup-oras` and `docker/login-action` take `if: env.DRY_RUN == ''`, so a dry
run needs no credentials at all. Every third-party action gets a SHA pin with a
`# vX.Y.Z` comment, as `ci.yml` already does.

## Stage 3 — docs

- **`README.md`** — a short "Using a published kit" section. Not an install
  rewrite: the allowlist line, one run example, and the verify command. State
  the allowlist step conditionally ("if the run fails with a kit-source error"),
  because the *default* of `kit.allowedSources` is unverified — the setting
  itself is confirmed.

  ```bash
  sbx settings set kit.allowedSources '["docker.io/","ghcr.io/lars20070/"]'
  sbx run --kit ghcr.io/lars20070/sbxclaude:0.4.0 claude
  sbx kit verify ghcr.io/lars20070/sbxclaude:0.4.0 \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    --certificate-identity-regexp '^https://github.com/lars20070/sbxagent/'
  ```

  Say the four packages map 1:1 to the four commands, and that pinning by digest
  beats `latest`.
- **`AGENTS.md`** — replace the "does not yet define" sentence: pushing `vX.Y.Z`
  triggers `release.yml`, which publishes all four kits to
  `ghcr.io/lars20070/<kit>:X.Y.Z` and re-points `latest` at the same digest.
  Keep "confirm before pushing a tag anywhere" — it matters more now. Record the
  **load-bearing invariant**: `latest` means "newest release" *only* because
  nothing publishes from `main`; adding a main-branch publish silently changes
  what `latest` means.
- **`CHANGELOG.md`** — an `### Added` entry under `## [Unreleased]` naming the
  four references, the two tags, and the provenance/signature story. Say the
  packages are **public after a one-time GHCR visibility flip** — claiming
  "public" outright is wrong until someone has clicked through it.
- **`.cspell.json`** — add only what `make lint` flags; likely `ghcr`, `oras`,
  `sigstore`, `keyless`, `SLSA`, `Rekor`, `Fulcio`, `cosign`, `artifactType`.

## Stage 4 — the probe (blocks Stage 5)

The first real tag is **blocked** until this passes. It is what settles whether
signing works against GHCR with only `docker login`.

The probe publishes under whatever `VERSION` (and the matching
`kits/*/spec.yaml` `version:`) currently say — today `0.3.0`. It does **not**
use `0.4.0`: that version is cut in Stage 5, and `publish-kit.sh` refuses a
version that disagrees with the staged spec. The package name is what makes
this a throwaway (`sbxprobe`), not a special version string.

1. `make lint`, `make validate`, `make test-unit`, `make publish-dry-run` — all
   green locally. Confirm the staged copy contains no `.DS_Store`.
2. Dispatch with `dry_run: true` — proves the sbx install, the version guard,
   `make lint` on a runner, and the matrix all work.
3. Dispatch with `dry_run: false`, `probe_repo: sbxprobe`, `probe_kit: sbxpi` —
   publishes `ghcr.io/lars20070/sbxprobe:<VERSION>` plus `latest`. `sbxpi`
   because it has no parent kit and is the most likely to break.
4. Check, on the probe package: both tags resolve to one digest
   (`oras manifest fetch --descriptor …:latest`); `sbx kit inspect` reports
   `sbxpi`; `sbx kit provenance` returns an attestation; `sbx kit verify`
   succeeds. Answer the two open script questions (digest refs for `sbx kit
   sign`; duplicate referrers on re-sign) by re-running the dispatch.
5. If signing failed: record it, set `sign: false` for the release, and open the
   fallback — `sbx kit sign` run manually against the published ref.
6. **Delete the `sbxprobe` package.**

## Stage 5 — first release

**The first published release is `0.4.0`, not `0.3.0`.** `VERSION`, the specs
and `## [0.3.0] - 2026-09-04` already agree and `v0.3.0` was never tagged, but
`## [Unreleased]` now holds five `Added` entries of post-0.3.0 `sbxpi` work
(four OpenRouter models plus Ollama). Tagging the tip `v0.3.0` would publish
unreleased features under an already-cut version.

1. Cut `0.4.0` per `AGENTS.md`: move the `Unreleased` entries under
   `## [0.4.0] - <date>`, set `VERSION` and all four `kits/*/spec.yaml`
   `version:` to `0.4.0`, restore an empty `## [Unreleased]`.
2. `git tag v0.4.0 && git push origin v0.4.0` — deliberately, and confirmed.
3. **Flip all four packages to Public** (profile → Packages → each → Package
   settings → Danger Zone). Until then a consumer gets a **404**, not
   "unauthorized" — which reads like a publishing bug and is not one.
4. Confirm each package linked to the repo via
   `org.opencontainers.image.source`; link by hand if not.

## Files touched

| File | Change |
|---|---|
| `scripts/publish-kit.sh` | new — stage, validate, probe, push, retag, sign |
| `scripts/check-release-tag.sh` | new — tag shape + `VERSION` agreement |
| `.github/workflows/release.yml` | new — `verify` + matrixed `publish` |
| `Makefile` | add `publish-dry-run`, extend `.PHONY` |
| `README.md` | new "Using a published kit" section |
| `AGENTS.md` | replace the "does not yet define" sentence; record the `latest` invariant |
| `CHANGELOG.md` | `### Added` under `## [Unreleased]` |
| `.cspell.json` | new words |

Unchanged on purpose: `scripts/sbxagent`, `tests/sbxagent_test.sh`,
`tests/toolchain_test.sh`, `.github/workflows/ci.yml`, and all four
`spec.yaml` files until the Stage 5 version bump.

## Verification

`make lint` covers both new scripts (`shellcheck --enable=all` + `.shellcheckrc`,
`bash -n`) and the new workflow (`yamllint`) with no new target. `make validate`
and `make test-unit` must stay green — they prove the wrapper is untouched.
`make publish-dry-run` is the real test of Stage 1: four validated kits, four
`inspect` blocks, four printed plans, nothing published, no network.

End to end after Stage 5, from a directory that is not this repo, for **both kit
shapes** — `sbxpi` (no parent kit) and one `extends:` kit:

```bash
sbx kit inspect    ghcr.io/lars20070/sbxpi:0.4.0     # reports sbxpi 0.4.0
sbx kit provenance ghcr.io/lars20070/sbxpi:0.4.0
sbx kit verify     ghcr.io/lars20070/sbxpi:0.4.0 \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github.com/lars20070/sbxagent/'
sbx run --kit ghcr.io/lars20070/sbxpi:0.4.0 pi
sbx run --kit ghcr.io/lars20070/sbxclaude:0.4.0 claude
oras manifest fetch --descriptor ghcr.io/lars20070/sbxpi:latest   # same digest
```

If a run fails with a kit-source allowlist error rather than a registry error,
that is the consumer-side trust setting, not a publishing bug — see the README
section.

## Risks

1. **Signing against GHCR is unproven.** Upstream needed a real Hub credential
   via `sbx login`, which has no GHCR equivalent. Mitigated three ways: signing
   is its own step so a failure never leaves a half-published artifact; Stage 4
   probes it before any real tag; `SIGN=` ships a release unsigned rather than
   blocking, and `sbx kit sign <ref>` fixes it in place afterwards.
2. **Signature and provenance are OCI referrers.** GHCR supports the referrers
   API; if it falls back to the tag scheme the artifacts still publish and only
   `sbx kit verify` needs checking. Caught by Stage 4, does not block a release.
3. **`sbx kit` is EXPERIMENTAL** and the job installs the *latest* sbx, matching
   `ci.yml`'s deliberate choice. A CLI change could break a release rather than
   a PR. Pinning would trade that for silently publishing in a stale format;
   not worth it while `schemaVersion: "2"` is stable.
4. **Reuse-on-collision means re-cutting a published version publishes nothing.**
   Deliberate, and the reason the step summary must shout. Signing is exempt —
   it runs on the reuse path too.
5. **`oras tag` reads before it writes.** Fine with `packages: write`, but it is
   the failure mode to look for if the token is ever narrowed — it fails *after*
   the immutable tag is published.
6. **`git tag` discipline is currently loose** — `v0.2.0` exists and points at a
   PR merge commit. From here a tag push has side effects, so `verify` failing
   loudly on a mismatched tag is load-bearing, not decorative.
7. **`kit.allowedSources`' default is unverified.** Costs nothing: it is one
   line on the consumer's host, cannot be fixed from the publishing side, and
   the README states it conditionally.

## Not doing

- Not touching `scripts/sbxagent` or `tests/sbxagent_test.sh` (decision 4).
  `sbx kit validate` does not accept OCI references anyway, so `make validate`
  needs the local tree regardless.
- **No unit test for `publish-kit.sh`.** The fake-CLI harness in
  `tests/sbxagent_test.sh` would extend to it, but the script's risky behaviour
  is all in how it reacts to a *real* registry (tag present, absent, or
  unreadable), which a fake `oras` would only re-assert. `shellcheck
  --enable=all` plus a mandatory `make publish-dry-run` and the Stage 4 probe is
  the bar. Revisit if it grows branches that are not about registry state.
- No publishing from `main`, no dated or rolling tags beyond `latest` — that is
  what makes `latest` mean "newest release".
- No container images and no `Dockerfile`: three kits inherit their image via
  `extends:`, and `sbxpi` uses `docker/sandbox-templates:shell-docker`
  deliberately as a moving tag.
- Not automating the GHCR visibility flip — it needs a PAT with package scope
  and is one-time per package.
- Docker Hub as a second registry. Revisit only if the allowlist default turns
  out to block GHCR consumers by default.
