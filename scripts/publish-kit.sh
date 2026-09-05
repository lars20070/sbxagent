#!/usr/bin/env bash
set -euo pipefail

# Publish one kit directory to an OCI registry, then re-point the rolling tag
# and sign the result.
#
#   usage: scripts/publish-kit.sh KIT VERSION      (for example: sbxpi 0.4.0)
#
#   REGISTRY    registry host                            (default ghcr.io)
#   NAMESPACE   registry namespace                       (default lars20070)
#   LATEST_TAG  rolling tag re-pointed at the same digest (default latest)
#   REPO_NAME   override the package name; probe use only (default: the kit name)
#   SIGN        non-empty to sign after pushing          (default 1)
#   DRY_RUN     non-empty to validate and print only     (default empty)
#
# All the logic lives here rather than in workflow YAML so that `make lint`
# covers it with shellcheck, and so `make publish-dry-run` rehearses the whole
# path locally with no registry, no credentials and no network.
#
# The release workflow calls this once per kit in a `fail-fast: false` matrix,
# so every step has to stay safe to re-run after a sibling kit failed midway.
# That is what the skip-if-already-published branch below is for.

SELF="$(basename "$0")"

REGISTRY="${REGISTRY:-ghcr.io}"
NAMESPACE="${NAMESPACE:-lars20070}"
LATEST_TAG="${LATEST_TAG:-latest}"
# Probe use only: it lets a throwaway package exercise the real publish path
# without touching the four real packages. Empty — use the kit name — is the
# only correct value for a release.
REPO_NAME="${REPO_NAME:-}"
# ${SIGN-1}, not ${SIGN:-1}: empty is a meaningful value here — it is the off
# switch, and the workflow passes SIGN='' to mean "do not sign". :- would treat
# that empty string as unset and turn signing back on, silently defeating the
# only way to ship a release unsigned. The variables above keep :- deliberately,
# because an empty registry or namespace is not a meaningful value, only a
# broken one.
SIGN="${SIGN-1}"
DRY_RUN="${DRY_RUN:-}"

die() {
	echo "${SELF}: $*" >&2
	exit 1
}

note() {
	echo "${SELF}: $*"
}

require() {
	command -v "$1" >/dev/null 2>&1 || die "no $1 found in PATH"
}

# fd 3 carries machine-readable key=value output for $GITHUB_OUTPUT. CI opens
# it (3>>"$GITHUB_OUTPUT"); when it is closed, fall back to the real stdout so a
# local run still prints the values. Everything else is redirected to stderr, so
# that `sbx kit validate`'s "VALID: ..." line, `sbx kit inspect`'s report and
# oras's chatter can never land in $GITHUB_OUTPUT and fail the step with
# "Invalid format".
if ! { : >&3; } 2>/dev/null; then
	exec 3>&1
fi
exec 1>&2

[[ "$#" -eq 2 ]] || die "usage: ${SELF} KIT VERSION    (for example: ${SELF} sbxpi 0.4.0)"

kit="$1"
version="$2"

# Never symlinked, so plain dirname is enough — unlike scripts/sbxagent, which
# is installed as a symlink and has to walk the chain to find its kit.
repo="$(cd "$(dirname "$0")/.." && pwd -P)"

[[ -f "${repo}/kits/${kit}/spec.yaml" ]] ||
	die "no kit at kits/${kit}/spec.yaml"

# Compose the reference from the directory name, never from an argument and
# never from the spec. `sbx kit push` uses the reference it is handed verbatim:
# it derives nothing from the kit and validates nothing against it, so a wrong
# value here would push a kit manifest over an unrelated tag in the namespace.
repo_ref="${REGISTRY}/${NAMESPACE}/${REPO_NAME:-${kit}}"
version_ref="${repo_ref}:${version}"

require sbx

# Published bytes must be committed bytes: staging below reads HEAD, so an
# uncommitted edit would be silently left out of the artifact. Enforced only
# when actually publishing, so that a dry run stays usable mid-change.
dirty="$(git -C "${repo}" status --porcelain -- "kits/${kit}" VERSION)"
if [[ -n "${dirty}" ]]; then
	if [[ -z "${DRY_RUN}" ]]; then
		die "uncommitted changes under kits/${kit} or VERSION; commit them first"
	fi
	note "WARNING: uncommitted changes under kits/${kit} or VERSION."
	note "WARNING: staging reads HEAD, so those edits are NOT what would ship."
