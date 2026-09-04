#!/usr/bin/env bash
# Smoke-tests the helper toolchain from inside a live sbxagent sandbox
# (sbxclaude, sbxcodex, sbxcursor or sbxpi).
# Keep EXPECTED_* in sync with the pinned installs in kits/*/spec.yaml.
set -euo pipefail

# Which kit built this sandbox. The wrapper names every sandbox
# <kit>-<slug>-<hash>, so the prefix is the kit name and the command to rerun.
KIT_NAME="${SANDBOX_NAME:-$(hostname)}"
KIT_NAME="${KIT_NAME%%-*}"
[[ -n "${KIT_NAME}" ]] || KIT_NAME="sbxclaude"

EXPECTED_SBX_VERSION="v0.39.0"
EXPECTED_RUFF_VERSION="0.16.2"
EXPECTED_YAMLLINT_VERSION="1.38.0"
EXPECTED_MARKDOWNLINT_VERSION="0.23.2"
EXPECTED_CSPELL_VERSION="10.0.1"
EXPECTED_PLAYWRIGHT_VERSION="1.62.1"
EXPECTED_MERMAID_VERSION="11.16.0"
EXPECTED_CONTEXT7_MCP_VERSION="4.0.0"
EXPECTED_GITHUB_MCP_VERSION="1.11.0"
EXPECTED_PI_VERSION="0.84.4"
EXPECTED_CONTEXT7_PI_VERSION="0.1.2"

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

# Kit-specific files below are written by `setup:`, which only re-runs on a
# rebuild. A sandbox created before a kit change has none of them, and a bare
# "file missing" would read as a broken test rather than a stale sandbox.
REBUILD_HINT="sandbox may predate this kit change — rebuild: '${KIT_NAME} rm' then '${KIT_NAME}'"

# ---------------------------------------------------------------------------
# sbxclaude and sbxcodex. Both kits install the same guard filter at the same
# path, so its behaviour is tested once, here. What each host CLI *does* with
# the verdict differs (Claude Code ends the turn; Codex replaces the tool
# result and lets the model continue), and each registers the hook its own way
# — those live in the per-kit blocks below.
# ---------------------------------------------------------------------------
if [[ "${KIT_NAME}" == "sbxclaude" || "${KIT_NAME}" == "sbxcodex" ]]; then

# Network-block escalation hook. A blocked request must produce a stop verdict
# with the remedy that fits the block type, rather than leaving the agent free
# to work around it. Keep these in sync with kits/network-block.jq and the
# `Network-block escalation hook` setup command in each kit's spec.yaml.
GUARD_FILTER="/usr/local/lib/sbxagent/network-block.jq"

[[ -s "${GUARD_FILTER}" ]] ||
	fail "guard filter is missing: ${GUARD_FILTER} (${REBUILD_HINT})"
pass "guard filter is installed"

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

# A local deny needs the opposite remedy to a default-deny: deny rules take
# precedence over allow rules, so the rule has to be removed, not allowed round.
check_guard_blocks "a PostToolUseFailure block" \
	'{"tool_name":"Bash","tool_input":{"command":"curl -f https://blocked.test"},"error":"Blocked by local rule for blocked.test"}' \
	'sbx policy rm network --resource "blocked.test"'

LOCAL_VERDICT="$(guard '{"tool_name":"Bash","tool_input":{"command":"curl -f https://blocked.test"},"error":"Blocked by local rule for blocked.test"}')" ||
	fail "guard failed on the local-rule payload"
if jq -r '.systemMessage' <<<"${LOCAL_VERDICT}" | grep -Fq 'sbx policy allow'; then
	fail "local-rule message must not suggest 'sbx policy allow': ${LOCAL_VERDICT}"
fi
pass "local-rule message removes the deny instead of allowing round it"

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

# Local readers stay exempt, including git's read-only subcommands — a
# `git diff` of the spec prints the block strings the filter itself contains.
check_guard_ignores "a git diff of the spec" \
	'{"tool_name":"Bash","tool_input":{"command":"git diff kits/sbxcodex/spec.yaml"},"tool_response":{"stdout":"Blocked by network policy: domain foo.test"}}'

