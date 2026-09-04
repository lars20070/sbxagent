#!/usr/bin/env bash
# Exercises the wrapper's dispatch against a fake `sbx` on PATH that logs its
# argv, so behavior is checked without touching a real sandbox.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Invoke through the symlink, not scripts/sbxagent, so every assertion below
# goes through basename dispatch the same way an installed wrapper does.
CLAUDE_SCRIPT="${ROOT}/scripts/sbxclaude"
CODEX_SCRIPT="${ROOT}/scripts/sbxcodex"
CURSOR_SCRIPT="${ROOT}/scripts/sbxcursor"
PI_SCRIPT="${ROOT}/scripts/sbxpi"
# The real script, which must refuse to run under its own name.
AGENT_SCRIPT="${ROOT}/scripts/sbxagent"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sbxagent-test.XXXXXX")"
FAKE_BIN="${TEST_ROOT}/bin"
SBX_LOG="${TEST_ROOT}/sbx.log"
TESTS=0
EXPECTED_VERSION="$(grep -m1 -oE '[0-9]+\.[0-9]+\.[0-9]+' "${ROOT}/VERSION")"

cleanup() {
	rm -rf "${TEST_ROOT}"
}
trap cleanup EXIT

fail() {
	echo "not ok - $*" >&2
	exit 1
}

# The exec tty test drives the wrapper under a real pty via python3, and
# os.waitstatus_to_exitcode landed in 3.9. Check up front rather than failing
# obscurely most of the way through the suite.
if ! command -v python3 >/dev/null 2>&1; then
	fail "python3 is required to test the exec tty gate"
fi
if ! python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 9) else 1)'; then
	fail "python3 3.9 or newer is required (os.waitstatus_to_exitcode) to test the exec tty gate"
fi

pass() {
	TESTS=$((TESTS + 1))
	echo "ok ${TESTS} - $*"
}

clear_log() {
	: >"${SBX_LOG}"
}

assert_eq() {
	local expected="$1"
	local actual="$2"
	local context="$3"
	[[ "${actual}" == "${expected}" ]] ||
		fail "${context}: expected '${expected}', got '${actual}'"
}

assert_match() {
	local pattern="$1"
	local actual="$2"
	local context="$3"
	[[ "${actual}" =~ ${pattern} ]] ||
		fail "${context}: '${actual}' does not match /${pattern}/"
}

assert_log() {
	local expected="$1"
	local context="$2"
	local actual
	actual="$(<"${SBX_LOG}")"
	assert_eq "${expected}" "${actual}" "${context}"
}

assert_no_log() {
	local context="$1"
	[[ ! -s "${SBX_LOG}" ]] || fail "${context}: sbx was called"
}

run_claude() {
	local directory="$1"
	shift
	(cd "${directory}" && "${CLAUDE_SCRIPT}" "$@")
}

# Only the slug is reproduced here. Recomputing the digest would duplicate the
# wrapper's shasum/sha256sum fallback, so the hash is asserted by shape and the
# properties that matter — uniqueness, stability, symlink transparency — are
# covered by comparing names below.
expected_slug() {
	local directory="$1"
	local slug
	slug="$(basename "$(cd "${directory}" && pwd -P)")"
	slug="${slug//[!a-zA-Z0-9-]/-}"
	while [[ "${slug%-}" != "${slug}" ]]; do
		slug="${slug%-}"
	done
	printf '%s\n' "${slug}"
}

reject_without_call() {
	local directory="$1"
	shift
	local output
	local status
	clear_log
	set +e
	output="$(run_claude "${directory}" "$@" 2>&1)"
	status=$?
	set -e
	if [[ "${status}" -eq 0 ]]; then
		fail "'$*' unexpectedly succeeded"
	fi
	[[ -n "${output}" ]] || fail "'$*' produced no error"
	assert_no_log "'$*'"
}