fi

# Stage a tracked-files-only copy. `sbx kit push` packages the directory as it
# finds it and does not respect .gitignore, so pushing straight from the working
# tree would bake in whatever is lying around — .DS_Store files currently sit
# under kits/ on macOS checkouts. `git archive` emits exactly the tracked files,
# matching the `git ls-files` philosophy the Makefile already uses throughout.
stage="$(mktemp -d)"
trap 'rm -rf "${stage}"' EXIT
git -C "${repo}" archive HEAD -- "kits/${kit}" | tar -x -C "${stage}"

staged="${stage}/kits/${kit}"
[[ -f "${staged}/spec.yaml" ]] ||
	die "kits/${kit} is not committed at HEAD, so nothing was staged"

# Validate and inspect before the dry-run exit, so a dry run still catches a
# broken kit and still shows exactly what would ship.
sbx kit validate "${staged}"
sbx kit inspect "${staged}"

# Same extraction the Makefile's version-agreement check uses. `make lint`
# checks this repo-wide; repeating it per kit keeps the script safe to run on
# its own, and catches a stale spec in the staged copy specifically.
spec_version="$(grep -m1 '^version:' "${staged}/spec.yaml" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)"
[[ -n "${spec_version}" ]] || die "could not find version: in kits/${kit}/spec.yaml"
[[ "${spec_version}" == "${version}" ]] ||
	die "kits/${kit}/spec.yaml is version ${spec_version} but ${version} was requested"

if [[ -n "${DRY_RUN}" ]]; then
	note "DRY RUN — nothing will be published."
	note "  would push  ${version_ref}"
	note "  would tag   ${repo_ref}:${LATEST_TAG} at the same digest"
	if [[ -n "${SIGN}" ]]; then
		note "  would sign  the pushed digest"
	else
		note "  would NOT sign (SIGN is empty)"
	fi
	exit 0
fi

require oras
require jq

# Sets PROBE_DIGEST to the tag's digest, or to the empty string when the tag
# definitively does not exist. Returns non-zero when the registry could not be
# read at all, leaving the reason in PROBE_ERROR.
#
# Probed with oras rather than `docker manifest inspect`: a kit is an OCI
# manifest with a custom artifactType and a non-image config, which
# image-oriented tooling may reject outright — and a rejection would be
# indistinguishable from "absent", waving through the very overwrite this probe
# exists to prevent. So anything that is not a recognisable "not found" is an
# error: "could not tell" must never be read as "absent".
#
# It sets a global and is called as a plain command rather than printing into
# "$(...)", and it never calls die. A die inside a command substitution exits
# only the subshell, and whether that aborts the parent depends on set -e
# behaviour that differs across bash versions — AGENTS.md pins bash 3.2 as the
# floor, which is what macOS ships as /bin/bash. Getting it wrong there would
# turn an unreadable registry into an assumed-absent tag and overwrite an
# already published immutable version. The status is checked explicitly instead,
# so the decision never rests on set -e at all.
PROBE_DIGEST=""
PROBE_ERROR=""
probe_digest() {
	local reference="$1"
	local out
	PROBE_DIGEST=""
	PROBE_ERROR=""
	if out="$(oras manifest fetch --descriptor "${reference}" 2>&1)"; then
		PROBE_DIGEST="$(printf '%s\n' "${out}" | jq -r '.digest')"
		return 0
	fi
	if printf '%s\n' "${out}" |
		grep -qEi 'not found|manifest unknown|name unknown|404'; then
		return 0
	fi
	PROBE_ERROR="${out}"
	return 1
}

if ! probe_digest "${version_ref}"; then
	die "could not read ${version_ref}: ${PROBE_ERROR}"
fi
existing="${PROBE_DIGEST}"

