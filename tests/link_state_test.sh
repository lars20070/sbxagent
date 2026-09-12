#!/usr/bin/env bash
# Exercises the kits' shared link-state.sh helper against temporary
# directories, so its migration and rollback branches are proven on the host
# rather than only by attaching a live sandbox.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="${ROOT}/kits/sbxclaude/files/home/.local/lib/sbxagent/link-state.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/link-state-test.XXXXXX")"
TESTS=0

cleanup() {
	chmod -R u+w "${TEST_ROOT}" 2>/dev/null || true
	rm -rf "${TEST_ROOT}"
}
trap cleanup EXIT

fail() {
	echo "not ok - $*" >&2
	exit 1
}

pass() {
	TESTS=$((TESTS + 1))
	echo "ok ${TESTS} - $*"
}

assert_eq() {
	local expected="$1"
	local actual="$2"
	local context="$3"
	[[ "${actual}" == "${expected}" ]] ||
		fail "${context}: expected '${expected}', got '${actual}'"
}

# Runs the helper the way the kit entrypoints do, capturing stderr and the
# exit status without tripping set -e.
STDERR=""
STATUS=0
run_helper() {
	local stderr_file="${TEST_ROOT}/stderr"
	set +e
	sh "${HELPER}" "$@" 2>"${stderr_file}"
	STATUS=$?
	set -e
	STDERR="$(<"${stderr_file}")"
}

# Each case gets a fresh state root and link parent.
fresh() {
	local name="$1"
	CASE="${TEST_ROOT}/${name}"
	STATE="${CASE}/state"
	LINK="${CASE}/home/agent/sessions"
	mkdir -p "${CASE}/home/agent"
	export SBXAGENT_STATE_DIR="${STATE}"
}

# 1. Without the variable the helper is a no-op, so a sandbox created by
#    plain `sbx run` keeps the agent's stock location.
fresh no-env
unset SBXAGENT_STATE_DIR
mkdir -p "${LINK}"
run_helper "${LINK}" sessions
assert_eq 0 "${STATUS}" "no env exit status"
[[ -d "${LINK}" && ! -L "${LINK}" ]] || fail "no env: link path was changed"
[[ ! -e "${STATE}" ]] || fail "no env: state root was created"
pass "no SBXAGENT_STATE_DIR is a no-op"

# 2. First link: nothing at the path, parent absent.
fresh first
LINK="${CASE}/home/agent/.codex/sessions"
run_helper "${LINK}" sessions
assert_eq 0 "${STATUS}" "first link exit status"
[[ -L "${LINK}" ]] || fail "first link: not a symlink"
assert_eq "${STATE}/sessions" "$(readlink "${LINK}")" "first link target"
[[ -d "${STATE}/sessions" ]] || fail "first link: target dir missing"
pass "first run creates the target and the symlink"

# 3. Running again is a no-op.
: >"${STATE}/sessions/marker"
run_helper "${LINK}" sessions
assert_eq 0 "${STATUS}" "repeat exit status"
assert_eq "${STATE}/sessions" "$(readlink "${LINK}")" "repeat target"
[[ -f "${STATE}/sessions/marker" ]] || fail "repeat: target contents changed"
[[ ! -e "${LINK}.sbxagent-aside" ]] || fail "repeat: aside left behind"
pass "repeat run is idempotent"

# 4. A real directory (the cursor parent kit seeds one) is migrated: contents
#    copied in, including dotfiles and nested dirs, then replaced by the link.
fresh migrate
mkdir -p "${LINK}/nested"
echo one >"${LINK}/file"
echo two >"${LINK}/.dotfile"
echo three >"${LINK}/nested/inner"
run_helper "${LINK}" sessions
assert_eq 0 "${STATUS}" "migrate exit status"
[[ -L "${LINK}" ]] || fail "migrate: not a symlink afterwards"
assert_eq one "$(<"${LINK}/file")" "migrated file"
assert_eq two "$(<"${LINK}/.dotfile")" "migrated dotfile"
assert_eq three "$(<"${LINK}/nested/inner")" "migrated nested file"
[[ ! -e "${LINK}.sbxagent-aside" ]] || fail "migrate: aside left behind"
pass "a real directory is merged into the target and replaced by the link"