# The wrapper picks its kit from the name it was invoked as. Running the real
# script directly, or a copy under an unrelated name, must refuse and explain
# how to link it — never guess an agent.
reject_wrong_name() {
	local invocation="$1"
	shift
	local label
	local output
	local status
	local expected
	label="$(basename "${invocation}")${1:+ $1}"
	clear_log
	set +e
	output="$( (cd "${WORK_A}" && "${invocation}" "$@") 2>&1 )"
	status=$?
	set -e
	[[ "${status}" -ne 0 ]] || fail "'${label}' unexpectedly succeeded"
	for expected in sbxclaude sbxcodex sbxcursor sbxpi "ln -s"; do
		[[ "${output}" == *"${expected}"* ]] ||
			fail "'${label}' did not mention '${expected}': ${output}"
	done
	assert_no_log "${label}"
}

mkdir -p "${FAKE_BIN}"
# Fake `sbx`: appends each call's argv (tab-separated) to SBX_LOG. The
# attach path probes with `sbx inspect` first, so SBX_SKIP_INSPECT_LOG lets a
# test simulate that check's result (via SBX_INSPECT_STATUS) without logging
# the probe itself, keeping assert_log focused on the calls that follow it.
cat >"${FAKE_BIN}/sbx" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "inspect" && "${SBX_SKIP_INSPECT_LOG:-0}" == "1" ]]; then
	exit "${SBX_INSPECT_STATUS:-1}"
fi

printf '%s' "${1:-}" >>"${SBX_LOG}"
for arg in "${@:2}"; do
	printf '\t%s' "${arg}" >>"${SBX_LOG}"
done
printf '\n' >>"${SBX_LOG}"
EOF
chmod +x "${FAKE_BIN}/sbx"
export PATH="${FAKE_BIN}:${PATH}"
export SBX_LOG

WORK_A="${TEST_ROOT}/one/api"
WORK_B="${TEST_ROOT}/two/api"
EMPTY_SLUG="${TEST_ROOT}/..."
LINK="${TEST_ROOT}/api-link"
mkdir -p "${WORK_A}" "${WORK_B}" "${EMPTY_SLUG}"
ln -s "${WORK_A}" "${LINK}"

# Sandbox naming: derived from the canonical directory path, so it must be
# unique per path, stable across runs, symlink-transparent, and never empty.
clear_log
NAME_A="$(run_claude "${WORK_A}" name)"
assert_match "^sbxclaude-$(expected_slug "${WORK_A}")-[0-9a-f]{6}$" "${NAME_A}" "derived name"
STABLE_NAME="$(run_claude "${WORK_A}" name)"
assert_eq "${NAME_A}" "${STABLE_NAME}" "stable name"
NAME_B="$(run_claude "${WORK_B}" name)"
[[ "${NAME_A}" != "${NAME_B}" ]] || fail "same basenames produced the same name"
LINK_NAME="$(run_claude "${LINK}" name)"
assert_eq "${NAME_A}" "${LINK_NAME}" "symlink name"
EMPTY_NAME="$(run_claude "${EMPTY_SLUG}" name)"
[[ "${EMPTY_NAME}" =~ ^sbxclaude-[0-9a-f]{6}$ ]] ||
	fail "empty sanitized basename produced invalid name '${EMPTY_NAME}'"
assert_no_log "name"
pass "name derivation is unique, stable, and canonical"

# version: reads VERSION directly, needs no sbx call.
clear_log
CLAUDE_VERSION_OUT="$(run_claude "${WORK_A}" version)"
assert_eq "sbxclaude ${EXPECTED_VERSION}" "${CLAUDE_VERSION_OUT}" "version output"
assert_no_log "version"
pass "version prints the kit name and version without calling sbx"

SANDBOX="${NAME_A}"
CLAUDE_KIT="${ROOT}/kits/sbxclaude"

