#!/usr/bin/env bash
set -euo pipefail

# Print one release's section of CHANGELOG.md, for use as GitHub Release notes.
#
#   usage: scripts/release-notes.sh VERSION      (for example: 0.4.1)
#
# A pure function — version in, notes out — so the release workflow can pipe it
# straight into `gh release create --notes-file -`, and so it is testable by
# hand without a registry, a tag, or CI.
#
# It is called twice per release, deliberately. The `verify` job runs it with
# stdout discarded, purely so an empty section fails the run *before* any kit is
# published; the `github-release` job then runs it for the notes themselves.
# `make lint` cannot cover that: it checks only that the latest `## [X.Y.Z]`
# heading exists and agrees with VERSION, and a heading with an empty body
# passes that happily.

SELF="$(basename "$0")"

die() {
	echo "${SELF}: $*" >&2
	exit 1
}

[[ "$#" -eq 1 ]] || die "usage: ${SELF} VERSION    (for example: ${SELF} 0.4.1)"

version="$1"

# Never symlinked, so plain dirname is enough — unlike scripts/sbxagent, which
# is installed as a symlink and has to walk the chain.
repo="$(cd "$(dirname "$0")/.." && pwd -P)"
changelog="${repo}/CHANGELOG.md"

[[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
	die "'${version}' is not of the form X.Y.Z"
[[ -f "${changelog}" ]] || die "no CHANGELOG.md at ${changelog}"

# Escape the dots so 0.4.1 cannot also match 0x4x1. Built from the argument
# rather than interpolated raw, because awk takes an extended regexp here and an
# unescaped dot matches any character.
pattern="$(printf '%s' "${version}" | sed 's/\./\\./g')"

# Same shape the Makefile already uses to slice this file. The heading line is
# skipped by `next`, so the notes start at the first `### ` — which is what we
# want: GitHub already shows the tag as the title and dates the release, so
# repeating "## [0.4.1] - 2026-09-05" inside the body is noise.
notes="$(awk -v pat="^## \\\\[${pattern}\\\\]" \
	'$0 ~ pat {f=1; next} /^## \[/ {f=0} f' "${changelog}")"

# The valuable half. An empty body means a version was cut with nothing to say
# about it, which is worth failing a release over — and, called from `verify`,
# it fails before anything is published rather than after.
#
# grep rather than `tr -d '[:space:]'`: AGENTS.md warns that BSD tr is
# multibyte-aware while GNU tr is byte-oriented, and changelog entries carry
# non-ASCII punctuation. A bracket expression behaves the same on both.
printf '%s' "${notes}" | grep -q '[^[:space:]]' ||
	die "CHANGELOG.md has no content under '## [${version}]'"

printf '%s\n' "${notes}"
