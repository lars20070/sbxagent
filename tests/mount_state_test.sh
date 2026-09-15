#!/usr/bin/env bash
# Exercises the kits' shared mount-state.sh helper against temporary
# directories, so its merge and idempotency branches are proven on the
# host rather than only by attaching a live sandbox.
#
# Two cases need a real bind mount, which only Linux can do and only with
# password-free sudo. They are gated on a capability probe rather than an OS
# name (see AGENTS.md: probe, never branch on the OS) and skip loudly
# otherwise. Set SBXAGENT_REQUIRE_BIND=1 to turn that skip into a failure; CI
# sets it on the Linux runner so the two cases cannot go uncovered everywhere
# at once. Everything else runs on any host, with sudo stubbed out.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="${ROOT}/kits/sbxclaude/files/home/.local/lib/sbxagent/mount-state.sh"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/mount-state-test.XXXXXX")"
TESTS=0

# Anything still bind-mounted under TEST_ROOT has to be detached before the
# tree is deleted: rm -rf through a live bind mount deletes the content on the
# other side of it. Sweeping mountinfo rather than tracking mounts by hand also
# covers a case that failed partway through and left one behind. Deepest path
# first, and repeated, so a stack of mounts unwinds.
unmount_all() {
	local pass_number mount_point
	[[ -r /proc/self/mountinfo ]] || return 0
	for pass_number in 1 2 3; do
		: "${pass_number}"
		while read -r mount_point; do
			sudo -n umount "${mount_point}" 2>/dev/null || true
		done < <(awk '{ print $5 }' /proc/self/mountinfo |
			grep -F "${TEST_ROOT}/" | awk '{ print length, $0 }' |
			sort -rn | cut -d' ' -f2-)
	done
}

