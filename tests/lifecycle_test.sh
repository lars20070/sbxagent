#!/usr/bin/env bash
# Live proof that the trace bind mount survives the sandbox lifecycle: the
# stock path stays a real directory, so a stop and a fresh start succeed and
# the bind is re-made.
#
# Needs a live sbx daemon, so it is outside `make test`, next to test-toolchain.
# It touches none of your real sandboxes: it works in a throwaway project
# directory with its own XDG_STATE_HOME, which gives the wrapper a different
# sandbox name and a different state folder, and removes the sandbox on exit.
#
# Usage: ./tests/lifecycle_test.sh [claude|codex|cursor|pi]
#
# Every `sbx` interaction is wrapped in a one-line function below, because a few
# of them encode assumptions about the CLI that could not be checked when this
# was written: that `sbx run --name X -- <flag>` runs the kit entrypoint
# non-interactively, that the sandbox keeps running once that agent process
# exits, and that `sbx exec` can reach a stopped sandbox. If one of those is
# wrong, the fix is in that function rather than spread through the cases.
set -euo pipefail

AGENT="${1:-claude}"
KIT="sbx${AGENT}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS=0

fail() {
	echo "not ok - $*" >&2
	exit 1
}

pass() {
	TESTS=$((TESTS + 1))
	echo "ok ${TESTS} - $*"
}

case "${KIT}" in
sbxclaude) STOCK=".claude/projects"; SUBDIR="projects" ;;
sbxcodex) STOCK=".codex/sessions"; SUBDIR="sessions" ;;
sbxcursor) STOCK=".cursor/projects"; SUBDIR="projects" ;;
sbxpi) STOCK=".pi/agent/sessions"; SUBDIR="sessions" ;;
*) fail "unknown agent '${AGENT}'; expected claude, codex, cursor or pi" ;;
esac

command -v sbx >/dev/null 2>&1 ||
	fail "sbx is not on PATH; this test needs a host with a live sbx daemon"

TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/lifecycle-test.XXXXXX")"
export XDG_STATE_HOME="${TEST_ROOT}/xdg-state"
PROJECT="${TEST_ROOT}/sbxagent-lifecycle"
mkdir -p "${PROJECT}" "${TEST_ROOT}/bin"
# The wrapper dispatches on the name it was invoked as, so it has to be reached
# through a link named for the kit.
WRAPPER="${TEST_ROOT}/bin/${KIT}"
ln -s "${ROOT}/scripts/sbxagent" "${WRAPPER}"
cd "${PROJECT}"

SANDBOX="$("${WRAPPER}" name)"
# Mirrors the wrapper's own layout: the sandbox name is <kit>-<slug>-<hash> and
# the agent state folder is <state home>/sbxagent/traces/<slug>-<hash>/<kit>.
STATE_DIR="${XDG_STATE_HOME}/sbxagent/traces/${SANDBOX#"${KIT}"-}/${KIT}"
TARGET="${STATE_DIR}/${SUBDIR}"

cleanup() {
	cd "${TEST_ROOT}"
	sbx rm "${SANDBOX}" >/dev/null 2>&1 || true
	rm -rf "${TEST_ROOT}"
}
trap cleanup EXIT

echo "# kit ${KIT}, disposable sandbox ${SANDBOX}"

# --- the assumptions, isolated -------------------------------------------

# Run the sandbox's configured entrypoint and let it exit again. Passing the
# agent's own version flag after `--` means the entrypoint runs in full — trace
# relocation included — and then the agent prints a line and exits, instead of
# opening a TUI this test would have to drive.
run_entrypoint() {
	sbx run --name "${SANDBOX}" -- --version </dev/null
}

# A command in the sandbox that does *not* go through the entrypoint.
in_sandbox() {
	sbx exec -i "${SANDBOX}" -- "$@" </dev/null
}

# --- the cases ------------------------------------------------------------

# Device and inode of a path inside the sandbox, always Linux, so plain GNU
# `stat -c`. Empty when the path cannot be stat'd at all.
trace_id() {
	in_sandbox stat -c '%d:%i' "$1" 2>/dev/null || true
}

# The same for a path on the host, which is a Mac as often as not: GNU first,
# then BSD, the same capability probe scripts/sbxagent uses for shasum.
host_id() {
	stat -c '%d:%i' "$1" 2>/dev/null || stat -f '%d:%i' "$1" 2>/dev/null || true
}

# True only when both sides answered and agree, so two failed stats cannot read
# as a match.
same_id() {
	[[ -n "$1" && "$1" == "$2" ]]
}

# Field 5 of mountinfo is the mount point, space-delimited, so a stack of mounts
# at one path shows up as a count above one. Claude legitimately has two: the
# parent kit's own volume, and this bind on top of it.
mount_depth() {
	in_sandbox sh -c 'grep -c " '"${1}"' " /proc/self/mountinfo || true'
}

"${WRAPPER}" create >/dev/null || fail "could not create ${SANDBOX}"
# `sbx exec` runs the command directly rather than through a shell, so $HOME has
# to be resolved once, inside, instead of being passed unexpanded.
# shellcheck disable=SC2016 # $HOME must expand in the sandbox, not here.
HOME_IN_SANDBOX="$(in_sandbox sh -c 'printf %s "$HOME"')"
[[ -n "${HOME_IN_SANDBOX}" ]] || fail "could not resolve HOME inside ${SANDBOX}"
STOCK_ABS="${HOME_IN_SANDBOX}/${STOCK}"