# Attach: creates (validate + kit) only when the sandbox is missing, and
# re-attaches directly when it already exists. Neither call passes `--`,
# since the wrapper never forwards agent arguments.
clear_log
SBX_SKIP_INSPECT_LOG=1 SBX_INSPECT_STATUS=1 run_claude "${WORK_A}" >/dev/null
assert_log "$(printf 'kit\tvalidate\t%s\nrun\t--name\t%s\t--kit\t%s\tsbxclaude' \
	"${CLAUDE_KIT}" "${SANDBOX}" "${CLAUDE_KIT}")" "new sandbox attach"
[[ "$(<"${SBX_LOG}")" != *$'\t--\t'* ]] || fail "new attach passed --"

clear_log
SBX_SKIP_INSPECT_LOG=1 SBX_INSPECT_STATUS=0 run_claude "${WORK_A}" >/dev/null
assert_log "$(printf 'run\t--name\t%s' "${SANDBOX}")" "existing sandbox attach"
[[ "$(<"${SBX_LOG}")" != *$'\t--\t'* ]] || fail "existing attach passed --"
pass "attach creates only when missing"

# rm is the one destructive command: it must never pass --force, so sbx's own
# confirmation prompt still stands.
clear_log
run_claude "${WORK_A}" rm >/dev/null
assert_log "$(printf 'rm\t%s' "${SANDBOX}")" "rm"
[[ "$(<"${SBX_LOG}")" != *"--force"* ]] || fail "rm passed --force"
pass "rm is a single confirmed removal"

# A malformed command must fail before any sbx call, not after — arity
# checks come first so a typo can never trigger partial destructive work.
reject_without_call "${WORK_A}" rm extra
reject_without_call "${WORK_A}" name extra
reject_without_call "${WORK_A}" inspect extra
reject_without_call "${WORK_A}" create extra
reject_without_call "${WORK_A}" kit
reject_without_call "${WORK_A}" policy
reject_without_call "${WORK_A}" policy check
reject_without_call "${WORK_A}" policy check one two
reject_without_call "${WORK_A}" exec
pass "invalid arities make no sbx calls"

clear_log
run_claude "${WORK_A}" inspect >/dev/null
assert_log "$(printf 'inspect\t%s' "${SANDBOX}")" "inspect"

clear_log
run_claude "${WORK_A}" create >/dev/null
assert_log "$(printf 'create\t--name\t%s\t--kit\t%s\tsbxclaude\t.' \
	"${SANDBOX}" "${CLAUDE_KIT}")" "create"

clear_log
run_claude "${WORK_A}" kit validate >/dev/null
assert_log "$(printf 'kit\tvalidate\t%s' "${CLAUDE_KIT}")" "kit validate"

clear_log
run_claude "${WORK_A}" policy log >/dev/null
assert_log "$(printf 'policy\tlog\t%s' "${SANDBOX}")" "policy log"
pass "single-call commands fill in sandbox and kit operands"

clear_log
CLAUDE_HELP="$(run_claude "${WORK_A}" help)"
assert_no_log "help"
[[ "${CLAUDE_HELP}" == *"Usage:"* ]] || fail "help omitted usage"
[[ "${CLAUDE_HELP}" == *"destructive"* ]] || fail "help omitted rm warning"
[[ "${CLAUDE_HELP}" == *"Use sbx or claude directly"* ]] ||
	fail "help omitted direct-command guidance"
# Usage is interpolated with the invoked name, so the real script name must not
# appear anywhere in it.
[[ "${CLAUDE_HELP}" == *"sbxclaude name"* ]] ||
	fail "help did not use the invoked name"
[[ "${CLAUDE_HELP}" != *"sbxagent"* ]] ||
	fail "help leaked the real script name instead of the invoked name"
pass "help documents the complete wrapper surface, under the invoked name"

reject_without_call "${WORK_A}" foo
pass "unknown commands make no sbx calls"

clear_log
printf '' | run_claude "${WORK_A}" exec echo hello >/dev/null
assert_log "$(printf 'exec\t-i\t%s\t--\techo\thello' "${SANDBOX}")" "piped exec"