# ...but mentioning one of those filenames must never buy a network command an
# exemption. Without this, `curl https://blocked # spec.yaml` silently suppresses
# the notice and the agent is free to do exactly what the guard forbids.
check_guard_blocks "a blocked curl whose command mentions spec.yaml" \
	'{"tool_name":"Bash","tool_input":{"command":"curl -sS https://evil.test  # see spec.yaml"},"tool_response":{"stderr":"Blocked by network policy: domain evil.test"}}' \
	'sbx policy allow network "evil.test"'

check_guard_blocks "a blocked download writing to spec.yaml" \
	'{"tool_name":"Bash","tool_input":{"command":"wget -O kits/sbxcodex/spec.yaml https://x.test/s"},"tool_response":{"stderr":"Blocked by network policy: domain x.test"}}' \
	'sbx policy allow network "x.test"'

# A local read chained to a network call is still a network call.
check_guard_blocks "a blocked curl chained after a CLAUDE.md read" \
	'{"tool_name":"Bash","tool_input":{"command":"cat CLAUDE.md && curl https://y.test"},"error":"Blocked by local rule for y.test"}' \
	'sbx policy rm network --resource "y.test"'

# A blocked WebFetch must never be exempted just because its URL happens to
# contain one of the self-reference filenames — only a Bash read of the
# actual file is exempt. These run under sbxcodex too: Codex has no WebFetch
# tool, so there they prove the filter is byte-identical, not tool coverage.
check_guard_blocks "a blocked WebFetch of a URL containing AGENTS.md" \
	'{"tool_name":"WebFetch","tool_input":{"url":"https://example.com/AGENTS.md"},"tool_response":{"content":"Blocked by local rule for x.test"}}' \
	'sbx policy rm network --resource "x.test"'

check_guard_blocks "a blocked WebFetch of a URL containing CLAUDE.md" \
	'{"tool_name":"WebFetch","tool_input":{"url":"https://example.com/CLAUDE.md"},"tool_response":{"content":"Blocked by local rule for y.test"}}' \
	'sbx policy rm network --resource "y.test"'

check_guard_blocks "a blocked WebFetch of a URL containing spec.yaml" \
	'{"tool_name":"WebFetch","tool_input":{"url":"https://example.com/spec.yaml"},"tool_response":{"content":"Blocked by local rule for z.test"}}' \
	'sbx policy rm network --resource "z.test"'

fi # end guard-filter tests

# ---------------------------------------------------------------------------
# sbxclaude only. The guard is registered as Claude Code hook JSON in
# /etc/claude-code/managed-settings.json, and ~/.claude.json is Claude Code's
# MCP config. sbxcodex registers both differently — see its block below.
# ---------------------------------------------------------------------------
if [[ "${KIT_NAME}" == "sbxclaude" ]]; then

MANAGED_SETTINGS="/etc/claude-code/managed-settings.json"

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

# User-scope MCP servers baked into every sandbox via
# kits/sbxclaude/files/home/.claude.json, so Context7 and GitHub MCP tools are
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

fi # end sbxclaude-only

# ---------------------------------------------------------------------------
# sbxcodex only. MCP servers live in ~/.codex/config.toml (TOML, appended by
# `setup:`) rather than in a JSON file shipped under files/home/, because the
# codex parent kit rewrites that file on every create. The guard is registered
# separately, in admin-tier /etc/codex/requirements.toml.
# ---------------------------------------------------------------------------
if [[ "${KIT_NAME}" == "sbxcodex" ]]; then

# Admin-tier hook registration. Asserted structurally rather than by grep:
# `allow_managed_hooks_only` only works as a top-level key, and a copy that
# drifted under [hooks] would still grep clean while doing nothing.
REQUIREMENTS_TOML="/etc/codex/requirements.toml"

[[ -s "${REQUIREMENTS_TOML}" ]] ||
	fail "${REQUIREMENTS_TOML} is missing (${REBUILD_HINT})"
pass "${REQUIREMENTS_TOML} exists"

