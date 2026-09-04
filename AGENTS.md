# Agent Instructions

> **Scope:** these are instructions for **development agents** working *on* this
> repository (e.g. Claude Code) — how to build, lint, and validate it. They are
> not instructions for the coding agent running inside a sandbox.

## Repository Map

- `kits/<command>/spec.yaml` — one Docker Sandbox Kit spec per wrapper command:
  agent, resources, network policy, and setup commands baked into that sandbox.
  There are three — `kits/sbxclaude/`, `kits/sbxcodex/`, `kits/sbxcursor/` —
  and the directory name is the single source of identity: it equals `name:` in
  the spec, the `sbx` positional operand, the sandbox-name prefix, and the
  command you type.
- `kits/<command>/files/` — files copied into that sandbox at kit-build time.
- `scripts/sbxagent` — wrapper CLI around `sbx` that creates, rebuilds, and
  re-attaches the per-project sandbox. It dispatches on `basename "$0"`, so it
  is invoked through the `scripts/sbxclaude`, `scripts/sbxcodex` and
  `scripts/sbxcursor` symlinks, never under its own name. Run
  `./scripts/sbxclaude -h` for the current command list rather than relying on
  this doc, which won't track it.

## Commands

```bash
make lint           # markdownlint, jq, esbuild, yamllint, shellcheck, bash -n, cspell
make test           # run all tests
make test-unit      # test wrapper dispatch with a fake sbx CLI
make test-toolchain # test helper tools inside the live sandbox
make validate       # validate against the current Docker Sandbox Kit schema
```

`make lint` is the single source of truth for linting — CI runs the same
target. Add a new check there, not as a separate command, so it can't drift.
Unknown-but-correct words go in `.cspell.json`.

## Critical Requirement

Before finishing any task that touches any `kits/*/spec.yaml` or `kits/*/files/`,
run `make validate` — it validates all three kits, and it's a static schema
check with no Docker, no `sbx login`, and no network, so there's no reason to
skip it. Before finishing any task that touches `scripts/sbxagent` or any other
shell script, run `make lint` — it runs `shellcheck` and `bash -n` over every
tracked script.

## Portability

The wrapper has to run unchanged on macOS and Linux hosts.

- Probe for capabilities, never for the OS name. The `shasum` → `sha256sum`
  fallback in `scripts/sbxagent` is the pattern to copy; there is no `uname`
  branch anywhere and there should not be one.
- Say `macOS` and `Linux` in code, comments, and docs. No distro or subsystem
  names. Identifiers are exempt: CI runner labels, `apt-get`, the `docker-sbx`
  package, and release asset filenames.
- bash 3.2 is the floor, because that is what macOS ships as `/bin/bash`. No
  `declare -A`, `mapfile`, `${var,,}`, `[[ -v ]]`, and no bare `"${arr[@]}"` on
  a possibly-empty array under `set -u`. CI pins this with
  `make test-unit BASH=/bin/bash` on the macOS runner.
- No GNU-only flags: `readlink -f`, `xargs -r`, `stat -c`, `date -d`, `sed -i`
  without an argument. Watch `tr` too — BSD `tr` is multibyte-aware while GNU
  `tr` is byte-oriented, so the two disagree on non-ASCII input.
- Known difference, currently harmless: on empty input GNU `xargs` runs the
  command once with no arguments while BSD `xargs` skips it. Every glob in
  `make lint` matches at least one file today, so it does not bite; if a glob
  ever stops matching, Linux and macOS will disagree.

## Changelog

- Maintain `CHANGELOG.md` using Keep a Changelog and Semantic Versioning.
- Add notable user-facing changes under `## [Unreleased]`, grouped under
  `Added`, `Changed`, `Deprecated`, `Removed`, `Fixed`, or `Security`.
- Skip entries for tests, formatting, internal refactors, and documentation
  changes that do not affect users.
- For a release, move the relevant entries to `## [X.Y.Z] - YYYY-MM-DD`.
- Bump `VERSION` and `version:` in **every** `kits/*/spec.yaml` to match
  `X.Y.Z` in the same commit that cuts the `## [X.Y.Z] - YYYY-MM-DD` heading
  — `make lint` fails if any of them disagree with each other or with the
  changelog.
- Restore an empty `## [Unreleased]` heading above the new release heading.
- Tag that commit `vX.Y.Z` once `VERSION`, all kit specs, and `CHANGELOG.md`
  agree.
  Pushing the tag and publishing the kit itself are separate steps this
  repo does not yet define; confirm before pushing a tag anywhere.

## Skills

- `context7-docs` — fetch current library/framework docs before writing code
  against one.
- `debug-third-party` — check for a known upstream bug before working around
  an error that looks like it's from a dependency.
