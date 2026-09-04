# Publish the four kits to `ghcr.io` on every release

> Revised after `publish-kits-plan-review.md`. Every blocker it raised is
> addressed below; where it asserts something I could not verify, the plan says
> so rather than adopting the claim.

## Context

Today a kit only exists as a directory in this repo. `scripts/sbxagent` passes
`kits/<name>/` to `sbx run --kit`, so using these kits means cloning the repo
and symlinking the wrapper — the entire install story in `README.md`. Nothing
is published anywhere.

`AGENTS.md` names this gap outright, in the release procedure:

> Pushing the tag and publishing the kit itself are separate steps this repo
> does not yet define; confirm before pushing a tag anywhere.

This change defines them. Cutting `vX.Y.Z` should publish all four kits as OCI
artifacts to GHCR, so that `sbx run --kit ghcr.io/lars20070/sbxclaude:0.4.0`
works on a machine that has never seen this repository.

The mechanics are already settled by upstream, and this plan follows them
rather than inventing anything:

- **`sbx kit push DIRECTORY REFERENCE`** pushes a kit directory straight to an
  OCI registry; its own help gives `ghcr.io/myorg/my-plugin:1.0` as the example
  reference. All four specs are `schemaVersion: "2"`, which selects the
  tar+gzip layer with the spec in the manifest config blob and standard OCI
  annotations — so the version and description are readable from the registry
  without pulling a layer. Every push also attaches a SLSA provenance referrer
  recording content digests, the declared sandbox image, and the source commit.
- **Push auth is the Docker credential store** (`sbx kit push --help`, v0.39.0),
  so `docker/login-action` against `ghcr.io` with the job's `GITHUB_TOKEN` is
  enough for the push itself. Signing is a separate question — see risk 1.
- **`--sign` is keyless** and "defaults to the ambient CI provider", i.e. the
  GitHub Actions OIDC token — so signing needs `id-token: write` and no secret.