python3 - "${REQUIREMENTS_TOML}" <<'PYTOML' ||
import sys
import tomllib

with open(sys.argv[1], "rb") as fh:
    req = tomllib.load(fh)

if req.get("allow_managed_hooks_only") is not True:
    sys.exit("allow_managed_hooks_only is not a top-level key set to true")
if req.get("features", {}).get("hooks") is not True:
    sys.exit("the hooks feature is not pinned on")
try:
    command = req["hooks"]["PostToolUse"][0]["hooks"][0]["command"]
except (KeyError, IndexError):
    sys.exit("no PostToolUse hook is registered")
if "network-block.jq" not in command:
    sys.exit("PostToolUse does not run the guard: " + command)
PYTOML
	fail "${REQUIREMENTS_TOML} does not register the guard as a managed hook (${REBUILD_HINT})"
pass "guard is registered as a managed PostToolUse hook"

CODEX_TOML="${HOME}/.codex/config.toml"

[[ -s "${CODEX_TOML}" ]] || fail "${CODEX_TOML} is missing (${REBUILD_HINT})"
pass "${CODEX_TOML} exists"

# Guards against the same root-ownership defect the entrypoint chown works
# around for ~/.codex (see kits/sbxcodex/spec.yaml, issue #415).
[[ -O "${CODEX_TOML}" ]] || fail "${CODEX_TOML} is not owned by the sandbox user"
pass "${CODEX_TOML} is owned by the sandbox user"

# The replicated parent seeding step must have run — without it Codex has no
# yolo-mode config at all, which is the exact failure #415 causes.
grep -Fqx 'approval_policy = "never"' "${CODEX_TOML}" ||
	fail "${CODEX_TOML} lacks the parent's yolo-mode keys (${REBUILD_HINT})"
pass "replicated parent seeding step ran"

grep -Fqx '[mcp_servers.context7]' "${CODEX_TOML}" ||
	fail "context7 MCP server missing from ${CODEX_TOML}"
grep -Fq "@upstash/context7-mcp@${EXPECTED_CONTEXT7_MCP_VERSION}" "${CODEX_TOML}" ||
	fail "context7 MCP server is not pinned to ${EXPECTED_CONTEXT7_MCP_VERSION} in ${CODEX_TOML}"
pass "context7 MCP server is pinned to ${EXPECTED_CONTEXT7_MCP_VERSION}"

# Codex's `env` table is static — it does not expand ${VAR} — so the token is
# inherited by name via env_vars and exported by the entrypoint instead.
grep -Fqx '[mcp_servers.github]' "${CODEX_TOML}" ||
	fail "github MCP server missing from ${CODEX_TOML}"
grep -Fqx 'command = "github-mcp-server"' "${CODEX_TOML}" ||
	fail "github MCP server has no github-mcp-server command in ${CODEX_TOML}"
grep -Fqx 'env_vars = ["GITHUB_PERSONAL_ACCESS_TOKEN"]' "${CODEX_TOML}" ||
	fail "github MCP server does not inherit GITHUB_PERSONAL_ACCESS_TOKEN in ${CODEX_TOML}"
pass "github MCP server is configured for local stdio"

fi # end sbxcodex-only

# ---------------------------------------------------------------------------
# sbxcursor only. MCP servers ship as files/home/.cursor/mcp.json — the cursor
# parent only writes ~/.cursor/cli-config.json, a different file, so a shipped
# copy is safe here in a way it is not for Codex. The other assertions cover the
# parent steps this kit has to replicate because sbx drops them (issue #415);
# for Cursor that includes the parent's `setup.files:` entry, not just its
# install and startup steps.
# ---------------------------------------------------------------------------
if [[ "${KIT_NAME}" == "sbxcursor" ]]; then

CURSOR_JSON="${HOME}/.cursor/mcp.json"

[[ -s "${CURSOR_JSON}" ]] || fail "${CURSOR_JSON} is missing (${REBUILD_HINT})"
jq -e . "${CURSOR_JSON}" >/dev/null 2>&1 ||
	fail "${CURSOR_JSON} is not valid JSON"