clear_log
# Runs the wrapper under a real pty (stdin from a plain pipe is never a tty)
# so the -it branch of the tty gate is actually exercised.
python3 -c \
	'import os, pty, sys; os.chdir(sys.argv[2]); raise SystemExit(os.waitstatus_to_exitcode(pty.spawn([sys.argv[1], "exec", "bash"])))' \
	"${CLAUDE_SCRIPT}" "${WORK_A}" >/dev/null
assert_log "$(printf 'exec\t-it\t%s\t--\tbash' "${SANDBOX}")" "interactive exec"

reject_without_call "${WORK_A}" exec -w /src ls
pass "exec allocates tty only when interactive and rejects sbx options"

clear_log
run_claude "${WORK_A}" policy check github.com >/dev/null
assert_log "$(printf 'policy\tcheck\tnetwork\t--sandbox\t%s\tgithub.com' \
	"${SANDBOX}")" "policy check"
pass "policy check is scoped to the sandbox"

# Basename dispatch is the whole point of one script under three names: each
# must select its own kit directory and its own sandbox, so two agents can run
# against the same project at once without colliding.
run_codex() {
	local directory="$1"
	shift
	(cd "${directory}" && "${CODEX_SCRIPT}" "$@")
}

clear_log
CODEX_NAME="$(run_codex "${WORK_A}" name)"
assert_match "^sbxcodex-$(expected_slug "${WORK_A}")-[0-9a-f]{6}$" "${CODEX_NAME}" "codex derived name"
# Same directory, different command: the slug and hash match and only the kit
# prefix differs, which is what keeps the two sandboxes separate.
assert_eq "sbxcodex-${NAME_A#sbxclaude-}" "${CODEX_NAME}" "codex name differs only by prefix"
[[ "${CODEX_NAME}" != "${NAME_A}" ]] ||
	fail "sbxclaude and sbxcodex produced the same sandbox name"
assert_no_log "codex name"

CODEX_VERSION_OUT="$(run_codex "${WORK_A}" version)"
assert_eq "sbxcodex ${EXPECTED_VERSION}" "${CODEX_VERSION_OUT}" "codex version output"

CODEX_KIT="${ROOT}/kits/sbxcodex"
clear_log
run_codex "${WORK_A}" kit validate >/dev/null
assert_log "$(printf 'kit\tvalidate\t%s' "${CODEX_KIT}")" "codex kit path"

clear_log
run_codex "${WORK_A}" create >/dev/null
assert_log "$(printf 'create\t--name\t%s\t--kit\t%s\tsbxcodex\t.' \
	"${CODEX_NAME}" "${CODEX_KIT}")" "codex create"
pass "sbxcodex dispatches to its own kit, sandbox name and kit operand"

# The "use X directly" line names the agent's own CLI, not Claude's.
clear_log
CODEX_HELP="$(run_codex "${WORK_A}" help)"
assert_no_log "codex help"
[[ "${CODEX_HELP}" == *"Use sbx or codex directly"* ]] ||
	fail "codex help did not name the codex CLI: ${CODEX_HELP}"
[[ "${CODEX_HELP}" == *"sbxcodex name"* ]] ||
	fail "codex help did not use the invoked name"
[[ "${CODEX_HELP}" != *"sbxagent"* ]] ||
	fail "codex help leaked the real script name"
pass "help names the invoked command and its underlying CLI"

run_cursor() {
	local directory="$1"
	shift
	(cd "${directory}" && "${CURSOR_SCRIPT}" "$@")
}

clear_log
CURSOR_NAME="$(run_cursor "${WORK_A}" name)"
assert_match "^sbxcursor-$(expected_slug "${WORK_A}")-[0-9a-f]{6}$" "${CURSOR_NAME}" "cursor derived name"
assert_eq "sbxcursor-${NAME_A#sbxclaude-}" "${CURSOR_NAME}" "cursor name differs only by prefix"
assert_no_log "cursor name"

