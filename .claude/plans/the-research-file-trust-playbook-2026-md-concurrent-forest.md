# Security hardening plan (post-Scorecard)

## Context

`trust-playbook-2026.md` and `scorecard.json` (score 6.1) prompted a review of
what security work is still worth doing here. The review found the repo is
already most of the way there: least-privilege tokens, SHA-pinned actions,
Dependabot, `persist-credentials: false`, a SECURITY.md with a threat model,
Scorecard, keyless-signed + SLSA-attested kits on GHCR, checksummed `sbx` and
`github-mcp-server` downloads inside the kits, and a wrapper with no `eval`,
no downloads and no file writes. Most of the playbook's Stage 0/1 is done.

The meaningful attack surface is the kit build and the release workflow, not
the 217-line dispatcher. What is left is small. This plan does the few things
that buy real safety, and explicitly declines the rest so nobody re-litigates
them next quarter. Scorecard is a regression signal, not a target: no step
below exists to move a number.

Decisions already made with the user:

- **No** release tarball + attestation (nobody downloads a tarball; the kits
  on GHCR are the artifact and are already signed and attested).
- CodeQL via **default setup** in repo settings (zero files in the repo).
- **Yes** to SSH-signed release tags — documented only once the first signed
  tag exists, so SECURITY.md never claims something that is not yet true.
- **Yes** to removing the unused `github-mcp-server` from `sbxpi` (raised by
  `SECURITY_PLAN_REVIEW.md`). Pi has no MCP support and uses `gh` for GitHub
  work; the binary is installed as root and never run.

## Stage 1 — repo edits (this session)

### 1a. Verify the `sbx` binary the release workflow downloads

`.github/workflows/release.yml` (publish job, "Install sbx CLI" step, ~line
199) fetches `DockerSandboxes-linux.tar.gz` for `v0.42.0` with no checksum,
then runs its `install.sh` under `sudo`. That binary is what pushes and signs
every published kit. Every `kits/*/spec.yaml` already pins the SHA-256 of the
**same bytes** (verified: the generic and `-amd64` tarballs for v0.42.0 are
identical, `a88c56f0…52e7`).

Change: download → `sha256sum` → compare → **only then** `tar` and
`install.sh`, mirroring `kits/sbxclaude/spec.yaml` lines ~140–152. Keep the
generic Linux archive (right for the GitHub-hosted runner). Put the digest
next to `SBX_VERSION` as a second env var, `SBX_SHA256`, so the two are bumped
together in one visible place.

What this does and does not do: it proves the runner got the bytes the repo
revision says it should. It does not authenticate the upstream release
independently — someone who can edit both the workflow and the digest can
still publish. That residual risk is covered by branch protection, account
security and the artifact provenance, not by more copies of the digest.

`ci.yml`'s validate job stays unpinned — deliberate schema-drift canary,
documented in the workflow and `docs/toolchain.md`; it runs with
`contents: read` and no secrets. Out of scope.

Also: `docs/toolchain.md` "To bump a pin" step 1 currently says update the
`sbx` checksums in all four kits — add `.github/workflows/release.yml` to
that sentence. No new lint check; five copies of one digest that only move
on a deliberate `sbx` bump do not need machinery.

### 1b. Remove `github-mcp-server` from the `sbxpi` kit

