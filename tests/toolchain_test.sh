#!/usr/bin/env bash
# Smoke-tests the helper toolchain from inside a live sbxclaude sandbox.
# Keep EXPECTED_* in sync with the pinned installs in sbxclaude/spec.yaml.
set -euo pipefail

EXPECTED_SBX_VERSION="v0.39.0"
EXPECTED_RUFF_VERSION="0.16.2"
EXPECTED_YAMLLINT_VERSION="1.38.0"
EXPECTED_MARKDOWNLINT_VERSION="0.23.2"
EXPECTED_CSPELL_VERSION="10.0.1"
EXPECTED_PLAYWRIGHT_VERSION="1.62.1"
EXPECTED_MERMAID_VERSION="11.16.0"
EXPECTED_CONTEXT7_MCP_VERSION="4.0.0"
EXPECTED_GITHUB_MCP_VERSION="1.11.0"

TESTS=0

fail() {
	echo "not ok - $*" >&2
	exit 1
}

pass() {
	TESTS=$((TESTS + 1))
	echo "ok ${TESTS} - $*"
}

check_tool() {
	local tool="$1"
	shift
	local output

	command -v "${tool}" >/dev/null 2>&1 ||
		fail "${tool} is not on PATH"
	if ! output="$("$@" 2>&1)"; then
		fail "${tool} version command failed"
	fi
	[[ -n "${output}" ]] || fail "${tool} version command produced no output"
	pass "${tool} is available"
}

check_tool_version() {
	local tool="$1"
	local expected="$2"
	shift 2
	local output

	command -v "${tool}" >/dev/null 2>&1 ||
		fail "${tool} is not on PATH"
	if ! output="$("$@" 2>&1)"; then
		fail "${tool} version command failed"
	fi
	[[ -n "${output}" ]] || fail "${tool} version command produced no output"
	printf '%s\n' "${output}" | grep -Fqw "${expected}" ||
		fail "${tool} version mismatch: expected '${expected}' in: ${output}"
	pass "${tool} is ${expected}"
}

# Distro / parent-kit tools: presence only.
check_tool jq jq --version
check_tool rg rg --version
check_tool curl curl --version
check_tool python3 python3 --version
check_tool shellcheck shellcheck --version
check_tool git git --version

# Directly installed tools: exact pinned versions.
check_tool_version ruff "${EXPECTED_RUFF_VERSION}" ruff --version
check_tool_version yamllint "${EXPECTED_YAMLLINT_VERSION}" yamllint --version
check_tool_version markdownlint-cli2 "v${EXPECTED_MARKDOWNLINT_VERSION}" markdownlint-cli2 --version
check_tool_version cspell "${EXPECTED_CSPELL_VERSION}" cspell --version
check_tool_version sbx "${EXPECTED_SBX_VERSION}" sbx version
check_tool_version playwright "Version ${EXPECTED_PLAYWRIGHT_VERSION}" playwright --version
check_tool_version github-mcp-server "${EXPECTED_GITHUB_MCP_VERSION}" \
	github-mcp-server --version

# Chromium must actually launch, not just be present — this is what lets the
# agent verify UI changes in a real browser. If this fails specifically on
# sandbox/seccomp setup, retry chromium.launch() with { args: ['--no-sandbox'] }.
CHROMIUM_VERSION="$(NODE_PATH="$(npm root -g)" node -e '
const { chromium } = require("playwright");
(async () => {
  const browser = await chromium.launch();
  console.log(await browser.version());
  await browser.close();
})();
' 2>&1)" || fail "chromium failed to launch: ${CHROMIUM_VERSION}"
[[ -n "${CHROMIUM_VERSION}" ]] || fail "chromium launch produced no version output"
pass "chromium launches headless (${CHROMIUM_VERSION})"

check_tool_version mmdc "${EXPECTED_MERMAID_VERSION}" mmdc --version

# Rendering must actually work, not just report a version — this is what
# proves the mmdc wrapper correctly reuses the Playwright Chromium instead of
# needing its own.
MMDC_TMPDIR="$(mktemp -d)"
trap 'rm -rf "${MMDC_TMPDIR}"' EXIT
printf 'graph TD\n  A --> B\n' >"${MMDC_TMPDIR}/diagram.mmd"
mmdc -i "${MMDC_TMPDIR}/diagram.mmd" -o "${MMDC_TMPDIR}/diagram.png" >/dev/null 2>&1 ||
	fail "mmdc failed to render a diagram"