pushed=no
reused=no
if [[ -n "${existing}" && "${existing}" != "null" ]]; then
	# Skip rather than overwrite, and reuse the digest. Upstream treats a
	# colliding release tag as fatal, but here one git tag publishes every kit,
	# so a run that fails on the third kit has to be re-runnable without
	# re-cutting the version. The cost is that re-cutting an already-published
	# version publishes nothing at all, which is why this says so loudly.
	reused=yes
	note "NOTICE: ${version_ref} already exists — NOT overwriting it."
	note "NOTICE: reusing ${existing}. Nothing new was published for ${kit}."
	note "NOTICE: if you meant to publish changed content, cut a new version."
else
	sbx kit push "${staged}" "${version_ref}"
	pushed=yes
fi

if ! probe_digest "${version_ref}"; then
	die "published ${version_ref} but could not read it back: ${PROBE_ERROR}"
fi
digest="${PROBE_DIGEST}"
# Written as an if rather than `[[ -n "${digest}" ]] && ...`, because under
# set -e a failing first test of an && list falls through instead of aborting.
if [[ -z "${digest}" || "${digest}" == "null" ]]; then
	die "published ${version_ref} but could not read its digest back"
fi

digest_ref="${repo_ref}@${digest}"

# Re-point the rolling tag at the digest rather than pushing a second time.
# oras.PackManifest stamps org.opencontainers.image.created, so re-pushing the
# same tree yields a different manifest digest even though the layer is
# byte-stable — and each digest would carry its own signature and provenance,
# so the two tags would advertise different attestations for one source. That
# annotation has one-second resolution, so two pushes within the same second do
# match: the divergence is intermittent, which is worse than reliable.
#
# Addressing the digest also stops a racing push from swapping what the rolling
# tag ends up naming. Note oras tag needs pull as well as push on the
# repository: it fetches the manifest before re-PUTting it under the new tag, so
# a push-only credential fails here, after the immutable tag is published.
oras tag "${digest_ref}" "${LATEST_TAG}"

# Sign as its own step, and run it even on the reuse path above — that is the
# whole point of separating it from the push.
#
# Never `sbx kit push --sign`: upstream documents that attaching a signature is
# an OCI-referrer write resolving credentials from sbx's own session rather than
# the Docker credential store, and that it therefore fails AFTER the unsigned
# manifest has already been pushed. Combined with the skip-if-present branch
# above, that would leave a kit published-but-unsigned and every re-run
# reporting "reused" — unsigned forever, silently. Split apart, a signing
# failure leaves a correctly published artifact that a re-run signs in place,
# with no version bump.
#
# Signed by digest so the target is unambiguous. Two things the Stage 4 probe
# settles and this cannot: whether `sbx kit sign` accepts a @sha256: reference
# (fall back to "${version_ref}" if not), and whether re-signing an
# already-signed kit attaches a duplicate referrer (gate this behind
# `sbx kit verify` if it does).
signed=no
if [[ -n "${SIGN}" ]]; then
	sbx kit sign "${digest_ref}"
	signed=yes
fi

{
	printf 'ref=%s\n' "${repo_ref}"
	printf 'digest=%s\n' "${digest}"
	printf 'pushed=%s\n' "${pushed}"
	printf 'reused=%s\n' "${reused}"
	printf 'signed=%s\n' "${signed}"
} >&3

if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
	# The backticks below are Markdown code spans for the job summary, not
	# command substitution, so these format strings must stay single-quoted and
	# unexpanded. Scoped to this block rather than disabled in .shellcheckrc,
	# where it would stop catching real accidental backticks everywhere else.
	# shellcheck disable=SC2016
	{
		if [[ "${reused}" == yes ]]; then
			printf '### %s — REUSED, nothing published\n\n' "${kit}"
			printf '`%s` already existed and was **not** overwritten.\n' "${version_ref}"
			printf 'To publish changed content, cut a new version.\n\n'
		else
			printf '### %s — published\n\n' "${kit}"
		fi
		printf '| field | value |\n|---|---|\n'
		printf '| reference | `%s` |\n' "${version_ref}"
		printf '| rolling | `%s` |\n' "${repo_ref}:${LATEST_TAG}"
		printf '| digest | `%s` |\n' "${digest}"
		printf '| signed | %s |\n\n' "${signed}"
	} >>"${GITHUB_STEP_SUMMARY}"
fi

note "${kit}: ${version_ref} -> ${digest} (pushed=${pushed} reused=${reused} signed=${signed})"