pass "${CURSOR_JSON} is valid JSON"

# Guards against root-owned files under ~/.cursor after the kit's files/home/
# tree is copied in (see kits/sbxcursor/spec.yaml, issue #415).
[[ -O "${CURSOR_JSON}" ]] || fail "${CURSOR_JSON} is not owned by the sandbox user"
pass "${CURSOR_JSON} is owned by the sandbox user"

jq -e --arg v "@upstash/context7-mcp@${EXPECTED_CONTEXT7_MCP_VERSION}" \
	'.mcpServers.context7.args | index($v) != null' \
	"${CURSOR_JSON}" >/dev/null ||
	fail "context7 MCP server missing or wrong pinned version in ${CURSOR_JSON}"
pass "context7 MCP server is pinned to ${EXPECTED_CONTEXT7_MCP_VERSION}"

# Cursor expands "${env:VAR}", not "${VAR}" — the Claude form would be passed
# through literally. Must stay byte-identical to the repo's .cursor/mcp.json:
# the sandbox mounts the project, so project scope sits alongside this user
# scope. `make lint` enforces that pairing.
jq -e '.mcpServers.github.command == "github-mcp-server"
	and (.mcpServers.github.args | index("stdio") != null)
	and .mcpServers.github.env.GITHUB_PERSONAL_ACCESS_TOKEN == "${env:GITHUB_TOKEN}"' \
	"${CURSOR_JSON}" >/dev/null ||
	fail "github MCP server missing or misconfigured in ${CURSOR_JSON}"
pass "github MCP server is configured for local stdio"

# Replicated parent step. Without it, agent traffic does not go through the
# forward proxy.
CURSOR_CLI_CONFIG="${HOME}/.cursor/cli-config.json"
jq -e '.network.useHttp1ForAgent == true' "${CURSOR_CLI_CONFIG}" >/dev/null 2>&1 ||
	fail "${CURSOR_CLI_CONFIG} does not force HTTP/1.1 for the agent (${REBUILD_HINT})"
pass "cli-config.json forces HTTP/1.1 so traffic uses the forward proxy"

# Replicated parent step. `--yolo` does not bypass the workspace trust gate, so
# without this every interactive session opens with a trust prompt. The slug is
# the workspace path with the leading slash dropped and the rest turned into "-".
CURSOR_TRUST_SLUG="${PWD#/}"
CURSOR_TRUST_FILE="${HOME}/.cursor/projects/${CURSOR_TRUST_SLUG//\//-}/.workspace-trusted"
[[ -s "${CURSOR_TRUST_FILE}" ]] ||
	fail "workspace is not pre-trusted: ${CURSOR_TRUST_FILE} missing (${REBUILD_HINT})"
pass "workspace is pre-trusted, so the TUI skips its trust prompt"

# Cursor gates MCP servers behind an approval separate from workspace trust,
# and `--yolo` bypasses neither. Without the kit's startup step both servers
# report "not loaded (needs approval)". The startup step soft-fails on purpose,
# so this assertion is what catches a silent regression.
CURSOR_MCP_APPROVALS="$(dirname "${CURSOR_TRUST_FILE}")/mcp-approvals.json"
jq -e . "${CURSOR_MCP_APPROVALS}" >/dev/null 2>&1 ||
	fail "MCP servers are not pre-approved: ${CURSOR_MCP_APPROVALS} missing or invalid (${REBUILD_HINT})"
# Entries are "<name>-<hash of the server definition>", not bare names, so this
# has to match on the prefix.
for server in context7 github; do
	jq -e --arg s "${server}" 'any(.[]; startswith($s + "-"))' \
		"${CURSOR_MCP_APPROVALS}" >/dev/null ||
		fail "${server} is not in ${CURSOR_MCP_APPROVALS}"
done
pass "context7 and github are pre-approved, so the TUI does not prompt for them"

fi # end sbxcursor-only

