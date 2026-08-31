#!/usr/bin/env bash
# Exercises the wrapper's dispatch against a fake `sbx` on PATH that logs its
# argv, so behavior is checked without touching a real sandbox.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/scripts/sbxclaude"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/sbxclaude-test.XXXXXX")"
FAKE_BIN="${TEST_ROOT}/bin"
SBX_LOG="${TEST_ROOT}/sbx.log"
TESTS=0

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

run_cli() {
	local directory="$1"
	shift
	(cd "${directory}" && "${SCRIPT}" "$@")
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
	output="$(run_cli "${directory}" "$@" 2>&1)"
	status=$?
	set -e
	if [[ "${status}" -eq 0 ]]; then
		fail "'$*' unexpectedly succeeded"
	fi
	[[ -n "${output}" ]] || fail "'$*' produced no error"
	assert_no_log "'$*'"
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
NAME_A="$(run_cli "${WORK_A}" name)"
assert_match "^sbxclaude-$(expected_slug "${WORK_A}")-[0-9a-f]{6}$" "${NAME_A}" "derived name"
STABLE_NAME="$(run_cli "${WORK_A}" name)"
assert_eq "${NAME_A}" "${STABLE_NAME}" "stable name"
NAME_B="$(run_cli "${WORK_B}" name)"
[[ "${NAME_A}" != "${NAME_B}" ]] || fail "same basenames produced the same name"
LINK_NAME="$(run_cli "${LINK}" name)"
assert_eq "${NAME_A}" "${LINK_NAME}" "symlink name"
EMPTY_NAME="$(run_cli "${EMPTY_SLUG}" name)"
[[ "${EMPTY_NAME}" =~ ^sbxclaude-[0-9a-f]{6}$ ]] ||
	fail "empty sanitized basename produced invalid name '${EMPTY_NAME}'"
assert_no_log "name"
pass "name derivation is unique, stable, and canonical"

# version: reads spec.yaml directly, needs no sbx call.
clear_log
VERSION_OUT="$(run_cli "${WORK_A}" version)"
assert_match "^sbxclaude [0-9]+\.[0-9]+\.[0-9]+$" "${VERSION_OUT}" "version output"
assert_no_log "version"
pass "version prints the kit name and version without calling sbx"

SANDBOX="${NAME_A}"
KIT="${ROOT}/sbxclaude"

# Attach: creates (validate + kit) only when the sandbox is missing, and
# re-attaches directly when it already exists. Neither call passes `--`,
# since the wrapper never forwards agent arguments.
clear_log
SBX_SKIP_INSPECT_LOG=1 SBX_INSPECT_STATUS=1 run_cli "${WORK_A}" >/dev/null
assert_log "$(printf 'kit\tvalidate\t%s\nrun\t--name\t%s\t--kit\t%s\tsbxclaude' \
	"${KIT}" "${SANDBOX}" "${KIT}")" "new sandbox attach"
[[ "$(<"${SBX_LOG}")" != *$'\t--\t'* ]] || fail "new attach passed --"

clear_log
SBX_SKIP_INSPECT_LOG=1 SBX_INSPECT_STATUS=0 run_cli "${WORK_A}" >/dev/null
assert_log "$(printf 'run\t--name\t%s' "${SANDBOX}")" "existing sandbox attach"
[[ "$(<"${SBX_LOG}")" != *$'\t--\t'* ]] || fail "existing attach passed --"
pass "attach creates only when missing"

# rm is the one destructive command: it must never pass --force, so sbx's own
# confirmation prompt still stands.
clear_log
run_cli "${WORK_A}" rm >/dev/null
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
run_cli "${WORK_A}" inspect >/dev/null
assert_log "$(printf 'inspect\t%s' "${SANDBOX}")" "inspect"

clear_log
run_cli "${WORK_A}" create >/dev/null
assert_log "$(printf 'create\t--name\t%s\t--kit\t%s\tsbxclaude\t.' \
	"${SANDBOX}" "${KIT}")" "create"

clear_log
run_cli "${WORK_A}" kit validate >/dev/null
assert_log "$(printf 'kit\tvalidate\t%s' "${KIT}")" "kit validate"

clear_log
run_cli "${WORK_A}" policy log >/dev/null
assert_log "$(printf 'policy\tlog\t%s' "${SANDBOX}")" "policy log"
pass "single-call commands fill in sandbox and kit operands"

clear_log
HELP_OUTPUT="$(run_cli "${WORK_A}" help)"
assert_no_log "help"
[[ "${HELP_OUTPUT}" == *"Usage:"* ]] || fail "help omitted usage"
[[ "${HELP_OUTPUT}" == *"destructive"* ]] || fail "help omitted rm warning"
[[ "${HELP_OUTPUT}" == *"Use sbx or claude directly"* ]] ||
	fail "help omitted direct-command guidance"
pass "help documents the complete wrapper surface"

reject_without_call "${WORK_A}" foo
pass "unknown commands make no sbx calls"

clear_log
printf '' | run_cli "${WORK_A}" exec echo hello >/dev/null
assert_log "$(printf 'exec\t-i\t%s\t--\techo\thello' "${SANDBOX}")" "piped exec"

clear_log
# Runs the wrapper under a real pty (stdin from a plain pipe is never a tty)
# so the -it branch of the tty gate is actually exercised.
python3 -c \
	'import os, pty, sys; os.chdir(sys.argv[2]); raise SystemExit(os.waitstatus_to_exitcode(pty.spawn([sys.argv[1], "exec", "bash"])))' \
	"${SCRIPT}" "${WORK_A}" >/dev/null
assert_log "$(printf 'exec\t-it\t%s\t--\tbash' "${SANDBOX}")" "interactive exec"

reject_without_call "${WORK_A}" exec -w /src ls
pass "exec allocates tty only when interactive and rejects sbx options"

clear_log
run_cli "${WORK_A}" policy check github.com >/dev/null
assert_log "$(printf 'policy\tcheck\tnetwork\t--sandbox\t%s\tgithub.com' \
	"${SANDBOX}")" "policy check"
pass "policy check is scoped to the sandbox"

# The README installs the wrapper as a symlink, so it has to resolve its own
# path through the chain to locate the kit. Two hops, the second one relative,
# invoked from an unrelated directory.
clear_log
LINK_BIN="${TEST_ROOT}/bin-link"
mkdir -p "${LINK_BIN}"
ln -s "${SCRIPT}" "${LINK_BIN}/hop1"
(cd "${LINK_BIN}" && ln -s hop1 hop2)
(cd "${WORK_B}" && "${LINK_BIN}/hop2" kit validate >/dev/null)
assert_log "$(printf 'kit\tvalidate\t%s' "${KIT}")" "kit path via symlinked wrapper"
pass "a symlinked wrapper still resolves the repo kit"

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
NO_SBX_NAME="$( (cd "${WORK_A}" && PATH="${MIN_BIN}" "${SCRIPT}" name) )" ||
	fail "'name' failed without sbx on PATH"
assert_eq "${NAME_A}" "${NO_SBX_NAME}" "name without sbx"
(cd "${WORK_A}" && PATH="${MIN_BIN}" "${SCRIPT}" help >/dev/null) ||
	fail "'help' failed without sbx on PATH"

set +e
NO_SBX_OUTPUT="$( (cd "${WORK_A}" && PATH="${MIN_BIN}" "${SCRIPT}" inspect) 2>&1 )"
NO_SBX_STATUS=$?
set -e
[[ "${NO_SBX_STATUS}" -ne 0 ]] || fail "'inspect' succeeded without sbx on PATH"
[[ "${NO_SBX_OUTPUT}" == *"macOS:"* && "${NO_SBX_OUTPUT}" == *"Linux:"* ]] ||
	fail "missing sbx hint did not offer both install recipes: '${NO_SBX_OUTPUT}'"
assert_no_log "inspect without sbx"
pass "name and help work without sbx; sbx commands fail with both install recipes"

echo "All ${TESTS} unit tests passed."