CURSOR_VERSION_OUT="$(run_cursor "${WORK_A}" version)"
assert_eq "sbxcursor ${EXPECTED_VERSION}" "${CURSOR_VERSION_OUT}" "cursor version output"

CURSOR_KIT="${ROOT}/kits/sbxcursor"
clear_log
run_cursor "${WORK_A}" kit validate >/dev/null
assert_log "$(printf 'kit\tvalidate\t%s' "${CURSOR_KIT}")" "cursor kit path"

clear_log
run_cursor "${WORK_A}" create >/dev/null
assert_log "$(printf 'create\t--name\t%s\t--kit\t%s\tsbxcursor\t.' \
	"${CURSOR_NAME}" "${CURSOR_KIT}")" "cursor create"
pass "sbxcursor dispatches to its own kit, sandbox name and kit operand"

clear_log
CURSOR_HELP="$(run_cursor "${WORK_A}" help)"
assert_no_log "cursor help"
[[ "${CURSOR_HELP}" == *"Use sbx or agent directly"* ]] ||
	fail "cursor help did not name the agent CLI: ${CURSOR_HELP}"
[[ "${CURSOR_HELP}" == *"sbxcursor name"* ]] ||
	fail "cursor help did not use the invoked name"
[[ "${CURSOR_HELP}" != *"sbxagent"* ]] ||
	fail "cursor help leaked the real script name"
pass "cursor help names the invoked command and its underlying CLI"

run_pi() {
	local directory="$1"
	shift
	(cd "${directory}" && "${PI_SCRIPT}" "$@")
}

clear_log
PI_NAME="$(run_pi "${WORK_A}" name)"
assert_match "^sbxpi-$(expected_slug "${WORK_A}")-[0-9a-f]{6}$" "${PI_NAME}" "pi derived name"
assert_eq "sbxpi-${NAME_A#sbxclaude-}" "${PI_NAME}" "pi name differs only by prefix"
assert_no_log "pi name"

PI_VERSION_OUT="$(run_pi "${WORK_A}" version)"
assert_eq "sbxpi ${EXPECTED_VERSION}" "${PI_VERSION_OUT}" "pi version output"

PI_KIT="${ROOT}/kits/sbxpi"
clear_log
run_pi "${WORK_A}" kit validate >/dev/null
assert_log "$(printf 'kit\tvalidate\t%s' "${PI_KIT}")" "pi kit path"

clear_log
run_pi "${WORK_A}" create >/dev/null
assert_log "$(printf 'create\t--name\t%s\t--kit\t%s\tsbxpi\t.' \
	"${PI_NAME}" "${PI_KIT}")" "pi create"
pass "sbxpi dispatches to its own kit, sandbox name and kit operand"

clear_log
PI_HELP="$(run_pi "${WORK_A}" help)"
assert_no_log "pi help"
[[ "${PI_HELP}" == *"Use sbx or pi directly"* ]] ||
	fail "pi help did not name the pi CLI: ${PI_HELP}"
[[ "${PI_HELP}" == *"sbxpi name"* ]] ||
	fail "pi help did not use the invoked name"
[[ "${PI_HELP}" != *"sbxagent"* ]] ||
	fail "pi help leaked the real script name"
pass "pi help names the invoked command and its underlying CLI"

# The whole point of basename dispatch: one directory, four commands, four
# separate sandboxes, so all four agents can run against a project at once.
[[ "${NAME_A}" != "${CODEX_NAME}" && "${NAME_A}" != "${CURSOR_NAME}" && "${NAME_A}" != "${PI_NAME}" &&
	"${CODEX_NAME}" != "${CURSOR_NAME}" && "${CODEX_NAME}" != "${PI_NAME}" &&
	"${CURSOR_NAME}" != "${PI_NAME}" ]] ||
	fail "the four names collide: ${NAME_A} ${CODEX_NAME} ${CURSOR_NAME} ${PI_NAME}"
pass "the four commands yield four distinct sandbox names for one directory"