# Created but never attached, so the entrypoint has not run. The bind must
# still be there: that is the whole job of the `setup: startup:` call site, and
# without it every session that does not go through the entrypoint writes to an
# unbound stock path and loses its traces when the sandbox goes away.
same_id "$(trace_id "${STOCK_ABS}")" "$(host_id "${TARGET}")" ||
	fail "${STOCK_ABS} is not bound after 'create' alone; the startup call site did not run"
pass "the startup step binds the stock trace path before any attach"

# 1. The entrypoint runs and the bind exists, seen from a *separate* session
#    rather than from the process that made it.
run_entrypoint >/dev/null || fail "the entrypoint failed on the first start"
[[ -d "${TARGET}" ]] || fail "the entrypoint did not create ${TARGET} on the host"
same_id "$(trace_id "${STOCK_ABS}")" "$(host_id "${TARGET}")" ||
	fail "${STOCK_ABS} is not bind-mounted onto ${TARGET} after the first start"
pass "the entrypoint binds the stock trace path, visible from another session"

# 2. The bind is real: a write at the stock path inside the sandbox lands in the
#    state folder on the host, not merely somewhere that exists.
in_sandbox sh -c "printf 'first\\n' > '${STOCK_ABS}/lifecycle-marker'" ||
	fail "could not write a marker at ${STOCK_ABS}"
[[ -f "${TARGET}/lifecycle-marker" ]] ||
	fail "the marker written in the sandbox did not appear at ${TARGET} on the host"
pass "a write at the stock path lands in the host state folder"

# 3. Re-running the entrypoint does not stack another mount. Not an assertion
#    that the depth is one: Claude's stock path also carries its parent kit's
#    own volume underneath.
BASELINE_DEPTH="$(mount_depth "${STOCK_ABS}")"
[[ "${BASELINE_DEPTH}" -ge 1 ]] ||
	fail "${STOCK_ABS} reports no mount at all (depth ${BASELINE_DEPTH})"
run_entrypoint >/dev/null || fail "the entrypoint failed on a repeat start"
run_entrypoint >/dev/null || fail "the entrypoint failed on a second repeat start"
DEPTH_NOW="$(mount_depth "${STOCK_ABS}")"
[[ "${DEPTH_NOW}" -le "${BASELINE_DEPTH}" ]] ||
	fail "mounts at ${STOCK_ABS} grew from ${BASELINE_DEPTH} to ${DEPTH_NOW}"
pass "repeat starts do not stack another mount (depth stayed at ${BASELINE_DEPTH})"

# 4. A stop and a fresh start: the stock path stays a real directory, so the
#    runtime can recreate its mount destination and the bind is re-made.
sbx stop "${SANDBOX}" >/dev/null 2>&1 || fail "could not stop ${SANDBOX}"

# Reached with `sbx exec` alone after the stop, so the entrypoint never runs.
# The more important instance of the check above, because this is the shape of
# `make test-toolchain` and of any agent launched by hand from `exec bash`.
same_id "$(trace_id "${STOCK_ABS}")" "$(host_id "${TARGET}")" ||
	fail "${STOCK_ABS} is not bound after 'stop' + 'exec' with no attach; the startup call site did not replay"
pass "the startup step re-binds after a stop, without any attach"

run_entrypoint >/dev/null ||
	fail "the entrypoint failed after a stop"
same_id "$(trace_id "${STOCK_ABS}")" "$(host_id "${TARGET}")" ||
	fail "${STOCK_ABS} is not bound again after a stop and restart"
[[ "$(in_sandbox cat "${STOCK_ABS}/lifecycle-marker")" == first ]] ||
	fail "the marker from the first start is not readable after a restart"
in_sandbox sh -c "printf 'second\\n' > '${STOCK_ABS}/lifecycle-marker-2'" ||
	fail "could not write at ${STOCK_ABS} after a restart"
[[ -f "${TARGET}/lifecycle-marker-2" ]] ||
	fail "a write after the restart did not reach ${TARGET} on the host"
pass "the sandbox restarts, rebinds, and keeps its traces across a stop"

# 5. Upstream docker/sbx-releases#388: a mount whose source is a host directory
#    can be silently unmounted when the host modifies that tree. That is the one
#    failure mode this design introduces, so provoke it deliberately from the
#    host side. A failure here does not mean the fix is wrong — a rare silent
#    detach is still better than a hard crash on every restart — but it must be
#    reported, because it decides whether docs/traces.md needs to warn users off
#    touching the state folder mid-session, and whether a re-bind watchdog
#    becomes its own piece of work.
printf 'host\n' >"${TARGET}/host-side-scratch"
rm -f "${TARGET}/host-side-scratch"
same_id "$(trace_id "${STOCK_ABS}")" "$(host_id "${TARGET}")" ||
	fail "the bind at ${STOCK_ABS} detached after a host-side write — upstream issue #388 reproduces here"
in_sandbox sh -c "printf 'third\\n' > '${STOCK_ABS}/lifecycle-marker-3'" ||
	fail "could not write at ${STOCK_ABS} after a host-side write"
[[ -f "${TARGET}/lifecycle-marker-3" ]] ||
	fail "a write after a host-side change did not reach ${TARGET} — upstream issue #388 reproduces here"
pass "the bind survives a host-side write to the state folder (upstream #388 did not reproduce)"

echo "All ${TESTS} lifecycle checks passed for ${KIT}."