# ---------------------------------------------------------------------------
# sbxpi only. Pi has no parent kit and no MCP support at all — there is no MCP
# config file to check here. Its config lives directly under
# files/home/.pi/agent/ (models.json, settings.json), and GitHub operations go
# through `git`/`gh` on PATH instead of a registered MCP server.
# ---------------------------------------------------------------------------
if [[ "${KIT_NAME}" == "sbxpi" ]]; then

check_tool_version pi "${EXPECTED_PI_VERSION}" pi --version
# Pi has no MCP, so GitHub work goes through the `gh` CLI instead.
check_tool gh gh --version

# Pi's file-search tool downloads `fd` from GitHub releases at first launch
# unless it finds `fd` or `fdfind` on PATH — unpinned, and network traffic on
# a cold start. The apt-installed `fdfind` is what suppresses that.
command -v fdfind >/dev/null 2>&1 || command -v fd >/dev/null 2>&1 ||
	fail "neither fd nor fdfind is on PATH, so Pi will download fd at launch (${REBUILD_HINT})"
pass "fd is preinstalled, so Pi fetches nothing at first launch"

PI_MODELS_JSON="${HOME}/.pi/agent/models.json"
PI_SETTINGS_JSON="${HOME}/.pi/agent/settings.json"

[[ -s "${PI_MODELS_JSON}" ]] || fail "${PI_MODELS_JSON} is missing (${REBUILD_HINT})"
jq -e . "${PI_MODELS_JSON}" >/dev/null 2>&1 ||
	fail "${PI_MODELS_JSON} is not valid JSON"
pass "${PI_MODELS_JSON} is valid JSON"

[[ -O "${PI_MODELS_JSON}" ]] || fail "${PI_MODELS_JSON} is not owned by the sandbox user"
pass "${PI_MODELS_JSON} is owned by the sandbox user"

jq -e '.providers.openrouter.modelOverrides["qwen/qwen3-coder"].compat.openRouterRouting.only == ["deepinfra"]' \
	"${PI_MODELS_JSON}" >/dev/null ||
	fail "openrouter provider is missing the DeepInfra routing pin in ${PI_MODELS_JSON}"
pass "openrouter is pinned to DeepInfra for qwen/qwen3-coder"

[[ -s "${PI_SETTINGS_JSON}" ]] || fail "${PI_SETTINGS_JSON} is missing (${REBUILD_HINT})"
jq -e . "${PI_SETTINGS_JSON}" >/dev/null 2>&1 ||
	fail "${PI_SETTINGS_JSON} is not valid JSON"
pass "${PI_SETTINGS_JSON} is valid JSON"

[[ -O "${PI_SETTINGS_JSON}" ]] || fail "${PI_SETTINGS_JSON} is not owned by the sandbox user"
pass "${PI_SETTINGS_JSON} is owned by the sandbox user"

jq -e '.defaultProvider == "openrouter" and .defaultModel == "qwen/qwen3-coder"' \
	"${PI_SETTINGS_JSON}" >/dev/null ||
	fail "defaultProvider/defaultModel are not set to openrouter/qwen3-coder in ${PI_SETTINGS_JSON}"
pass "settings.json defaults to openrouter / qwen/qwen3-coder"

# `pi install` merges this key into the shipped settings.json at build time —
# the kit does not hand-write it, so this is what proves that step ran and its
# result survived. Without the entry Pi loads no Context7 tools at all.
jq -e --arg v "npm:@upstash/context7-pi@${EXPECTED_CONTEXT7_PI_VERSION}" \
	'.packages | index($v) != null' \
	"${PI_SETTINGS_JSON}" >/dev/null ||
	fail "context7 package missing or wrong pinned version in ${PI_SETTINGS_JSON} (${REBUILD_HINT})"
pass "context7 Pi package is pinned to ${EXPECTED_CONTEXT7_PI_VERSION}"

# Pre-installed at build time, so first launch fetches nothing from the network.
[[ -d "${HOME}/.pi/agent/npm/node_modules" ]] ||
	fail "context7 package was not materialised under ~/.pi/agent/npm (${REBUILD_HINT})"
pass "context7 package is materialised on disk, not fetched at first launch"

fi # end sbxpi-only

echo "All ${TESTS} toolchain tests passed."