- `kits/sbxpi/spec.yaml` ~lines 465–492: delete the install command block
  (description "GitHub MCP server binary, toolchain parity only — Pi never
  calls it"). Fix the allowlist comment at ~line 112 that names
  `github-mcp-server` as a reason for the GitHub hosts; the hosts themselves
  stay (`sbx` download, `gh`, Playwright browsing).
- `tests/toolchain_test.sh:90`: the `github-mcp-server --version` check must
  skip when `KIT_NAME == sbxpi` — reuse the existing `KIT_NAME` guard pattern
  at line ~147 / ~471.
- `docs/agents.md:58–62`: "Every kit installs `github-mcp-server`" → three
  kits install it; `sbxpi` does not, and uses `gh`.
- `docs/toolchain.md:65`: `github-mcp-server` row — "`kits/*/spec.yaml`" →
  the three non-Pi kits.
- `CHANGELOG.md` `### Removed`: `sbxpi` no longer installs
  `github-mcp-server`; Pi never called it. GitHub work there is `gh`, as
  before.

### 1c. `CHANGELOG.md` under `## [Unreleased]`

- `### Security`: release workflow verifies the SHA-256 of the `sbx` CLI it
  publishes with, against the same digest the kits pin.
- `### Removed`: as in 1b.

**Not in this stage:** any SECURITY.md or changelog wording about signed
tags. That lands with 2a, after the first signed tag exists.

## Stage 2 — host / GitHub settings (user does these, ~10 minutes)

None of these can be done from inside the sandbox. They are independent of
Stage 1 and of each other.

### 2a. Sign release tags (SSH) — at the next release

On the Mac, once:

```bash
git config --global gpg.format ssh
git config --global user.signingkey ~/.ssh/<your-key>.pub
git config --global tag.gpgsign true
```

Then GitHub → Settings → SSH and GPG keys → **New SSH key** → Key type
**Signing Key** → paste the same public key. Future `git tag vX.Y.Z` is
signed automatically and shows *Verified* on the tag page. Nothing in the
workflow changes.

Then, in the same release PR or right after: replace the last line of
`SECURITY.md` ("Git tags and commits are not signed.") with: release tags
are signed with the maintainer's SSH key and show as *Verified* on GitHub;
commits are not; the kit signature and provenance remain the thing to verify,
since the tag only triggers the build. Add a `### Security` changelog line.

A signed tag improves attribution. It does not replace the artifact
signature and it does not prove the source is safe.

### 2b. CodeQL default setup

GitHub → repo Settings → Code security → Code scanning → CodeQL analysis →
**Default**. Pick languages **GitHub Actions** and **JavaScript/TypeScript**
(the `.ts` extension). The point is workflow analysis: CodeQL's `actions`
queries catch expression injection and untrusted-checkout patterns in
workflow YAML, which shellcheck cannot see.

### 2c. Branch protection on `main`: one toggle

Enable **Require branches to be up to date before merging**. Harmless for a
solo maintainer. Leave *required approvers* off — a solo maintainer cannot
approve their own PR, so it would only block merges.

### 2d. Account: passkey / security-key 2FA

Check GitHub → Settings → Password and authentication. If only TOTP, add a
passkey. This is the control that would have stopped the 2025 `chalk`/`debug`
phish. Not a repo change; just confirm it once.

## Ongoing practice (not a task)

When a kit's agent changes, re-read that kit's allowlist, tools and MCP
servers and drop what the new agent no longer needs — 1b is one instance of
this. Do not trim allowlists just to make them shorter; several hosts are
needed for image construction or browsing.

## Considered and declined (so they stay declined)

| Item | Why not |
| --- | --- |
| Hash-pin the `npm install --global` lines (Pinned-Dependencies 6/10) | Needs a `package.json` + lockfile for three CI-only lint tools and a second Dependabot ecosystem. Versions are already pinned; hash pinning buys little for tools that never touch a secret. |
| `--ignore-scripts` on those npm installs | esbuild and Playwright rely on install scripts / optional deps; breakage risk outweighs the gain on a no-secrets job. |
| Release tarball + `attest-build-provenance` | Decided with the user: no consumer of a tarball exists; the kits are the artifact and are already signed and attested. |
| Extend SHA-256 pinning to npm/uv/apt packages in kit specs | No stable published digest to pin against without a lockfile or a pinned base image per kit. Version pins stay. Does not defend against a malicious maintainer anyway. |
| Required PR approvers / CODEOWNERS | Solo maintainer; would only block merges. |
| OpenSSF Best Practices badge | Self-certification paperwork; addresses no threat here. |
| Drop `actions/cache` from `release.yml`'s verify job | Cache is only readable from the same base ref; the job has `contents: read` and no secrets. Not worth the CI-time cost. |
| SBOM, fuzzing, third-party audit | Playbook and review agree: premature at this size. |
| "Have your coding agent check the code" as a user-facing claim | Playbook §5: misleading, and a prompt-injection footgun for exactly this tool. Not adding. |

## Files touched (Stage 1)

- `.github/workflows/release.yml` — checksum block in "Install sbx CLI"
- `kits/sbxpi/spec.yaml` — remove the `github-mcp-server` install block; fix
  one allowlist comment
- `tests/toolchain_test.sh` — skip the `github-mcp-server` check on `sbxpi`
- `docs/toolchain.md`, `docs/agents.md` — bump instructions; which kits
  install `github-mcp-server`
- `CHANGELOG.md` — one Security, one Removed entry under Unreleased
- `.cspell.json` — only if a new word trips cspell

Not committing or pushing; changes are left unstaged for the user per
AGENTS.md.

## Verification

1. `make lint` — yamllint on the workflow, shellcheck + `bash -n` on the
   test, markdownlint + cspell on the docs.
2. `make validate` — required because `kits/sbxpi/spec.yaml` changes.
3. Confirm the digest locally before committing the value:
   `curl -fsSL .../v0.42.0/DockerSandboxes-linux.tar.gz | sha256sum` must
   print `a88c56f02435974145a86d983beab4458b412c2133d5da0df7f12e117d8152e7`.
   This checks the chosen number, not what GitHub will execute — step 4 does
   that.
4. After merge, run the Release workflow via **workflow_dispatch** with
   `dry_run: true`. The dry run still executes the "Install sbx CLI" step, so
   a wrong digest fails there without publishing anything.
5. For 1b, on the host: `sbxpi rm && sbxpi` to rebuild, then
   `make test-toolchain AGENT=pi`. The rebuilt sandbox must have no
   `/usr/local/bin/github-mcp-server` and `gh issue list` must still work.
6. After 2a: `git tag -v <next tag>` locally; the tag page shows *Verified*.
7. After 2b/2c: confirm in the GitHub settings pages themselves. The next
   Scorecard run will reflect it, but the settings page is the evidence.