[[ -s "${MMDC_TMPDIR}/diagram.png" ]] || fail "mmdc produced an empty or missing PNG"
pass "mmdc renders a diagram using the reused Playwright Chromium"

CA_BUNDLE="/etc/ssl/certs/ca-certificates.crt"
[[ -s "${CA_BUNDLE}" ]] || fail "CA certificate bundle is missing or empty"
pass "CA certificate bundle is available"

# Sandbox policy allows github.com:443 but not SSH port 22; the kit rewrites
# GitHub SSH remotes to HTTPS so fetches stay on the allowlist.
INSTEAD_OF="$(git config --global --get-all url.https://github.com/.insteadOf || true)"
printf '%s\n' "${INSTEAD_OF}" | grep -Fxq 'git@github.com:' ||
	fail "missing insteadOf rewrite for git@github.com:"
printf '%s\n' "${INSTEAD_OF}" | grep -Fxq 'ssh://git@github.com/' ||
	fail "missing insteadOf rewrite for ssh://git@github.com/"
pass "GitHub SSH remotes rewrite to HTTPS"

# Network-block escalation hook. A blocked request must end the turn and tell
# the user which host to allow, rather than leaving the agent free to work
# around it. Keep these in sync with the `Network-block escalation hook` setup
# command in sbxclaude/spec.yaml.
GUARD_FILTER="/usr/local/lib/sbxclaude/network-block.jq"
MANAGED_SETTINGS="/etc/claude-code/managed-settings.json"

# Both files are written by `setup:`, which only re-runs on a rebuild. A
# sandbox created before that change has neither, and the bare "file missing"
# would read as a broken test rather than a stale sandbox.
REBUILD_HINT="sandbox may predate this kit change — rebuild: 'sbxclaude rm' then 'sbxclaude'"

[[ -s "${GUARD_FILTER}" ]] ||
	fail "guard filter is missing: ${GUARD_FILTER} (${REBUILD_HINT})"
pass "guard filter is installed"

jq -e . "${MANAGED_SETTINGS}" >/dev/null 2>&1 ||
	fail "managed settings are missing or not valid JSON: ${MANAGED_SETTINGS} (${REBUILD_HINT})"
pass "managed settings are valid JSON"

# The failure event matters as much as the success one: a blocked `curl -f` or
# `npm install` exits non-zero and only fires PostToolUseFailure.
for event in PostToolUse PostToolUseFailure; do
	jq -e --arg e "${event}" \
		'.hooks[$e][0].hooks[0].command | test("network-block\\.jq")' \
		"${MANAGED_SETTINGS}" >/dev/null ||
		fail "managed settings do not run the guard on ${event}"
	pass "guard is registered on ${event}"
done

# Feed a payload through the installed filter and echo its verdict.
guard() {
	printf '%s' "$1" | jq -cf "${GUARD_FILTER}"
}

check_guard_blocks() {
	local name="$1" payload="$2" expected="$3"
	local out

	out="$(guard "${payload}")" || fail "guard failed on ${name}"
	[[ -n "${out}" ]] || fail "guard emitted nothing for ${name} (fails open)"
	[[ "$(jq -r '.continue' <<<"${out}")" == "false" ]] ||
		fail "guard did not stop the turn for ${name}: ${out}"
	jq -r '.systemMessage' <<<"${out}" | grep -Fq "${expected}" ||
		fail "guard message for ${name} lacks '${expected}': ${out}"
	pass "guard stops the turn on ${name}"
}

check_guard_ignores() {
	local name="$1" payload="$2"
	local out

	out="$(guard "${payload}")" || fail "guard failed on ${name}"
	[[ "${out}" == "{}" ]] || fail "guard should ignore ${name}, got: ${out}"
	pass "guard ignores ${name}"
}

check_guard_blocks "a PostToolUse block" \
	'{"tool_name":"Bash","tool_input":{"command":"curl -sS https://example.org"},"tool_response":{"stderr":"Blocked by network policy: domain example.org"}}' \
	'sbx policy allow network "example.org"'

check_guard_blocks "a PostToolUseFailure block" \
	'{"tool_name":"Bash","tool_input":{"command":"curl -f https://blocked.test"},"error":"Blocked by local rule for blocked.test"}' \
	'sbx policy allow network "blocked.test"'