# 5. Collision policy: the sandbox's copy wins over what is already in the
#    state folder (a sandbox re-created after rm), and files only in the
#    state folder survive.
fresh collide
mkdir -p "${STATE}/sessions/a" "${LINK}/a"
echo old >"${STATE}/sessions/a/x"
echo keep >"${STATE}/sessions/only-in-state"
echo new >"${LINK}/a/x"
run_helper "${LINK}" sessions
assert_eq 0 "${STATUS}" "collide exit status"
assert_eq new "$(<"${LINK}/a/x")" "collision winner"
assert_eq keep "$(<"${LINK}/only-in-state")" "state-only file"
pass "on a name clash the sandbox's copy wins and the rest is merged"

# 6. A symlink to anything else is refused and left alone; the target dir is
#    not even created, since the check runs before mkdir.
fresh other-link
mkdir -p "${CASE}/elsewhere"
ln -s "${CASE}/elsewhere" "${LINK}"
run_helper "${LINK}" sessions
assert_eq 1 "${STATUS}" "other link exit status"
assert_eq "${CASE}/elsewhere" "$(readlink "${LINK}")" "other link untouched"
[[ ! -e "${STATE}" ]] || fail "other link: state root was created"
[[ "${STDERR}" == *"left untouched"* ]] || fail "other link: stderr was '${STDERR}'"
pass "an unexpected symlink is refused and left untouched"

# 7. If the symlink cannot be created, the renamed-aside directory is put
#    back, so the agent's stock location is intact.
fresh ln-fails
FAKE_BIN="${CASE}/bin"
mkdir -p "${FAKE_BIN}" "${LINK}"
echo one >"${LINK}/file"
printf '#!/bin/sh\nexit 1\n' >"${FAKE_BIN}/ln"
chmod +x "${FAKE_BIN}/ln"
PATH="${FAKE_BIN}:${PATH}" run_helper "${LINK}" sessions
assert_eq 1 "${STATUS}" "ln fails exit status"
[[ -d "${LINK}" && ! -L "${LINK}" ]] || fail "ln fails: original directory not restored"
assert_eq one "$(<"${LINK}/file")" "ln fails: original contents"
[[ ! -e "${LINK}.sbxagent-aside" ]] || fail "ln fails: aside left behind"
[[ "${STDERR}" == *"restored"* ]] || fail "ln fails: stderr was '${STDERR}'"
pass "a failed symlink restores the original directory"

# 8. If the copy fails, nothing has been moved yet. A read-only target denies
#    the copy for a normal user; root ignores mode bits, so skip there.
if [[ "$(id -u)" -eq 0 ]]; then
	echo "skip - copy failure case needs a non-root user"
else
	fresh cp-fails
	mkdir -p "${STATE}/sessions" "${LINK}"
	echo one >"${LINK}/file"
	chmod 555 "${STATE}/sessions"
	run_helper "${LINK}" sessions
	assert_eq 1 "${STATUS}" "cp fails exit status"
	[[ -d "${LINK}" && ! -L "${LINK}" ]] || fail "cp fails: original directory changed"
	assert_eq one "$(<"${LINK}/file")" "cp fails: original contents"
	[[ ! -e "${LINK}.sbxagent-aside" ]] || fail "cp fails: aside left behind"
	[[ "${STDERR}" == *"left untouched"* ]] || fail "cp fails: stderr was '${STDERR}'"
	pass "a failed copy leaves the original directory untouched"
fi

# 9. A leftover aside from an interrupted run is never overwritten.
fresh leftover
mkdir -p "${LINK}" "${LINK}.sbxagent-aside"
echo one >"${LINK}/file"
echo stale >"${LINK}.sbxagent-aside/file"
run_helper "${LINK}" sessions
assert_eq 1 "${STATUS}" "leftover exit status"
[[ -d "${LINK}" && ! -L "${LINK}" ]] || fail "leftover: original directory changed"
assert_eq stale "$(<"${LINK}.sbxagent-aside/file")" "leftover aside contents"
[[ "${STDERR}" == *"interrupted run"* ]] || fail "leftover: stderr was '${STDERR}'"
pass "a leftover aside directory is refused, not overwritten"

echo "All ${TESTS} link-state tests passed."
