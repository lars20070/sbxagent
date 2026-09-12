#!/usr/bin/env bash
# Exercises the kits' shared link-state.sh helper against temporary
# directories, so its migration and rollback branches are proven on the host
# rather than only by attaching a live sandbox.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="${ROOT}/kits/sbxclaude/files/home/.local/lib/sbxagent/link-state.sh"
REAL_CP="$(command -v cp)"
REAL_MV="$(command -v mv)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/link-state-test.XXXXXX")"
TESTS=0

cleanup() {
	# u+rwx, not u+w: removing an entry needs execute on its directory too, so
	# a mode-000 fixture left behind by a failing case is undeletable without
	# it, and BSD rm reports that as an error where GNU rm quietly copes.
	chmod -R u+rwx "${TEST_ROOT}" 2>/dev/null || true
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

# Reveal a distinct underlying directory when the helper unmounts LINK.
# A real umount detaches the whole filesystem regardless of the permissions of
# anything on it, so the stub has to widen modes before deleting: an unreadable
# lost+found is removed by GNU rm but refused by BSD rm, which would otherwise
# leave it behind on macOS only and diverge from a real unmount.
fake_mount() {
	FAKE_BIN="${CASE}/bin"
	mkdir -p "${FAKE_BIN}"
	printf '#!/bin/sh\nexit 0\n' >"${FAKE_BIN}/mountpoint"
	cat >"${FAKE_BIN}/sudo" <<'SH'
#!/bin/sh
set -eu
chmod -R u+rwx "$3" 2>/dev/null || true
rm -rf "$3"
mkdir -p "$3"
echo underlying >"$3/underlying-marker"
SH
	chmod +x "${FAKE_BIN}/mountpoint" "${FAKE_BIN}/sudo"
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

# 10. A generic mv failure, unrelated to any mount, gets the same clean
#     rollback as a failed copy or a failed symlink instead of aborting with
#     set -eu's raw mv stderr.
fresh mv-fails
FAKE_BIN="${CASE}/bin"
mkdir -p "${FAKE_BIN}" "${LINK}"
echo one >"${LINK}/file"
printf '#!/bin/sh\nexit 1\n' >"${FAKE_BIN}/mv"
chmod +x "${FAKE_BIN}/mv"
PATH="${FAKE_BIN}:${PATH}" run_helper "${LINK}" sessions
assert_eq 1 "${STATUS}" "mv fails exit status"
[[ -d "${LINK}" && ! -L "${LINK}" ]] || fail "mv fails: original directory changed"
assert_eq one "$(<"${LINK}/file")" "mv fails: original contents"
[[ ! -e "${LINK}.sbxagent-aside" ]] || fail "mv fails: aside created"
[[ "${STDERR}" == *"left untouched"* ]] || fail "mv fails: stderr was '${STDERR}'"
pass "a failed mv leaves the original directory untouched with a clean diagnostic"

# 11. LINK is a separate mount (the claude parent kit's real setup, not a
#     plain directory): it is unmounted and then migrated exactly like an
#     ordinary directory, ending up linked the same way.
fresh mount-happy
mkdir -p "${LINK}"
echo one >"${LINK}/file"
FAKE_BIN="${CASE}/bin"
mkdir -p "${FAKE_BIN}"
printf '#!/bin/sh\nexit 0\n' >"${FAKE_BIN}/mountpoint"
chmod +x "${FAKE_BIN}/mountpoint"
# shellcheck disable=SC2016 # $3 is meant to expand when the fake script runs, not here.
printf '#!/bin/sh\nfind "$3" -mindepth 1 -exec rm -rf {} +\nexit 0\n' >"${FAKE_BIN}/sudo"
chmod +x "${FAKE_BIN}/sudo"
PATH="${FAKE_BIN}:${PATH}" run_helper "${LINK}" sessions
assert_eq 0 "${STATUS}" "mount happy path exit status"
[[ -L "${LINK}" ]] || fail "mount happy path: not a symlink afterwards"
assert_eq "${STATE}/sessions" "$(readlink "${LINK}")" "mount happy path target"
assert_eq one "$(<"${LINK}/file")" "mount happy path migrated file"
[[ ! -e "${LINK}.sbxagent-aside" ]] || fail "mount happy path: aside left behind"
pass "a mounted trace folder is unmounted and migrated like an ordinary directory"

# 12. If unmounting fails, LINK is left mounted and untouched -- nothing
#     destructive has happened yet.
fresh mount-umount-fails
mkdir -p "${LINK}"
echo one >"${LINK}/file"
FAKE_BIN="${CASE}/bin"
mkdir -p "${FAKE_BIN}"
printf '#!/bin/sh\nexit 0\n' >"${FAKE_BIN}/mountpoint"
chmod +x "${FAKE_BIN}/mountpoint"
printf '#!/bin/sh\nexit 1\n' >"${FAKE_BIN}/sudo"
chmod +x "${FAKE_BIN}/sudo"
PATH="${FAKE_BIN}:${PATH}" run_helper "${LINK}" sessions
assert_eq 1 "${STATUS}" "umount fails exit status"
[[ -d "${LINK}" && ! -L "${LINK}" ]] || fail "umount fails: original directory changed"
assert_eq one "$(<"${LINK}/file")" "umount fails: original contents"
[[ "${STDERR}" == *"left mounted and untouched"* ]] || fail "umount fails: stderr was '${STDERR}'"
pass "a failed unmount leaves the mount and its contents untouched"

# 13. What unmounting reveals underneath merges in via the same
#     last-write-wins collision policy as any other directory migration
#     (case 5's "sandbox's copy wins" rule is symmetric: whichever copy
#     lands last in the target wins). This is a known, low-probability edge
#     case, not specially defended against -- see the plan's Fix section.
fresh mount-underlying-collision
mkdir -p "${LINK}"
echo current >"${LINK}/transcript"
FAKE_BIN="${CASE}/bin"
mkdir -p "${FAKE_BIN}"
printf '#!/bin/sh\nexit 0\n' >"${FAKE_BIN}/mountpoint"
chmod +x "${FAKE_BIN}/mountpoint"
# shellcheck disable=SC2016 # $3 is meant to expand when the fake script runs, not here.
printf '#!/bin/sh\nfind "$3" -mindepth 1 -exec rm -rf {} +\necho old >"$3/transcript"\nexit 0\n' >"${FAKE_BIN}/sudo"
chmod +x "${FAKE_BIN}/sudo"
PATH="${FAKE_BIN}:${PATH}" run_helper "${LINK}" sessions
assert_eq 0 "${STATUS}" "underlying collision exit status"
[[ -L "${LINK}" ]] || fail "underlying collision: not a symlink afterwards"
assert_eq old "$(<"${STATE}/sessions/transcript")" "underlying collision: last-copied content wins"
pass "content revealed by unmounting merges via the existing last-write-wins policy"

# 14. A mount that fails to link after being unmounted must still leave the
#     traces reachable at the stock path. Rolling back only restores the
#     bare mount point revealed by unmounting -- the traces themselves are
#     on the now-unmounted volume, which may not be remountable -- so they
#     are copied back out of the target. The fake unmount therefore has to
#     reveal a genuinely distinct underlying directory, or it would hide
#     exactly the case this guards.
fresh mount-ln-fails
mkdir -p "${LINK}"
echo one >"${LINK}/file"
FAKE_BIN="${CASE}/bin"
mkdir -p "${FAKE_BIN}"
printf '#!/bin/sh\nexit 0\n' >"${FAKE_BIN}/mountpoint"
chmod +x "${FAKE_BIN}/mountpoint"
# shellcheck disable=SC2016 # $3 is meant to expand when the fake script runs, not here.
printf '#!/bin/sh\nfind "$3" -mindepth 1 -exec rm -rf {} +\necho underlying >"$3/underlying-marker"\nexit 0\n' >"${FAKE_BIN}/sudo"
chmod +x "${FAKE_BIN}/sudo"
printf '#!/bin/sh\nexit 1\n' >"${FAKE_BIN}/ln"
chmod +x "${FAKE_BIN}/ln"
PATH="${FAKE_BIN}:${PATH}" run_helper "${LINK}" sessions
assert_eq 1 "${STATUS}" "mount ln fails exit status"
[[ -d "${LINK}" && ! -L "${LINK}" ]] || fail "mount ln fails: directory not restored"
assert_eq one "$(<"${LINK}/file")" "mount ln fails: unmounted traces reachable at the stock path"
assert_eq underlying "$(<"${LINK}/underlying-marker")" "mount ln fails: underlying directory restored"
assert_eq one "$(<"${STATE}/sessions/file")" "mount ln fails: traces also kept in the target"
[[ ! -e "${LINK}.sbxagent-aside" ]] || fail "mount ln fails: aside left behind"
[[ "${STDERR}" == *"restored"* ]] || fail "mount ln fails: stderr was '${STDERR}'"
pass "a failed symlink after unmounting leaves the traces reachable at the stock path"

# 15. An unreadable source lost+found is skipped without aborting the copy,
#     and it never touches whatever lost+found already exists in the
#     target. Root ignores mode bits, so skip there like case 8.
if [[ "$(id -u)" -eq 0 ]]; then
	echo "skip - unreadable lost+found case needs a non-root user"
else
	fresh mount-lost-found
	mkdir -p "${LINK}/lost+found" "${STATE}/sessions/lost+found"
	chmod 000 "${LINK}/lost+found"
	echo one >"${LINK}/file"
	echo existing >"${STATE}/sessions/lost+found/marker"
	fake_mount
	PATH="${FAKE_BIN}:${PATH}" run_helper "${LINK}" sessions
	assert_eq 0 "${STATUS}" "lost+found exit status"
	[[ -L "${LINK}" ]] || fail "lost+found: not a symlink afterwards"
	assert_eq one "$(<"${LINK}/file")" "lost+found: migrated file"
	assert_eq existing "$(<"${STATE}/sessions/lost+found/marker")" "lost+found: existing target entry preserved"
	pass "an unreadable source lost+found is skipped without aborting the copy or touching the target's own lost+found"
fi

# 16. An interrupted migration must be refused before either copying or
#     unmounting, so the original volume and the saved aside stay intact.
fresh mount-leftover
mkdir -p "${LINK}" "${LINK}.sbxagent-aside" "${STATE}/sessions"
echo one >"${LINK}/file"
echo stale >"${LINK}.sbxagent-aside/file"
echo existing >"${STATE}/sessions/file"
fake_mount
PATH="${FAKE_BIN}:${PATH}" run_helper "${LINK}" sessions
assert_eq 1 "${STATUS}" "mount leftover exit status"
[[ -d "${LINK}" && ! -L "${LINK}" ]] || fail "mount leftover: original directory changed"
assert_eq one "$(<"${LINK}/file")" "mount leftover: original contents"
assert_eq stale "$(<"${LINK}.sbxagent-aside/file")" "mount leftover: aside contents"
assert_eq existing "$(<"${STATE}/sessions/file")" "mount leftover: target contents"
[[ ! -e "${LINK}/underlying-marker" ]] || fail "mount leftover: unmount was attempted"
[[ "${STDERR}" == *"interrupted run"* ]] || fail "mount leftover: stderr was '${STDERR}'"
pass "a leftover aside prevents copying and unmounting a mounted trace folder"

# 17-18. Both the underlying-directory copy and the rename can fail after
#        unmounting. In either case the traces must be restored before the
#        agent continues, and a retry must preserve any subsequent writes.
for failed_step in copy move; do
	fresh "mount-${failed_step}-fails"
	mkdir -p "${LINK}/nested"
	echo one >"${LINK}/file"
	echo hidden >"${LINK}/.dotfile"
	echo nested >"${LINK}/nested/trace"
	fake_mount
	if [[ "${failed_step}" == copy ]]; then
		cat >"${FAKE_BIN}/cp" <<'SH'
#!/bin/sh
if [ "$2" = "${LINK_STATE_COPY_SOURCE}" ]; then exit 1; fi
exec "${LINK_STATE_REAL_CP}" "$@"
SH
		chmod +x "${FAKE_BIN}/cp"
	else
		printf '#!/bin/sh\nexit 1\n' >"${FAKE_BIN}/mv"
		chmod +x "${FAKE_BIN}/mv"
	fi
	LINK_STATE_COPY_SOURCE="${LINK}/." LINK_STATE_REAL_CP="${REAL_CP}" \
		PATH="${FAKE_BIN}:${PATH}" run_helper "${LINK}" sessions
	assert_eq 1 "${STATUS}" "mount ${failed_step} fails exit status"
	[[ -d "${LINK}" && ! -L "${LINK}" ]] || fail "mount ${failed_step} fails: stock directory missing"
	assert_eq one "$(<"${LINK}/file")" "mount ${failed_step} fails: restored traces"
	assert_eq hidden "$(<"${LINK}/.dotfile")" "mount ${failed_step} fails: restored dotfile"
	assert_eq nested "$(<"${LINK}/nested/trace")" "mount ${failed_step} fails: restored nested trace"
	assert_eq underlying "$(<"${LINK}/underlying-marker")" "mount ${failed_step} fails: underlying contents"
	assert_eq one "$(<"${STATE}/sessions/file")" "mount ${failed_step} fails: saved traces"
	[[ ! -e "${LINK}.sbxagent-aside" ]] || fail "mount ${failed_step} fails: aside left behind"
	[[ "${STDERR}" == *"could not ${failed_step}"* && "${STDERR}" == *"traces restored"* ]] ||
		fail "mount ${failed_step} fails: stderr was '${STDERR}'"
	echo two >>"${LINK}/file"
	run_helper "${LINK}" sessions
	assert_eq 0 "${STATUS}" "mount ${failed_step} fails: retry exit status"
	[[ -L "${LINK}" ]] || fail "mount ${failed_step} fails: retry did not link"
	assert_eq "$(printf 'one\ntwo')" "$(<"${STATE}/sessions/file")" "mount ${failed_step} fails: retry preserved new writes"
	pass "a failed ${failed_step} after unmounting restores traces and permits retry"
done

# 19. If copying the saved traces back also fails, report their surviving
#     location instead of claiming that the original contents were restored.
fresh mount-restore-copy-fails
mkdir -p "${LINK}"
echo one >"${LINK}/file"
fake_mount
cat >"${FAKE_BIN}/cp" <<'SH'
#!/bin/sh
if [ "$2" = "${LINK_STATE_COPY_SOURCE}" ]; then exit 1; fi
exec "${LINK_STATE_REAL_CP}" "$@"
SH
printf '#!/bin/sh\nexit 1\n' >"${FAKE_BIN}/ln"
chmod +x "${FAKE_BIN}/cp" "${FAKE_BIN}/ln"
LINK_STATE_COPY_SOURCE="${STATE}/sessions/." LINK_STATE_REAL_CP="${REAL_CP}" \
	PATH="${FAKE_BIN}:${PATH}" run_helper "${LINK}" sessions
assert_eq 1 "${STATUS}" "restore copy fails exit status"
assert_eq one "$(<"${STATE}/sessions/file")" "restore copy fails: saved traces"
assert_eq underlying "$(<"${LINK}/underlying-marker")" "restore copy fails: underlying directory restored"
[[ ! -e "${LINK}/file" ]] || fail "restore copy fails: failure was not exercised"
[[ ! -e "${LINK}.sbxagent-aside" ]] || fail "restore copy fails: aside left behind"
[[ "${STDERR}" == *"could not restore"* && "${STDERR}" == *"remain in ${STATE}/sessions"* ]] ||
	fail "restore copy fails: stderr was '${STDERR}'"
[[ "${STDERR}" != *"traces restored"* && "${STDERR}" != *"left untouched"* ]] ||
	fail "restore copy fails: misleading diagnostic '${STDERR}'"
pass "a failed trace restore reports the surviving state copy"

# 20. A failed rename during rollback also names the saved directories and
#     keeps them intact, rather than aborting with only the raw mv error.
fresh mount-restore-move-fails
mkdir -p "${LINK}"
echo one >"${LINK}/file"
fake_mount
cat >"${FAKE_BIN}/mv" <<'SH'
#!/bin/sh
if [ "$1" = "${LINK_STATE_MOVE_SOURCE}" ]; then exit 1; fi
exec "${LINK_STATE_REAL_MV}" "$@"
SH
printf '#!/bin/sh\nexit 1\n' >"${FAKE_BIN}/ln"
chmod +x "${FAKE_BIN}/mv" "${FAKE_BIN}/ln"
LINK_STATE_MOVE_SOURCE="${LINK}.sbxagent-aside" LINK_STATE_REAL_MV="${REAL_MV}" \
	PATH="${FAKE_BIN}:${PATH}" run_helper "${LINK}" sessions
assert_eq 1 "${STATUS}" "restore move fails exit status"
assert_eq one "$(<"${STATE}/sessions/file")" "restore move fails: saved traces"
assert_eq underlying "$(<"${LINK}.sbxagent-aside/underlying-marker")" "restore move fails: aside preserved"
[[ ! -e "${LINK}" ]] || fail "restore move fails: failure was not exercised"
[[ "${STDERR}" == *"could not restore ${LINK}.sbxagent-aside"* && "${STDERR}" == *"remain in ${STATE}/sessions"* ]] ||
	fail "restore move fails: stderr was '${STDERR}'"
pass "a failed rollback rename reports and preserves the saved directories"

echo "All ${TESTS} link-state tests passed."