# Org policy is not liftable with `sbx policy allow`, so it must not be offered.
check_guard_blocks "an org-policy block" \
	'{"tool_name":"WebFetch","tool_input":{"url":"https://corp.test"},"tool_response":{"content":"Blocked by org policy"}}' \
	'contact IT'

ORG_VERDICT="$(guard '{"tool_response":{"content":"Blocked by org policy"}}')" ||
	fail "guard failed on the org-policy payload"
if printf '%s' "${ORG_VERDICT}" | grep -Fq "sbx policy allow"; then
	fail "org-policy message must not suggest 'sbx policy allow': ${ORG_VERDICT}"
fi
pass "org-policy message omits 'sbx policy allow'"

check_guard_ignores "ordinary output" \
	'{"tool_name":"Bash","tool_input":{"command":"ls"},"tool_response":{"stdout":"a\nb\n"}}'

# The block strings appear verbatim in this project's docs, spec, and tests,
# so reading one of those files must not trip the guard.
check_guard_ignores "a Bash read of CLAUDE.md" \
	'{"tool_name":"Bash","tool_input":{"command":"cat CLAUDE.md"},"tool_response":{"stdout":"Blocked by network policy: domain foo.test"}}'

# A blocked WebFetch must never be exempted just because its URL happens to
# contain one of the self-reference filenames — only a Bash read of the
# actual file is exempt.
check_guard_blocks "a blocked WebFetch of a URL containing AGENTS.md" \
	'{"tool_name":"WebFetch","tool_input":{"url":"https://example.com/AGENTS.md"},"tool_response":{"content":"Blocked by local rule for x.test"}}' \
	'sbx policy allow network "x.test"'

check_guard_blocks "a blocked WebFetch of a URL containing CLAUDE.md" \
	'{"tool_name":"WebFetch","tool_input":{"url":"https://example.com/CLAUDE.md"},"tool_response":{"content":"Blocked by local rule for y.test"}}' \
	'sbx policy allow network "y.test"'

check_guard_blocks "a blocked WebFetch of a URL containing spec.yaml" \
	'{"tool_name":"WebFetch","tool_input":{"url":"https://example.com/spec.yaml"},"tool_response":{"content":"Blocked by local rule for z.test"}}' \
	'sbx policy allow network "z.test"'

# User-scope MCP servers baked into every sandbox via
# sbxclaude/files/home/.claude.json, so Context7 and GitHub MCP tools are
# available regardless of the target project's own MCP configuration.
CLAUDE_JSON="${HOME}/.claude.json"

[[ -s "${CLAUDE_JSON}" ]] || fail "${CLAUDE_JSON} is missing (${REBUILD_HINT})"
jq -e . "${CLAUDE_JSON}" >/dev/null 2>&1 ||
	fail "${CLAUDE_JSON} is not valid JSON"
pass "${CLAUDE_JSON} is valid JSON"

# Guards against the same root-ownership defect the entrypoint chown already
# works around for ~/.claude (see spec.yaml, issue #415).
[[ -O "${CLAUDE_JSON}" ]] || fail "${CLAUDE_JSON} is not owned by the sandbox user"
pass "${CLAUDE_JSON} is owned by the sandbox user"

jq -e --arg v "@upstash/context7-mcp@${EXPECTED_CONTEXT7_MCP_VERSION}" \
	'.mcpServers.context7.args | index($v) != null' \
	"${CLAUDE_JSON}" >/dev/null ||
	fail "context7 MCP server missing or wrong pinned version in ${CLAUDE_JSON}"
pass "context7 MCP server is pinned to ${EXPECTED_CONTEXT7_MCP_VERSION}"

# Must stay byte-identical to the `github` entry in the repo's .mcp.json: the
# sandbox mounts the project, so a project-scope entry sits alongside this
# user-scope one and Claude Code reports conflicting endpoints if they differ.
# GITHUB_TOKEN is the developer's PAT on the host; the entrypoint points it at
# the proxy-managed `github` sentinel in here.
jq -e '.mcpServers.github.command == "github-mcp-server"
	and (.mcpServers.github.args | index("stdio") != null)
	and .mcpServers.github.env.GITHUB_PERSONAL_ACCESS_TOKEN == "${GITHUB_TOKEN}"' \
	"${CLAUDE_JSON}" >/dev/null ||
	fail "github MCP server missing or misconfigured in ${CLAUDE_JSON}"
pass "github MCP server is configured for local stdio"

echo "All ${TESTS} toolchain tests passed."
