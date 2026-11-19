#!/usr/bin/env bash
# Live proof, checked from the host, that the trace mount survives the sandbox
# lifecycle. The wrapper mounts the agent's trace folder in the host's project
# state straight onto the agent's native session-trace directory, so these
# checks write on one side and read on the other.
#
# Needs a live sbx daemon, so it is outside `make test`, next to test-toolchain.
# It touches none of your real sandboxes: it works in a throwaway project
# directory with its own XDG_STATE_HOME, which gives the wrapper a different
# sandbox name and a different state folder, and removes the sandbox on exit.
#
# Usage: ./tests/lifecycle_test.sh [claude|codex|cursor|pi]
#
# Every `sbx` interaction is wrapped in a one-line function below, because a few
# of them encode assumptions about the CLI: that `sbx run --name X -- <flag>`
# runs the agent non-interactively, that the sandbox keeps running once that
# agent process exits, and that `sbx exec` can reach a stopped sandbox. If one
# of those is wrong, the fix is in that function rather than spread through the
# cases.
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

note() {
	echo "# $*"
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
# Mirrors the wrapper's own layout: the sandbox name is <kit>-<slug>-<hash>, the
# project state folder is <state home>/sbxagent/traces/<slug>-<hash>, and this
# agent's traces live in <project state>/<kit>/<subdir>.
PROJECT_DIR="${XDG_STATE_HOME}/sbxagent/traces/${SANDBOX#"${KIT}"-}"
MESSAGEBOARD_DIR="${XDG_STATE_HOME}/sbxagent/messageboards/${SANDBOX#"${KIT}"-}"
TARGET="${PROJECT_DIR}/${KIT}/${SUBDIR}"
# Another agent's traces for the same project, made up for the visibility
# checks. No sandbox of that agent is ever created.
SIBLING="${PROJECT_DIR}/other-agent"

cleanup() {
	cd "${TEST_ROOT}"
	# --force: this is automated cleanup of a disposable sandbox, and from sbx
	# v0.45.0 a removal prompt that is declined (or never answered) exits
	# non-zero, which `|| true` would hide and leave the sandbox behind. The
	# wrapper's own `rm` deliberately never passes --force (see the unit test
	# in sbxagent_test.sh); only this trap and remove_sandbox do.
	sbx rm --force "${SANDBOX}" >/dev/null 2>&1 || true
	rm -rf "${TEST_ROOT}"
}
trap cleanup EXIT

note "kit ${KIT}, disposable sandbox ${SANDBOX}"

# --- the assumptions, isolated -------------------------------------------

# Run the sandbox's configured agent and let it exit again. Passing the agent's
# own version flag after `--` starts the agent, which then prints a line and
# exits, instead of opening a TUI this test would have to drive.
run_entrypoint() {
	sbx run --name "${SANDBOX}" -- --version </dev/null
}

# A command in the sandbox that does *not* go through the agent.
in_sandbox() {
	sbx exec -i "${SANDBOX}" -- "$@" </dev/null
}

remove_sandbox() {
	sbx rm --force "${SANDBOX}" >/dev/null 2>&1 || fail "could not remove ${SANDBOX}"
}

# --- the cases ------------------------------------------------------------

# 0. Traces from before this sandbox existed — an older sandbox, or the v2
#    kits' bind mount — are already in the host folder. They must show up, so
#    an upgrade keeps them.
mkdir -p "${TARGET}" "${SIBLING}"
printf 'old\n' >"${TARGET}/before-create"
printf 'sibling\n' >"${SIBLING}/trace"

CROSS_SANDBOX_VISIBILITY=true "${WRAPPER}" create >/dev/null ||
	fail "could not create ${SANDBOX} with CROSS_SANDBOX_VISIBILITY=true"
# `sbx exec` runs the command directly rather than through a shell, so $HOME has
# to be resolved once, inside, instead of being passed unexpanded.
# shellcheck disable=SC2016 # $HOME must expand in the sandbox, not here.
HOME_IN_SANDBOX="$(in_sandbox sh -c 'printf %s "$HOME"')"
[[ -n "${HOME_IN_SANDBOX}" ]] || fail "could not resolve HOME inside ${SANDBOX}"
STOCK_ABS="${HOME_IN_SANDBOX}/${STOCK}"

# Created but never attached, so the agent has not run. The mount comes from
# `create` itself, so nothing else has to have happened yet.
[[ "$(in_sandbox cat "${STOCK_ABS}/before-create")" == old ]] ||
	fail "a trace that was on the host before 'create' is not visible at ${STOCK_ABS}"
pass "traces already on the host are visible at the native path after 'create' alone"

# 1. A write at the native path inside the sandbox lands in the host folder.
in_sandbox sh -c "printf 'first\\n' > '${STOCK_ABS}/lifecycle-marker'" ||
	fail "could not write a marker at ${STOCK_ABS}"
[[ "$(cat "${TARGET}/lifecycle-marker" 2>/dev/null)" == first ]] ||
	fail "the marker written in the sandbox did not appear at ${TARGET} on the host"
pass "a write at the native trace path lands in the host state folder"

# 2. And the other way: a host-side write is visible inside.
printf 'host\n' >"${TARGET}/host-marker"
[[ "$(in_sandbox cat "${STOCK_ABS}/host-marker")" == host ]] ||
	fail "a file written on the host at ${TARGET} is not visible at ${STOCK_ABS}"
pass "a host-side write is visible at the native trace path"

# 3. Running the agent does not move or hide the mount.
run_entrypoint >/dev/null || fail "the agent failed on the first start"
[[ "$(in_sandbox cat "${STOCK_ABS}/lifecycle-marker")" == first ]] ||
	fail "the marker is not visible at ${STOCK_ABS} after the agent ran"
pass "the mount is unchanged once the agent has run"

# 4. A stop, then `sbx exec` alone, so the agent never runs: the shape of
#    `make test-toolchain` and of any agent launched by hand from `exec bash`.
sbx stop "${SANDBOX}" >/dev/null 2>&1 || fail "could not stop ${SANDBOX}"
printf 'stopped\n' >"${TARGET}/while-stopped"
[[ "$(in_sandbox cat "${STOCK_ABS}/while-stopped")" == stopped ]] ||
	fail "a host-side write made while the sandbox was stopped is not visible after 'exec'"
in_sandbox sh -c "printf 'second\\n' > '${STOCK_ABS}/lifecycle-marker-2'" ||
	fail "could not write at ${STOCK_ABS} after a stop"
[[ -f "${TARGET}/lifecycle-marker-2" ]] ||
	fail "a write after the stop did not reach ${TARGET} on the host"
run_entrypoint >/dev/null || fail "the agent failed after a stop"
pass "the mount survives a stop, with or without the agent running"

# 5. Shared mode, the default: the project state folder is mounted read-only
#    at its host path, so another agent's traces are readable and not writable,
#    and the messageboard is there, read-write.
[[ "$(in_sandbox cat "${SIBLING}/trace")" == sibling ]] ||
	fail "another agent's traces at ${SIBLING} are not readable in shared mode"
! in_sandbox sh -c "printf 'x\\n' > '${SIBLING}/written-from-sandbox'" 2>/dev/null ||
	fail "another agent's traces at ${SIBLING} are writable from this sandbox"
[[ ! -e "${SIBLING}/written-from-sandbox" ]] ||
	fail "a write from the sandbox reached another agent's traces on the host"
in_sandbox sh -c "printf 'post\\n' > '${MESSAGEBOARD_DIR}/lifecycle-post'" ||
	fail "the messageboard at ${MESSAGEBOARD_DIR} is not writable in shared mode"
[[ -f "${MESSAGEBOARD_DIR}/lifecycle-post" ]] ||
	fail "a messageboard post did not reach ${MESSAGEBOARD_DIR} on the host"
pass "shared mode: sibling traces are read-only, the messageboard is read-write"

# 6. Private mode: only this agent's own traces are mounted.
remove_sandbox
CROSS_SANDBOX_VISIBILITY=false "${WRAPPER}" create >/dev/null ||
	fail "could not create ${SANDBOX} with CROSS_SANDBOX_VISIBILITY=false"
[[ "$(in_sandbox cat "${STOCK_ABS}/lifecycle-marker")" == first ]] ||
	fail "this agent's own traces are not visible in private mode"
! in_sandbox test -e "${SIBLING}/trace" ||
	fail "another agent's traces at ${SIBLING} are visible in private mode"
! in_sandbox test -e "${MESSAGEBOARD_DIR}" ||
	fail "the messageboard at ${MESSAGEBOARD_DIR} is mounted in private mode"
pass "private mode: own traces only, no sibling traces, no messageboard"

# 7. The host folder disappears after create, while the sandbox is stopped.
#    The wrapper recreates it on every create, but not on a restart, which sbx
#    does on its own. sbx v0.54.0 refuses to start such a sandbox, naming the
#    missing folder, and docs/traces.md tells users so. Starting anyway would
#    silently keep that session's traces off the host, so a change here fails.
sbx stop "${SANDBOX}" >/dev/null 2>&1 || fail "could not stop ${SANDBOX}"
mv "${TARGET}" "${TARGET}.away"
if MISSING_OUTPUT="$(run_entrypoint 2>&1)"; then
	fail "sbx started the sandbox with its trace folder ${TARGET} missing; update docs/traces.md"
fi
[[ "${MISSING_OUTPUT}" == *"no longer exists on the host"* ]] ||
	fail "sbx refused to start for an unexpected reason: ${MISSING_OUTPUT}"
pass "a missing host trace folder stops the sandbox from starting"
sbx stop "${SANDBOX}" >/dev/null 2>&1 || true
rm -rf "${TARGET}"
mv "${TARGET}.away" "${TARGET}"
run_entrypoint >/dev/null || fail "the agent failed after the trace folder was restored"
[[ "$(in_sandbox cat "${STOCK_ABS}/lifecycle-marker")" == first ]] ||
	fail "the traces are not visible again after the trace folder was restored"
pass "restoring the host folder brings the traces back"

echo "All ${TESTS} lifecycle checks passed for ${KIT}."