# The README installs the wrapper as a symlink, so it has to resolve its own
# path through the chain to locate the kit. Two extra hops, the second one
# relative, invoked from an unrelated directory. Every hop is named sbxclaude:
# dispatch reads the basename of $0, so an arbitrary hop name is rejected (that
# is covered separately below).
clear_log
LINK_BIN="${TEST_ROOT}/bin-link"
LINK_BIN2="${TEST_ROOT}/bin-link2"
mkdir -p "${LINK_BIN}" "${LINK_BIN2}"
ln -s "${CLAUDE_SCRIPT}" "${LINK_BIN}/sbxclaude"
(cd "${LINK_BIN2}" && ln -s ../bin-link/sbxclaude sbxclaude)
(cd "${WORK_B}" && "${LINK_BIN2}/sbxclaude" kit validate >/dev/null)
assert_log "$(printf 'kit\tvalidate\t%s' "${CLAUDE_KIT}")" "kit path via symlinked wrapper"
pass "a symlinked wrapper still resolves the repo kit"

# `help` is deliberately not exempt: in this state the refusal message is the
# help you need, and a non-zero exit keeps "not a usable command" honest.
reject_wrong_name "${AGENT_SCRIPT}"
reject_wrong_name "${AGENT_SCRIPT}" help
pass "running scripts/sbxagent directly refuses and explains how to link it"

# A copy rather than a symlink is the one real failure mode of basename
# dispatch, so it gets the same treatment.
COPIED="${TEST_ROOT}/sbx-unknown-agent"
# `cat` rather than `cp`: still a real copy, but virtiofs reports every
# workspace file as fully sparse, so `cp` out of the workspace writes a
# correctly-sized file of NUL bytes and this test would fail for a reason that
# has nothing to do with dispatch. No `cp` flag avoids it; `cat` and `dd` are
# unaffected. Open upstream, no fix as of sbx v0.39.0:
# https://github.com/docker/sbx-releases/issues/526
cat "${AGENT_SCRIPT}" >"${COPIED}"
chmod +x "${COPIED}"
reject_wrong_name "${COPIED}"
pass "a copy under an unknown name refuses too"

# require_sbx runs only in the commands that shell out to sbx, so the commands
# that do not need it keep working on a host where sbx is not installed yet.
MIN_BIN="${TEST_ROOT}/min-bin"
mkdir -p "${MIN_BIN}"
for tool in bash env cat readlink dirname basename cut shasum sha256sum; do
	TOOL_PATH="$(command -v "${tool}" || true)"
	if [[ -n "${TOOL_PATH}" ]]; then
		ln -s "${TOOL_PATH}" "${MIN_BIN}/${tool}"
	fi
done

clear_log
NO_SBX_NAME="$( (cd "${WORK_A}" && PATH="${MIN_BIN}" "${CLAUDE_SCRIPT}" name) )" ||
	fail "'name' failed without sbx on PATH"
assert_eq "${NAME_A}" "${NO_SBX_NAME}" "name without sbx"
(cd "${WORK_A}" && PATH="${MIN_BIN}" "${CLAUDE_SCRIPT}" help >/dev/null) ||
	fail "'help' failed without sbx on PATH"

set +e
NO_SBX_OUTPUT="$( (cd "${WORK_A}" && PATH="${MIN_BIN}" "${CLAUDE_SCRIPT}" inspect) 2>&1 )"
NO_SBX_STATUS=$?
set -e
[[ "${NO_SBX_STATUS}" -ne 0 ]] || fail "'inspect' succeeded without sbx on PATH"
[[ "${NO_SBX_OUTPUT}" == *"macOS:"* && "${NO_SBX_OUTPUT}" == *"Linux:"* ]] ||
	fail "missing sbx hint did not offer both install recipes: '${NO_SBX_OUTPUT}'"
assert_no_log "inspect without sbx"
pass "name and help work without sbx; sbx commands fail with both install recipes"

echo "All ${TESTS} unit tests passed."