cleanup() {
	unmount_all
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

# A case that cannot run here. Refused outright when the caller demanded the
# real thing, so a runner that quietly lost the ability to mount cannot look
# identical to a fully green one.
skip() {
	[[ -z "${SBXAGENT_REQUIRE_BIND:-}" ]] ||
		fail "$* — but SBXAGENT_REQUIRE_BIND is set, so it may not be skipped"
	echo "skip - $*"
}

assert_eq() {
	local expected="$1"
	local actual="$2"
	local context="$3"
	[[ "${actual}" == "${expected}" ]] ||
		fail "${context}: expected '${expected}', got '${actual}'"
}

# How many mounts are stacked at exactly this path. Zero where there is no
# mountinfo to read, which is every host that cannot bind-mount anyway.
mount_count() {
	[[ -r /proc/self/mountinfo ]] || { echo 0; return 0; }
	awk -v path="$1" '$5 == path { total++ } END { print total + 0 }' \
		/proc/self/mountinfo
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

# A sudo that reports success without mounting anything, for the cases that
# only care about what happened before the bind.
stub_sudo_ok() {
	FAKE_BIN="${CASE}/bin"
	mkdir -p "${FAKE_BIN}"
	printf '#!/bin/sh\nexit 0\n' >"${FAKE_BIN}/sudo"
	chmod +x "${FAKE_BIN}/sudo"
}

# Can this host actually bind-mount? Inlined rather than wrapped in a function
# so a false answer stays an ordinary condition under set -e.
BIND_AVAILABLE=no
mkdir -p "${TEST_ROOT}/bind-probe/src" "${TEST_ROOT}/bind-probe/dst"
if sudo -n mount --bind "${TEST_ROOT}/bind-probe/src" \
	"${TEST_ROOT}/bind-probe/dst" 2>/dev/null; then
	sudo -n umount "${TEST_ROOT}/bind-probe/dst" 2>/dev/null || true
	BIND_AVAILABLE=yes
fi

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

# 2. First bind, from nothing at all: neither the trace directory nor its
#    parents exist. `mount --bind` will not create its own destination, so the
#    helper has to, and the pi kit really does start out this way.
if [[ "${BIND_AVAILABLE}" == yes ]]; then
	fresh first
	LINK="${CASE}/home/agent/.pi/agent/sessions"
	run_helper "${LINK}" sessions
	assert_eq 0 "${STATUS}" "first bind exit status"
	[[ -d "${LINK}" && ! -L "${LINK}" ]] || fail "first bind: not a real directory"
	assert_eq "$(stat -c '%d:%i' "${STATE}/sessions")" \
		"$(stat -c '%d:%i' "${LINK}")" "first bind: device and inode"
	echo one >"${LINK}/trace"
	assert_eq one "$(<"${STATE}/sessions/trace")" "first bind: write reaches state"

	# 3. Running again finds itself already bound: no second mount stacked on
	#    top, and nothing copied back over what the agent has since written.
	assert_eq 1 "$(mount_count "${LINK}")" "repeat: baseline mount count"
	run_helper "${LINK}" sessions
	assert_eq 0 "${STATUS}" "repeat exit status"
	assert_eq 1 "$(mount_count "${LINK}")" "repeat: mount count did not grow"
	assert_eq one "$(<"${STATE}/sessions/trace")" "repeat: target contents changed"
	pass "first run binds a missing trace path and a repeat run is idempotent"
	unmount_all
else
	skip "first-bind and idempotency cases need a working 'sudo -n mount --bind'"
fi

# 4. Host state is authoritative. A name it already holds is never overwritten
#    by whatever is at the stock path — a re-provisioned parent volume, or a
#    rebuilt sandbox's freshly seeded files — while names it lacks are merged
#    in, dotfiles and nested directories included.
fresh merge
mkdir -p "${STATE}/sessions/shared" "${LINK}/shared" "${LINK}/nested"
echo host >"${STATE}/sessions/shared/trace"
echo keep >"${STATE}/sessions/only-in-state"
echo stale >"${LINK}/shared/trace"
echo seeded >"${LINK}/fresh"
echo hidden >"${LINK}/.dotfile"
echo deep >"${LINK}/nested/trace"
stub_sudo_ok
PATH="${FAKE_BIN}:${PATH}" run_helper "${LINK}" sessions
assert_eq 0 "${STATUS}" "merge exit status"
assert_eq host "$(<"${STATE}/sessions/shared/trace")" "merge: host entry preserved"
assert_eq keep "$(<"${STATE}/sessions/only-in-state")" "merge: state-only entry"
assert_eq seeded "$(<"${STATE}/sessions/fresh")" "merge: new name merged in"
assert_eq hidden "$(<"${STATE}/sessions/.dotfile")" "merge: dotfile merged in"
assert_eq deep "$(<"${STATE}/sessions/nested/trace")" "merge: nested file merged in"
pass "host state wins on a name clash and gaps are filled from the stock path"

# 5. An unreadable source lost+found is skipped without aborting the copy, and
#    never touches whatever lost+found the target already has. Root ignores
#    mode bits, so there is nothing to exercise there.
if [[ "$(id -u)" -eq 0 ]]; then
	echo "skip - unreadable lost+found case needs a non-root user"
else
	fresh lost-found
	mkdir -p "${LINK}/lost+found" "${STATE}/sessions/lost+found"
	chmod 000 "${LINK}/lost+found"
	echo one >"${LINK}/trace"
	echo existing >"${STATE}/sessions/lost+found/marker"
	stub_sudo_ok
	PATH="${FAKE_BIN}:${PATH}" run_helper "${LINK}" sessions
	assert_eq 0 "${STATUS}" "lost+found exit status"
	assert_eq one "$(<"${STATE}/sessions/trace")" "lost+found: other files still copied"
	assert_eq existing "$(<"${STATE}/sessions/lost+found/marker")" \
		"lost+found: existing target entry preserved"
	pass "an unreadable source lost+found is skipped without aborting the copy"
fi

# 6. A failed bind is fatal, with nothing left half-done. The agent must not
#    reach an unbound stock path: traces written there die with the sandbox,
#    and no later boot would find them to migrate.
fresh bind-fails
mkdir -p "${LINK}"
echo one >"${LINK}/trace"
FAKE_BIN="${CASE}/bin"
mkdir -p "${FAKE_BIN}"
printf '#!/bin/sh\nexit 1\n' >"${FAKE_BIN}/sudo"
chmod +x "${FAKE_BIN}/sudo"
PATH="${FAKE_BIN}:${PATH}" run_helper "${LINK}" sessions
assert_eq 1 "${STATUS}" "bind fails exit status"
[[ "${STDERR}" == *"could not bind-mount"* ]] || fail "bind fails: stderr was '${STDERR}'"
assert_eq one "$(<"${STATE}/sessions/trace")" "bind fails: traces were still copied"
pass "a failed bind is fatal rather than a silent fallback to the stock path"

# 7. A failed copy is fatal too, before anything is mounted. A read-only target
#    denies the copy for a normal user; root ignores mode bits, so skip there.
if [[ "$(id -u)" -eq 0 ]]; then
	echo "skip - copy failure case needs a non-root user"
else
	fresh copy-fails
	mkdir -p "${STATE}/sessions" "${LINK}"
	echo one >"${LINK}/trace"
	chmod 555 "${STATE}/sessions"
	stub_sudo_ok
	PATH="${FAKE_BIN}:${PATH}" run_helper "${LINK}" sessions
	assert_eq 1 "${STATUS}" "copy fails exit status"
	[[ "${STDERR}" == *"could not copy"* ]] || fail "copy fails: stderr was '${STDERR}'"
	pass "a failed copy is fatal before anything is mounted"
fi

# 8-11. Exercise the actual entrypoint shell blocks from every kit spec. There
# is no soft failure mode left: any non-zero status from the helper has to stop
# the agent from starting, because every one of them means traces would
# otherwise be written somewhere that does not reach the state folder.
for kit in sbxclaude sbxcodex sbxcursor sbxpi; do
	SPEC="${ROOT}/kits/${kit}/spec.yaml"
	ENTRYPOINT="$(awk '
		$0 == "    - |" { block = 1; next }
		block && /^    - / { exit }
		block { sub(/^      /, ""); print }
	' "${SPEC}")"
	case "${kit}" in
	sbxclaude) agent=claude ;;
	sbxcodex) agent=codex ;;
	sbxcursor) agent=agent ;;
	sbxpi) agent=pi ;;
	*) fail "unknown kit in entrypoint test: ${kit}" ;;
	esac

	fresh "entrypoint-${kit}"
	FAKE_HOME="${CASE}/home/agent"
	FAKE_BIN="${CASE}/bin"
	AGENT_LOG="${CASE}/agent.log"
	mkdir -p "${FAKE_HOME}/.local/lib/sbxagent" "${FAKE_BIN}"
	cat >"${FAKE_HOME}/.local/lib/sbxagent/mount-state.sh" <<'SH'
