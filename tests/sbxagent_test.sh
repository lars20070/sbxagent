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

# scripts/sbxagent loads ${ROOT}/.env if present, and every test below
# invokes the wrapper against this real checkout — there is no sandboxed
# REPO to point it at instead. Move any real .env a developer created via
# `cp .env.example .env` out of the way for the whole suite, and put it
# back (or remove a test-written one) on exit, so `make test-unit` never
# reads or clobbers a real local .env.
ENV_FILE="${ROOT}/.env"
ENV_BACKUP="${TEST_ROOT}/env-backup"
[[ ! -e "${ENV_FILE}" ]] || mv "${ENV_FILE}" "${ENV_BACKUP}"

cleanup() {
	if [[ -e "${ENV_BACKUP}" ]]; then
		mv "${ENV_BACKUP}" "${ENV_FILE}"
	else
		rm -f "${ENV_FILE}"
	fi
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
# The wrapper creates its state tree under XDG_STATE_HOME on every
# sandbox-creating call; point it into TEST_ROOT so the real machine's
# ~/.local/state is never touched.
export XDG_STATE_HOME="${TEST_ROOT}/xdg-state"
STATE_ROOT="${XDG_STATE_HOME}/sbxagent/traces"
# The messageboard tree is a sibling of traces under the same XDG root: one
# folder per project, shared read-write by every agent's sandbox for it, with
# no per-agent subfolder.
MESSAGEBOARD_ROOT="${XDG_STATE_HOME}/sbxagent/messageboards"

# Portable mode probe: BSD stat first, GNU fallback, same pattern as the
# wrapper's shasum/sha256sum probe.
file_mode() {
	stat -f%Lp "$1" 2>/dev/null || stat -c%a "$1"
}

WORK_A="${TEST_ROOT}/one/api"
WORK_B="${TEST_ROOT}/two/api"
EMPTY_SLUG="${TEST_ROOT}/..."
LINK="${TEST_ROOT}/api-link"
# Two basenames that overrun the 63-character sandbox-name limit sbx enforces.
# The second is sized so the cut lands exactly on a hyphen, which would leave a
# trailing hyphen -- also rejected -- if the wrapper did not re-strip afterwards.
LONG_SLUG="${TEST_ROOT}/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
LONG_SLUG_CUT_ON_HYPHEN="${TEST_ROOT}/ccccccccccccccccccccccccccccccccccccccccccc-tail"
mkdir -p "${WORK_A}" "${WORK_B}" "${EMPTY_SLUG}" "${LONG_SLUG}" \
	"${LONG_SLUG_CUT_ON_HYPHEN}"
ln -s "${WORK_A}" "${LINK}"

# Sandbox naming: derived from the canonical directory path, so it must be
# unique per path, stable across runs, symlink-transparent, and never empty.
clear_log
NAME_A="$(run_claude "${WORK_A}" name)"
assert_match "^sbxclaude-$(expected_slug "${WORK_A}")-[0-9a-f]{8}$" "${NAME_A}" "derived name"
STABLE_NAME="$(run_claude "${WORK_A}" name)"
assert_eq "${NAME_A}" "${STABLE_NAME}" "stable name"
NAME_B="$(run_claude "${WORK_B}" name)"
[[ "${NAME_A}" != "${NAME_B}" ]] || fail "same basenames produced the same name"
LINK_NAME="$(run_claude "${LINK}" name)"
assert_eq "${NAME_A}" "${LINK_NAME}" "symlink name"
EMPTY_NAME="$(run_claude "${EMPTY_SLUG}" name)"
[[ "${EMPTY_NAME}" =~ ^sbxclaude-[0-9a-f]{8}$ ]] ||
	fail "empty sanitized basename produced invalid name '${EMPTY_NAME}'"
CUSTOM_HASH_NAME="$(HASH_LENGTH=12 run_claude "${WORK_A}" name)"
assert_match "^sbxclaude-$(expected_slug "${WORK_A}")-[0-9a-f]{12}$" \
	"${CUSTOM_HASH_NAME}" "custom hash length"
assert_no_log "name"
pass "name derivation is unique, stable, canonical, and configurable"

# sbx rejects a sandbox name longer than 63 characters or ending in a hyphen or
# period, so the slug is truncated to fit. The hash still carries the whole
# path, so two truncated siblings stay distinct.
clear_log
LONG_NAME="$(run_claude "${LONG_SLUG}" name)"
assert_match "^sbxclaude-a{44}-[0-9a-f]{8}$" "${LONG_NAME}" "truncated long name"
[[ "${#LONG_NAME}" -le 63 ]] ||
	fail "long basename produced a ${#LONG_NAME}-character name '${LONG_NAME}'"
HYPHEN_CUT_NAME="$(run_claude "${LONG_SLUG_CUT_ON_HYPHEN}" name)"
assert_match "^sbxclaude-c{43}-[0-9a-f]{8}$" \
	"${HYPHEN_CUT_NAME}" "cut landing on a hyphen"
# A hash long enough to overrun the limit on its own has nothing left to trim,
# so the wrapper refuses rather than emitting a name sbx would reject.
set +e
OVERLONG_HASH_OUT="$(HASH_LENGTH=60 run_claude "${WORK_A}" name 2>&1)"
OVERLONG_HASH_STATUS=$?
set -e
[[ "${OVERLONG_HASH_STATUS}" -ne 0 ]] ||
	fail "HASH_LENGTH=60 unexpectedly produced '${OVERLONG_HASH_OUT}'"
assert_match "63 characters" "${OVERLONG_HASH_OUT}" "overlong hash error"
assert_no_log "name"
pass "names are truncated to the 63-character limit without a trailing hyphen"

# version: reads VERSION directly, needs no sbx call.
clear_log
CLAUDE_VERSION_OUT="$(run_claude "${WORK_A}" version)"
assert_eq "sbxclaude ${EXPECTED_VERSION}" "${CLAUDE_VERSION_OUT}" "version output"
assert_no_log "version"
pass "version prints the kit name and version without calling sbx"

SANDBOX="${NAME_A}"
CLAUDE_KIT="${ROOT}/kits/sbxclaude"
# The state tree is keyed by the project, not the agent: strip the agent
# prefix from the sandbox name and every kit run against WORK_A shares the
# result. Asserted below when a second kit creates into the same folder.
PROJECT_DIR="${STATE_ROOT}/${NAME_A#*-}"
# Same project key, so the messageboard folder sits alongside the trace folder
# and is shared by every agent's sandbox for WORK_A.
MESSAGEBOARD_DIR="${MESSAGEBOARD_ROOT}/${NAME_A#*-}"

# name and version are read-only: nothing under STATE_ROOT may exist yet.
# This can only be asserted before the first sandbox-creating call.
[[ ! -e "${STATE_ROOT}" ]] || fail "name/version created ${STATE_ROOT}"
[[ ! -e "${MESSAGEBOARD_ROOT}" ]] || fail "name/version created ${MESSAGEBOARD_ROOT}"

# Attach: creates (validate + kit) only when the sandbox is missing, and
# re-attaches directly when it already exists. Neither call passes `--`,
# since the wrapper never forwards agent arguments. Creation mounts the
# project's state folder read-only, the project's messageboard read-write,
# and this agent's subfolder read-write.
clear_log
SBX_SKIP_INSPECT_LOG=1 SBX_INSPECT_STATUS=1 run_claude "${WORK_A}" >/dev/null
assert_log "$(printf 'kit\tvalidate\t%s\nrun\t--name\t%s\t-e\tSBXAGENT_STATE_DIR=%s\t--kit-arg\tlite=true\t%s\t.\t%s:ro\t%s\t%s' \
	"${CLAUDE_KIT}" "${SANDBOX}" "${PROJECT_DIR}/sbxclaude" \
	"${CLAUDE_KIT}" "${PROJECT_DIR}" "${MESSAGEBOARD_DIR}" "${PROJECT_DIR}/sbxclaude")" "new sandbox attach"
[[ "$(<"${SBX_LOG}")" != *$'\t--\t'* ]] || fail "new attach passed --"
[[ -d "${PROJECT_DIR}/sbxclaude" ]] || fail "attach did not create ${PROJECT_DIR}/sbxclaude"
[[ -d "${MESSAGEBOARD_DIR}" ]] || fail "attach did not create ${MESSAGEBOARD_DIR}"

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

# Wipe both state trees first so this covers the create branch's own mkdir,
# rather than riding on the folders the attach test already made.
rm -rf "${STATE_ROOT}" "${MESSAGEBOARD_ROOT}"
clear_log
run_claude "${WORK_A}" create >/dev/null
assert_log "$(printf 'create\t--name\t%s\t-e\tSBXAGENT_STATE_DIR=%s\t--kit-arg\tlite=true\t%s\t.\t%s:ro\t%s\t%s' \
	"${SANDBOX}" "${PROJECT_DIR}/sbxclaude" "${CLAUDE_KIT}" "${PROJECT_DIR}" "${MESSAGEBOARD_DIR}" "${PROJECT_DIR}/sbxclaude")" "create"
[[ -d "${PROJECT_DIR}/sbxclaude" ]] || fail "create did not create ${PROJECT_DIR}/sbxclaude"
assert_eq "700" "$(file_mode "${PROJECT_DIR}/sbxclaude")" "agent state folder mode"
[[ -d "${MESSAGEBOARD_DIR}" ]] || fail "create did not create ${MESSAGEBOARD_DIR}"
assert_eq "700" "$(file_mode "${MESSAGEBOARD_DIR}")" "messageboard folder mode"

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

# Basename dispatch is the whole point of one script under four names: each
# must select its own kit directory and its own sandbox, so two agents can run
# against the same project at once without colliding.
run_codex() {
	local directory="$1"
	shift
	(cd "${directory}" && "${CODEX_SCRIPT}" "$@")
}

clear_log
CODEX_NAME="$(run_codex "${WORK_A}" name)"
assert_match "^sbxcodex-$(expected_slug "${WORK_A}")-[0-9a-f]{8}$" "${CODEX_NAME}" "codex derived name"
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
assert_log "$(printf 'create\t--name\t%s\t-e\tSBXAGENT_STATE_DIR=%s\t--kit-arg\tlite=true\t%s\t.\t%s:ro\t%s\t%s' \
	"${CODEX_NAME}" "${PROJECT_DIR}/sbxcodex" "${CODEX_KIT}" "${PROJECT_DIR}" "${MESSAGEBOARD_DIR}" "${PROJECT_DIR}/sbxcodex")" "codex create"
pass "sbxcodex dispatches to its own kit, sandbox name and kit operand"

# The state folder is shared per project, not per agent: both kits' folders
# now sit under the one PROJECT_DIR, which is what lets one agent's sandbox
# read the other's state for the same directory. The messageboard goes further
# — one folder with no per-agent subfolder, so the identical path is mounted
# read-write into both sandboxes, which is what makes it a shared board. The
# argv assertions above already show both kits naming the same MESSAGEBOARD_DIR.
[[ -d "${PROJECT_DIR}/sbxclaude" && -d "${PROJECT_DIR}/sbxcodex" ]] ||
	fail "claude and codex did not share ${PROJECT_DIR}"
[[ -d "${MESSAGEBOARD_DIR}" ]] || fail "codex create did not reuse ${MESSAGEBOARD_DIR}"
[[ ! -e "${MESSAGEBOARD_DIR}/sbxclaude" && ! -e "${MESSAGEBOARD_DIR}/sbxcodex" ]] ||
	fail "the messageboard grew a per-agent subfolder under ${MESSAGEBOARD_DIR}"
pass "two agents for one directory share a project state folder and messageboard"

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
assert_match "^sbxcursor-$(expected_slug "${WORK_A}")-[0-9a-f]{8}$" "${CURSOR_NAME}" "cursor derived name"
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
assert_log "$(printf 'create\t--name\t%s\t-e\tSBXAGENT_STATE_DIR=%s\t--kit-arg\tlite=true\t%s\t.\t%s:ro\t%s\t%s' \
	"${CURSOR_NAME}" "${PROJECT_DIR}/sbxcursor" "${CURSOR_KIT}" "${PROJECT_DIR}" "${MESSAGEBOARD_DIR}" "${PROJECT_DIR}/sbxcursor")" "cursor create"
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
assert_match "^sbxpi-$(expected_slug "${WORK_A}")-[0-9a-f]{8}$" "${PI_NAME}" "pi derived name"
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
assert_log "$(printf 'create\t--name\t%s\t-e\tSBXAGENT_STATE_DIR=%s\t--kit-arg\tlite=true\t%s\t.\t%s:ro\t%s\t%s' \
	"${PI_NAME}" "${PROJECT_DIR}/sbxpi" "${PI_KIT}" "${PROJECT_DIR}" "${MESSAGEBOARD_DIR}" "${PROJECT_DIR}/sbxpi")" "pi create"
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

# A different directory gets its own project state folder. Only that folder
# is mounted, so a sandbox for WORK_B never sees WORK_A's state, and creating
# it leaves WORK_A's folder exactly as it was.
PROJECT_DIR_B="${STATE_ROOT}/${NAME_B#*-}"
MESSAGEBOARD_DIR_B="${MESSAGEBOARD_ROOT}/${NAME_B#*-}"
[[ "${PROJECT_DIR_B}" != "${PROJECT_DIR}" ]] ||
	fail "same basenames produced the same project state folder"
[[ "${MESSAGEBOARD_DIR_B}" != "${MESSAGEBOARD_DIR}" ]] ||
	fail "same basenames produced the same messageboard folder"
BEFORE="$(ls "${PROJECT_DIR}")"
clear_log
run_claude "${WORK_B}" create >/dev/null
assert_log "$(printf 'create\t--name\t%s\t-e\tSBXAGENT_STATE_DIR=%s\t--kit-arg\tlite=true\t%s\t.\t%s:ro\t%s\t%s' \
	"${NAME_B}" "${PROJECT_DIR_B}/sbxclaude" "${CLAUDE_KIT}" "${PROJECT_DIR_B}" "${MESSAGEBOARD_DIR_B}" "${PROJECT_DIR_B}/sbxclaude")" "create in another directory"
[[ -d "${PROJECT_DIR_B}/sbxclaude" ]] || fail "create did not create ${PROJECT_DIR_B}/sbxclaude"
assert_eq "${BEFORE}" "$(ls "${PROJECT_DIR}")" "other project's state folder untouched"
pass "each directory gets its own project state folder"

# CROSS_SANDBOX_VISIBILITY=false drops the read-only project mount and the
# read-write messageboard mount, leaving only the agent's own subfolder. Both
# creating paths have their own exec line, so both are checked. Any other value
# is rejected before sbx runs or anything is created, and only on the creating
# paths — name must keep working. WORK_B's messageboard already exists by now
# (the default-visibility create just above made it), so only the argv can be
# asserted here: false must not mount it, but must not delete it either. The
# never-created case is asserted with a fresh project key in the .env block.
clear_log
CROSS_SANDBOX_VISIBILITY=false run_claude "${WORK_B}" create >/dev/null
assert_log "$(printf 'create\t--name\t%s\t-e\tSBXAGENT_STATE_DIR=%s\t--kit-arg\tlite=true\t%s\t.\t%s' \
	"${NAME_B}" "${PROJECT_DIR_B}/sbxclaude" "${CLAUDE_KIT}" "${PROJECT_DIR_B}/sbxclaude")" "create without visibility"
[[ -d "${PROJECT_DIR_B}/sbxclaude" ]] || fail "create without visibility removed ${PROJECT_DIR_B}/sbxclaude"
[[ -d "${MESSAGEBOARD_DIR_B}" ]] ||
	fail "create without visibility deleted the existing ${MESSAGEBOARD_DIR_B}"

clear_log
CROSS_SANDBOX_VISIBILITY=false SBX_SKIP_INSPECT_LOG=1 SBX_INSPECT_STATUS=1 run_claude "${WORK_B}" >/dev/null
assert_log "$(printf 'kit\tvalidate\t%s\nrun\t--name\t%s\t-e\tSBXAGENT_STATE_DIR=%s\t--kit-arg\tlite=true\t%s\t.\t%s' \
	"${CLAUDE_KIT}" "${NAME_B}" "${PROJECT_DIR_B}/sbxclaude" "${CLAUDE_KIT}" "${PROJECT_DIR_B}/sbxclaude")" "attach without visibility"

BEFORE="$(ls "${STATE_ROOT}")"
BEFORE_BOARD="$(ls "${MESSAGEBOARD_ROOT}")"
CROSS_SANDBOX_VISIBILITY=bogus reject_without_call "${WORK_B}" create
assert_eq "${BEFORE}" "$(ls "${STATE_ROOT}")" "bad visibility value created state"
assert_eq "${BEFORE_BOARD}" "$(ls "${MESSAGEBOARD_ROOT}")" "bad visibility value created a messageboard"
BOGUS_NAME="$(CROSS_SANDBOX_VISIBILITY=bogus run_claude "${WORK_B}" name)" ||
	fail "'name' failed with a bad CROSS_SANDBOX_VISIBILITY"
assert_eq "${NAME_B}" "${BOGUS_NAME}" "name with bad visibility value"
pass "CROSS_SANDBOX_VISIBILITY=false drops the shared mount and rejects other values"

# SBXAGENT_LITE reaches the kit as --kit-arg lite=<value>; the default true
# is already asserted by every create/run argv above. Like the visibility
# flag, a bad value is rejected only on the creating paths.
clear_log
SBXAGENT_LITE=false run_claude "${WORK_B}" create >/dev/null
assert_log "$(printf 'create\t--name\t%s\t-e\tSBXAGENT_STATE_DIR=%s\t--kit-arg\tlite=false\t%s\t.\t%s:ro\t%s\t%s' \
	"${NAME_B}" "${PROJECT_DIR_B}/sbxclaude" "${CLAUDE_KIT}" "${PROJECT_DIR_B}" "${MESSAGEBOARD_DIR_B}" "${PROJECT_DIR_B}/sbxclaude")" "create with SBXAGENT_LITE=false"
SBXAGENT_LITE=bogus reject_without_call "${WORK_B}" create
LITE_BOGUS_NAME="$(SBXAGENT_LITE=bogus run_claude "${WORK_B}" name)" ||
	fail "'name' failed with a bad SBXAGENT_LITE"
assert_eq "${NAME_B}" "${LITE_BOGUS_NAME}" "name with bad SBXAGENT_LITE value"
pass "SBXAGENT_LITE is passed as a kit arg and rejects other values"

# NETWORK_ALLOWLIST=false stacks the open-network mixin kit with --kit on
# both creating paths; the default true adds nothing, which every create/run
# argv above already asserts. A bad value is rejected only on those paths.
OPEN_NETWORK_KIT="${ROOT}/mixins/open-network"
clear_log
NETWORK_ALLOWLIST=false run_claude "${WORK_B}" create >/dev/null
assert_log "$(printf 'create\t--name\t%s\t-e\tSBXAGENT_STATE_DIR=%s\t--kit-arg\tlite=true\t--kit\t%s\t%s\t.\t%s:ro\t%s\t%s' \
	"${NAME_B}" "${PROJECT_DIR_B}/sbxclaude" "${OPEN_NETWORK_KIT}" "${CLAUDE_KIT}" "${PROJECT_DIR_B}" "${MESSAGEBOARD_DIR_B}" "${PROJECT_DIR_B}/sbxclaude")" "create with NETWORK_ALLOWLIST=false"
clear_log
NETWORK_ALLOWLIST=false SBX_SKIP_INSPECT_LOG=1 SBX_INSPECT_STATUS=1 run_claude "${WORK_B}" >/dev/null
assert_log "$(printf 'kit\tvalidate\t%s\nrun\t--name\t%s\t-e\tSBXAGENT_STATE_DIR=%s\t--kit-arg\tlite=true\t--kit\t%s\t%s\t.\t%s:ro\t%s\t%s' \
	"${CLAUDE_KIT}" "${NAME_B}" "${PROJECT_DIR_B}/sbxclaude" \
	"${OPEN_NETWORK_KIT}" "${CLAUDE_KIT}" "${PROJECT_DIR_B}" "${MESSAGEBOARD_DIR_B}" "${PROJECT_DIR_B}/sbxclaude")" "new sandbox attach with NETWORK_ALLOWLIST=false"
NETWORK_ALLOWLIST=bogus reject_without_call "${WORK_B}" create
NETWORK_BOGUS_NAME="$(NETWORK_ALLOWLIST=bogus run_claude "${WORK_B}" name)" ||
	fail "'name' failed with a bad NETWORK_ALLOWLIST"
assert_eq "${NAME_B}" "${NETWORK_BOGUS_NAME}" "name with bad NETWORK_ALLOWLIST value"
pass "NETWORK_ALLOWLIST=false stacks the open-network mixin and rejects other values"

# .env file: a config layer weaker than a real exported env var, stronger
# than scripts/sbxagent's own defaults. ${ROOT}/.env is backed up for the
# whole suite (see top of file); this is the only block that writes one, and
# it removes it again immediately after so nothing later in the suite
# observes it.
WORK_ENV="${TEST_ROOT}/three/api"
mkdir -p "${WORK_ENV}"
cat >"${ENV_FILE}" <<'EOF'
HASH_LENGTH=6
CROSS_SANDBOX_VISIBILITY=false
SBXAGENT_LITE=false
NETWORK_ALLOWLIST=false
EOF

clear_log
DOTENV_NAME="$(run_claude "${WORK_ENV}" name)"
assert_match "^sbxclaude-$(expected_slug "${WORK_ENV}")-[0-9a-f]{6}$" \
	"${DOTENV_NAME}" ".env sets HASH_LENGTH when unset in real env"

DOTENV_PROJECT_DIR="${STATE_ROOT}/${DOTENV_NAME#*-}"
DOTENV_MESSAGEBOARD_DIR="${MESSAGEBOARD_ROOT}/${DOTENV_NAME#*-}"
clear_log
run_claude "${WORK_ENV}" create >/dev/null
assert_log "$(printf 'create\t--name\t%s\t-e\tSBXAGENT_STATE_DIR=%s\t--kit-arg\tlite=false\t--kit\t%s\t%s\t.\t%s' \
	"${DOTENV_NAME}" "${DOTENV_PROJECT_DIR}/sbxclaude" "${OPEN_NETWORK_KIT}" "${CLAUDE_KIT}" "${DOTENV_PROJECT_DIR}/sbxclaude")" \
	".env CROSS_SANDBOX_VISIBILITY=false drops the shared mount, SBXAGENT_LITE=false reaches the kit, NETWORK_ALLOWLIST=false stacks the mixin"
# The only project key in the suite whose first create runs with visibility
# off, so this is where "never created" can be told apart from "created by an
# earlier visible create and correctly left alone".
[[ ! -e "${DOTENV_MESSAGEBOARD_DIR}" ]] ||
	fail "create without visibility created ${DOTENV_MESSAGEBOARD_DIR}"

clear_log
NETWORK_ALLOWLIST=true run_claude "${WORK_ENV}" create >/dev/null
assert_log "$(printf 'create\t--name\t%s\t-e\tSBXAGENT_STATE_DIR=%s\t--kit-arg\tlite=false\t%s\t.\t%s' \
	"${DOTENV_NAME}" "${DOTENV_PROJECT_DIR}/sbxclaude" "${CLAUDE_KIT}" "${DOTENV_PROJECT_DIR}/sbxclaude")" \
	"real env NETWORK_ALLOWLIST=true beats .env"

ENV_OVERRIDE_NAME="$(HASH_LENGTH=9 run_claude "${WORK_ENV}" name)"
assert_match "^sbxclaude-$(expected_slug "${WORK_ENV}")-[0-9a-f]{9}$" \
	"${ENV_OVERRIDE_NAME}" "real env HASH_LENGTH beats .env"

rm -f "${ENV_FILE}"
pass ".env supplies defaults that real env still overrides"

# The empty-slug guard applies to the project folder as well as the sandbox
# name: with nothing left of the basename the key is the bare hash, never
# "-<hash>". EMPTY_NAME is already known to be sbxclaude-<hash>, so the
# expected folder is derived the same way as PROJECT_DIR above.
EMPTY_PROJECT_DIR="${STATE_ROOT}/${EMPTY_NAME#*-}"
EMPTY_MESSAGEBOARD_DIR="${MESSAGEBOARD_ROOT}/${EMPTY_NAME#*-}"
clear_log
run_claude "${EMPTY_SLUG}" create >/dev/null
assert_log "$(printf 'create\t--name\t%s\t-e\tSBXAGENT_STATE_DIR=%s\t--kit-arg\tlite=true\t%s\t.\t%s:ro\t%s\t%s' \
	"${EMPTY_NAME}" "${EMPTY_PROJECT_DIR}/sbxclaude" "${CLAUDE_KIT}" "${EMPTY_PROJECT_DIR}" "${EMPTY_MESSAGEBOARD_DIR}" "${EMPTY_PROJECT_DIR}/sbxclaude")" "create with empty slug"
[[ -d "${EMPTY_PROJECT_DIR}/sbxclaude" ]] || fail "create did not create ${EMPTY_PROJECT_DIR}/sbxclaude"
[[ -d "${EMPTY_MESSAGEBOARD_DIR}" ]] || fail "create did not create ${EMPTY_MESSAGEBOARD_DIR}"
pass "an empty slug keys the project state and messageboard folders by hash alone"

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
# unaffected. Open upstream, no fix as of sbx v0.45.0:
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