- **[`docker/sbx-kits-contrib`](https://github.com/docker/sbx-kits-contrib)
  publishes its kits exactly this way**, and its `PUBLISHING.md`,
  `scripts/publish-artifact.sh` and `.github/workflows/publish-artifact.yml`
  are the reference this plan copies from, including three decisions whose
  reasons are not guessable from the CLI help. They are called out at the point
  of use below.

### Decisions taken (confirmed with the user)

| # | Question | Decision |
|---|---|---|
| 1 | Package names | Flat: `ghcr.io/lars20070/<kit>` — the package name is the kit name, the directory name, and the command. No `-kit` suffix; this repo publishes no images, so there is nothing to disambiguate from |
| 2 | Tags | `<version>` (immutable) plus `latest`, re-pointed at the same digest. Since publishing only happens on releases, `latest` means "newest release" |
| 3 | Visibility | Public — a one-time manual flip per package after the first release, because GHCR creates every new package private |
| 4 | Scope | Publish only. `scripts/sbxagent` keeps using the local `kits/<name>/`, and `README.md` gains no consumption guide |

## Changes

### 1. `scripts/publish-kit.sh` (new) — one kit, one tag

All logic lives here rather than in workflow YAML, so it is shellcheck-linted
by `make lint` and runnable locally as a dry run. Modelled on
`sbx-kits-contrib`'s `publish-artifact.sh`. Note `.shellcheckrc`: `enable=all`
with only SC2310/SC2311/SC2312 disabled, so `[[ ]]` over `[ ]` (SC2292), braced
and quoted variables (SC2248), and a default `*)` in every `case` (SC2249) are
enforced.

```text
usage: scripts/publish-kit.sh <kit> <version>       # e.g. sbxclaude 0.4.0
env:   REGISTRY=ghcr.io  NAMESPACE=lars20070  LATEST_TAG=latest
       SIGN=1            DRY_RUN=
```

Behaviour, in order:

1. **Compose the reference from the kit directory name** —
   `${REGISTRY}/${NAMESPACE}/${kit}` — never from an argument or from the spec.
   `sbx kit push` uses the reference it is handed verbatim: it derives nothing
   from the kit and validates nothing against it, so a wrong value pushes a kit
   manifest over an unrelated tag in the namespace.
2. Refuse unless `kits/<kit>/spec.yaml` exists, and run `sbx kit validate` on
   it — before the dry-run exit, so a dry run still catches a broken kit.
3. **Probe for the tag with `oras manifest fetch --descriptor`**, not
   `docker manifest inspect`: a kit is an OCI manifest with a custom
   `artifactType` and a non-image config, which image-oriented tooling may
   reject outright — and a rejection is indistinguishable from "absent", which
   would wave through the overwrite the probe exists to prevent. Distinguish
   "not found" (`not found|manifest unknown|name unknown|404`) from "could not
   tell"; the latter is a hard failure.
   - Tag absent → push.
   - Tag present → **skip the push, reuse the digest, and say so loudly** in
     the step summary. This diverges from upstream, which treats a colliding
     release tag as fatal: here one git tag publishes four kits, so a run that
     fails on the third kit must be re-runnable without re-cutting the version.
     Reuse never overwrites, so re-cutting a version with different content
     quietly publishes nothing — which is why the summary has to be loud.
4. `sbx kit push kits/<kit> <ref>:<version>`, with `--sign` when `SIGN` is set
   (the default). `SIGN=` turns signing off — see risk 1 for why that escape
   hatch exists rather than being a hardcoded `--sign`.
5. Read the digest back with `oras manifest fetch --descriptor` and fail if it
   is empty or `null` (an `if`, not `[[ -n "${d}" ]] && …` — under `set -e` a
   failing first test of an `&&` list falls through).
6. **Re-point `latest` with `oras tag "<ref>@<digest>" "${LATEST_TAG}"`, by
   digest.** Not a second `sbx kit push`: a second push re-packs the kit and
   `oras.PackManifest` stamps `org.opencontainers.image.created`, so the two
   tags would usually — but not always, the annotation has one-second
   resolution — carry different digests, each with its own signature and
   provenance. Addressing the digest also stops a racing push from swapping
   what `latest` ends up naming.
7. Emit `ref=`, `digest=`, `pushed=`, `reused=`, `signed=` on fd 3 for
   `$GITHUB_OUTPUT`, with `exec 3>&1 1>&2` so that `sbx kit validate`'s
   `VALID: …`, `sbx kit push`'s output and `oras tag`'s output cannot land in
   `$GITHUB_OUTPUT` and fail the step with "Invalid format". Append a human
   summary to `$GITHUB_STEP_SUMMARY` when set.

### 2. `scripts/check-release-tag.sh` (new) — the release is self-consistent

Takes a tag name, asserts `^v[0-9]+\.[0-9]+\.[0-9]+$`, and asserts the version
matches `VERSION`. It does not re-check the specs or the changelog: `make lint`
already fails when `VERSION`, any `kits/*/spec.yaml` `version:`, or
`CHANGELOG.md`'s latest release heading disagree, and the `verify` job runs
`make lint`. Emits `version=` for `$GITHUB_OUTPUT`.

**Only the tag-triggered path calls it.** On `workflow_dispatch`,
`GITHUB_REF_NAME` is a branch (`main`), not a tag, so running it there would
fail on the shape check — a dispatch takes its version from `VERSION` instead.

### 3. `.github/workflows/release.yml` (new)

```yaml
on:
  push:
    tags: ["v[0-9]+.[0-9]+.[0-9]+"]
  workflow_dispatch:
    inputs:
      dry_run:
        description: Validate and print the plan; publish nothing.
        type: boolean
        default: true
      sign:
        description: Attach a keyless Sigstore signature to each push.
        type: boolean
        default: true
```

`permissions: contents: read` at the top level, matching `ci.yml`. Two jobs:

- **`verify`** — `runs-on: ubuntu-latest`. Checkout; then, on a tag push only
  (`if: github.event_name == 'push'`), `scripts/check-release-tag.sh
  "${GITHUB_REF_NAME}"`; then the version-agreement lint. Outputs `version`
  (from the tag on a push, from `VERSION` on a dispatch) and `kits`.

  **`make lint` needs its tools installed first.** `ci.yml`'s lint job installs
  `markdownlint-cli2`, `cspell` and `esbuild` from pins and passes
  `ESBUILD=esbuild`; a bare `ubuntu-latest` has none of them, so copy that job's
  npm-cache and install steps (the `brew` step is macOS-only and not needed).
  `ubuntu-latest` already ships `shellcheck`, `jq` and `yamllint`.

  `make lint` here is the whole point: a tag whose `VERSION`, specs and
  changelog disagree must not publish.

  **`kits` is discovered, not hardcoded**, so a fifth kit needs no workflow
  edit — matching `make lint`, `make validate` and `make publish-dry-run`,
  which all iterate `kits/*/`:

  ```yaml
  - id: kits
    run: |
      set -euo pipefail
      for d in kits/*/; do basename "${d}"; done |
        jq -R . | jq -sc . | sed 's/^/kits=/' >> "$GITHUB_OUTPUT"
  ```

- **`publish`** — `needs: verify`, `runs-on: ubuntu-latest`,
  `strategy: {fail-fast: false, matrix: {kit: ${{ fromJSON(needs.verify.outputs.kits) }}}}`,
  and job-level `permissions: {contents: read, packages: write,
  id-token: write}` — `packages: write` to push to GHCR (it also grants the
  read that `oras tag` needs, see risk 5), `id-token: write` for keyless
  signing. Steps: checkout (`persist-credentials: false`, as everywhere in
  `ci.yml`) → install sbx (copy the Linux leg of `ci.yml`'s `validate` job
  verbatim, including its `releases/latest` download and the comment saying why
  latest is intentional) → `oras-project/setup-oras` pinned to a SHA →
  `docker/login-action` pinned to a SHA, `registry: ghcr.io`,
  `username: ${{ github.actor }}`, `password: ${{ secrets.GITHUB_TOKEN }}` →
  the publish step:

  ```yaml
  - name: Publish
    run: ./scripts/publish-kit.sh "${{ matrix.kit }}" "${{ needs.verify.outputs.version }}"
    env:
      # A tag push always publishes; a dispatch only when dry_run is cleared.
      DRY_RUN: ${{ github.event_name == 'workflow_dispatch' && inputs.dry_run && '1' || '' }}
      SIGN: ${{ (github.event_name != 'workflow_dispatch' || inputs.sign) && '1' || '' }}
  ```

  The login and setup-oras steps take the same `if: env.DRY_RUN == ''` guard, so
  a dry run needs no credentials at all.

`fail-fast: false` so one kit's failure does not cancel the other three
mid-publish; step 3 above makes the re-run clean.

Every third-party action gets a SHA pin with a `# vX.Y.Z` comment, as `ci.yml`
already does — `.coderabbit.yaml` reviews this path for least-privilege
`permissions:`, loud failures, and no secret echoing.

### 4. `Makefile` — a dry-run target

```make
publish-dry-run:
	for kit in kits/*/; do \
		DRY_RUN=1 ./scripts/publish-kit.sh "$$(basename "$${kit%/}")" \
			"$$(cat VERSION)"; \
	done
```

Add to `.PHONY`. No network, no Docker, no login — it validates each kit and
prints the plan, so the publish path is checkable without cutting a release.

### 5. `AGENTS.md` — replace the "does not yet define" sentence

The release procedure's last bullet becomes: pushing the `vX.Y.Z` tag triggers
`.github/workflows/release.yml`, which publishes all four kits to
`ghcr.io/lars20070/<kit>:X.Y.Z` and re-points `latest` at the same digest —
`latest` tracks the newest release here, unlike upstream where it tracks main.
Keep the existing "confirm before pushing a tag anywhere" instruction; it
matters more now that a tag push publishes.

### 6. `CHANGELOG.md` — an `### Added` entry under `## [Unreleased]`

Naming the four references, the two tags, and that artifacts are signed keyless
with a SLSA provenance referrer. Say the packages are **public after a one-time
GHCR visibility flip** — GHCR creates them private, so claiming "public"
outright is wrong until someone has clicked through it.

### 7. `.cspell.json`

Add only what `make lint` flags — likely `ghcr`, `oras`, `sigstore`, `keyless`,
`SLSA`, `Rekor`, `Fulcio`, `cosign`, `artifactType`.

## Verification

1. `make lint` — covers the new shell scripts (`shellcheck --enable=all` plus
   `.shellcheckrc`) and the new workflow (`yamllint`) automatically.
2. `make publish-dry-run` — four validated kits, four printed plans, nothing
   published, no network.
3. `make test-unit`, `make validate` — unchanged, but confirm nothing regressed
   (`tests/sbxagent_test.sh` pins the exact `sbx` argv the wrapper produces;
   this change does not touch the wrapper).
4. **Prove the publish path before tagging anything**, via
   `workflow_dispatch` with `dry_run: true`, then once more with
   `dry_run: false` against a throwaway version (e.g. `0.0.0-probe` — pass it
   by temporarily dispatching from a branch whose `VERSION` says so, and delete
   the package afterwards). This is what settles risk 1: whether a signed push
   to GHCR works with only `docker login`.
5. **The first real release is `0.4.0`, not `0.3.0`.** `VERSION`, the specs and
   `## [0.3.0] - 2026-09-04` already agree and `v0.3.0` was never tagged, but
   `## [Unreleased]` now holds five `Added` entries of post-0.3.0 `sbxpi` work
   (four OpenRouter models plus Ollama). Tagging the tip `v0.3.0` would publish
   unreleased features under an already-cut version. New features, no breaking
   change → minor bump: move the `Unreleased` entries under
   `## [0.4.0] - <date>`, set `VERSION` and all four `kits/*/spec.yaml`
   `version:` to `0.4.0`, restore an empty `## [Unreleased]`, then tag
   `v0.4.0` — deliberately and confirmed, per `AGENTS.md`.
6. After the first publish, flip all four packages to **Public** in GitHub →
   your profile → Packages → each package → Package settings. They are private
   until then, and a consumer will get a 404 rather than "unauthorized".
7. End to end, from a directory that is not this repo:

   ```bash
   sbx kit inspect ghcr.io/lars20070/sbxclaude:0.4.0
   sbx kit provenance ghcr.io/lars20070/sbxclaude:0.4.0
   sbx kit verify ghcr.io/lars20070/sbxclaude:0.4.0 \
     --certificate-oidc-issuer https://token.actions.githubusercontent.com \
     --certificate-identity-regexp '^https://github.com/lars20070/sbxagent/'
   sbx run --kit ghcr.io/lars20070/sbxclaude:0.4.0 claude
   ```

   `inspect` should report `sbxclaude 0.4.0`; `verify` should report the
   workflow identity; the sandbox should come up exactly like a local
   `sbxclaude`. **If the last command fails with a kit-source allowlist error
   rather than a registry error, that is the consumer-side trust setting, not a
   publishing bug** — see risk 4 for what to check and how to widen it.
8. Confirm `latest` and `0.4.0` resolve to one digest:
   `oras manifest fetch --descriptor ghcr.io/lars20070/sbxclaude:latest`.

## Risks and open questions

1. **Whether a *signed* push to GHCR works with only `docker login` is
   unproven.** `sbx kit push --help` on v0.39.0 says push auth is the Docker
   credential store, but upstream's `PUBLISHING.md` says signing "requires real
   Hub credentials" and their workflow does a separate `sbx login` before
   pushing — and a v0.42.0-rc release note ("`sbx kit push` now authenticates
   from the sbx credential store, so a single `sbx login` or `docker login` is
   enough for pushing, signing, and attaching provenance") reads as the fix for
   exactly that split. `releases/latest` resolves to the newest non-prerelease,
   v0.39.0, which predates it. Upstream's constraint is Hub-specific and may
   not apply to GHCR at all, but the plan does not assume that. Three defences:
   the probe in verification step 4; the `SIGN=` escape hatch, so a release can
   proceed unsigned rather than blocking; and the documented recovery
   `sbx kit sign ghcr.io/lars20070/<kit>:<version>`, which attaches a signature
   to an already-pushed OCI reference — so a push that lands unsigned is
   fixable in place, without a version bump.
2. **Signature and provenance are attached as OCI referrers.** GHCR supports the
   referrers API, but if it falls back to the tag-based scheme the artifacts
   still publish — only `sbx kit verify` would need checking. Verification step 7
   catches this; it does not block the release itself.
3. **`sbx kit` is marked EXPERIMENTAL** ("this command may change or be removed
   in future releases"), and the publish job installs the *latest* sbx, matching
   `ci.yml`'s deliberate exception. A CLI change could therefore break a release
   rather than a PR. The alternative — pinning sbx for publishing only — trades
   that for silently publishing in an outdated format; not worth it while the
   format is `schemaVersion: "2"` and stable.
4. **The consumer may need to trust `ghcr.io` as a kit source.** The review
   states sbx allows only `docker.io/` by default via a `kit.allowedSources`
   setting; I could not verify that against the docs or the local CLI, so it is
   recorded as unverified rather than designed around. It costs nothing to be
   ready for: it is a one-line setting on the consumer's host, it cannot be
   fixed from the publishing side, and verification step 7 will surface it
   immediately. If it turns out to be real, decision 4 (no README consumption
   guide) is worth revisiting for that single line — publishing artifacts nobody
   can load by default would be a poor result.
5. **`oras tag` reads before it writes**, so a push-only credential fails
   *after* the immutable tag is already published. `GITHUB_TOKEN` with
   `packages: write` also grants read, so this is fine here — but it is the
   failure mode to look for if the token is ever narrowed.
6. **Reuse-on-collision means re-cutting a published version publishes nothing.**
   Deliberate (see change 1, step 3), but it depends on the summary being read.
7. **`git tag` discipline is currently loose**: `v0.2.0` exists and points at a
   PR merge commit. From here on a tag push has a side effect, so `verify`
   failing loudly on a mismatched tag is load-bearing rather than decorative.

## Not doing

- Not touching `scripts/sbxagent` or `tests/sbxagent_test.sh` — decision 4. The
  wrapper keeps passing the local `kits/<name>/` directory, and `sbx kit
  validate` does not accept OCI references anyway, so `make validate` needs the
  local tree regardless.
- No README consumption guide — decision 4, subject to risk 4.
- **No unit test for `publish-kit.sh`.** `tests/sbxagent_test.sh`'s fake-CLI
  harness would extend to it, but the script's risky behaviour is all in how it
  reacts to a *real* registry (tag present, absent, or unreadable), which a fake
  `oras` would only re-assert rather than test. `shellcheck --enable=all` plus a
  mandatory `make publish-dry-run` is the agreed bar; revisit if the script
  grows branches that are not about registry state.
- No publishing from `main` and no dated/rolling tags. Releases are the only
  trigger, which is what makes `latest` mean "newest release".
- No container images, and no `Dockerfile`: three kits inherit their image via
  `extends:`, and `sbxpi` uses `docker/sandbox-templates:shell-docker`
  deliberately as a moving tag.
- Not automating the GHCR visibility flip — it needs a PAT with package scope,
  and it is a one-time action per package.