#!/bin/sh
exit "${MOUNT_STATE_TEST_STATUS}"
SH
	cat >"${FAKE_BIN}/${agent}" <<'SH'
#!/bin/sh
printf '%s\n' "$0" >>"${ENTRYPOINT_AGENT_LOG}"
SH
	chmod +x "${FAKE_HOME}/.local/lib/sbxagent/mount-state.sh" "${FAKE_BIN}/${agent}"

	: >"${AGENT_LOG}"
	MOUNT_STATE_TEST_STATUS=0 ENTRYPOINT_AGENT_LOG="${AGENT_LOG}" HOME="${FAKE_HOME}" \
		PATH="${FAKE_BIN}:${PATH}" sh -c "${ENTRYPOINT}" "${kit}-entrypoint"
	[[ -s "${AGENT_LOG}" ]] || fail "${kit} success: agent was not launched"

	: >"${AGENT_LOG}"
	set +e
	MOUNT_STATE_TEST_STATUS=1 \
		ENTRYPOINT_AGENT_LOG="${AGENT_LOG}" HOME="${FAKE_HOME}" \
		PATH="${FAKE_BIN}:${PATH}" sh -c "${ENTRYPOINT}" "${kit}-entrypoint" \
		2>"${CASE}/stderr-1"
	STATUS=$?
	set -e
	STDERR="$(<"${CASE}/stderr-1")"
	assert_eq 1 "${STATUS}" "${kit} status 1: exit status"
	[[ ! -s "${AGENT_LOG}" ]] ||
		fail "${kit} status 1: agent was launched anyway"
	[[ "${STDERR}" == *"refusing to start ${agent}"* ]] ||
		fail "${kit} status 1: stderr was '${STDERR}'"
	pass "${kit} entrypoint launches only when the trace path is relocated"
done

# 12. Both call sites exist in every kit. The bind does not survive a stop, so
# it has to be re-made on every start, and neither call site alone reaches every
# start: the entrypoint is the agent launch command, so it never runs for a
# `sbx exec` session or a sandbox that is started but not attached; the startup
# step does run per start but is known not to replay after a daemon restart
# (docker/sbx-releases #420) or when `sbx exec` starts a stopped sandbox (#479).
# Dropping either one reintroduces a silent hole — traces written to an unbound
# stock path, with no error, lost when the sandbox goes away — so assert both
# are present rather than trusting a comment to keep them there.
fresh "call-sites"
for kit in sbxclaude sbxcodex sbxcursor sbxpi; do
	SPEC="${ROOT}/kits/${kit}/spec.yaml"
	# shellcheck disable=SC2016 # $HOME is literal here: these strings are
	# matched against the spec's own text, which must keep it unexpanded so it
	# resolves inside the sandbox rather than on this machine.
	case "${kit}" in
	sbxclaude) trace_path='$HOME/.claude/projects'; subdir=projects ;;
	sbxcodex) trace_path='$HOME/.codex/sessions'; subdir=sessions ;;
	sbxcursor) trace_path='$HOME/.cursor/projects'; subdir=projects ;;
	sbxpi) trace_path='$HOME/.pi/agent/sessions'; subdir=sessions ;;
	*) fail "unknown kit in call-site test: ${kit}" ;;
	esac

	# Exactly two invocations: one per call site. More would mean a duplicate
	# nobody intended; fewer means one was dropped.
	CALLS="$(grep -c 'lib/sbxagent/mount-state\.sh' "${SPEC}" || true)"
	assert_eq 2 "${CALLS}" "${kit}: mount-state.sh invocations in spec.yaml"

	# The startup block, isolated so a match cannot come from the entrypoint.
	STARTUP="$(awk '
		$0 == "  startup:" { block = 1; next }
		block && /^  [^ ]/ { exit }
		block { print }
	' "${SPEC}")"
	[[ -n "${STARTUP}" ]] ||
		fail "${kit}: spec.yaml has no 'setup: startup:' block"
	[[ "${STARTUP}" == *"lib/sbxagent/mount-state.sh"* ]] ||
		fail "${kit}: the startup block does not call mount-state.sh"
	[[ "${STARTUP}" == *"\"${trace_path}\" ${subdir}"* ]] ||
		fail "${kit}: the startup call does not pass ${trace_path} and ${subdir}"
	# As the agent user, or the bind lands with root-owned traces the agent
	# cannot then write to.
	[[ "${STARTUP}" == *'user: "agent"'* ]] ||
		fail "${kit}: the startup block does not run as the agent user"
done
pass "every kit calls mount-state.sh from both the entrypoint and a startup step"

echo "All ${TESTS} mount-state tests passed."
