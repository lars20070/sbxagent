# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- The baked-in `github` MCP server now runs `github-mcp-server` `1.11.0`
  locally over stdio instead of calling GitHub's hosted server at
  `api.githubcopilot.com`. The hosted endpoint is a Copilot endpoint and needs
  a fine-grained PAT with the Copilot Requests permission, so it rejected
  tokens that work fine for `git` and `gh` with
  `401 unauthorized: AuthenticateToken authentication failed`
  ([docker/sbx-releases#231](https://github.com/docker/sbx-releases/issues/231)).
  The local server talks to `api.github.com`, which the credential proxy
  already authenticates, so `sbx secret set github` is now the only credential
  the GitHub MCP tools need.
- Network allowlist: `api.githubcopilot.com:443` replaced by
  `api.github.com:443`.
- `.mcp.json`, `.cursor/mcp.json`, and `.vscode/mcp.json` define `github` as
  the same local stdio server, so the repo's project scope and the kit's user
  scope no longer disagree about the endpoint. All four configs read
  `GITHUB_PERSONAL_ACCESS_TOKEN` from `${GITHUB_TOKEN}`; the sandbox entrypoint
  points that at the proxy-managed `github` sentinel so one definition works
  both on the host and in the sandbox. The host now needs
  `brew install github-mcp-server`.

## [0.1.0] - 2026-08-22

### Added

- Initial Docker Sandbox Kit for running Claude Code with Docker, passwordless
  `sudo`, and the host project mounted as the workspace.
- `sbxclaude` wrapper with per-project sandbox naming and commands to attach,
  create, remove, inspect, execute commands, validate the kit, and inspect
  network policy.
- Interactive and piped command execution with appropriate TTY and stdin
  handling.
- Pre-installed `jq`, `ripgrep`, `curl`, Python 3, ShellCheck, Ruff,
  yamllint, markdownlint-cli2, and CSpell tooling.
- Pre-installed Playwright with headless Chromium, so the agent can load
  pages, take screenshots, and read console output to verify UI changes
  before reporting them done.
- Pre-installed mermaid-cli (`mmdc`), reusing the existing Playwright
  Chromium, so the agent can render Mermaid diagrams to PNG/SVG from the
  terminal.
- In-sandbox `sbx` CLI (pinned release, architecture-matched, checksum
  verified) for daemon-free kit commands (`version`, `kit validate`,
  `kit inspect`, `kit pack`), so the kit can be validated from inside the
  sandbox.
- Agent instructions covering the sandbox environment, the limits of the
  in-sandbox `sbx`, and the pre-installed toolchain.
- Network-block escalation hook: when the sandbox network policy blocks a
  request, the agent's turn now ends and the host to allow is printed to your
  terminal, instead of the agent quietly working around the block. Installed
  as root-owned managed settings so the agent cannot disable it with an
  ordinary file edit.
- ELI5 output style, available to Claude Code inside the sandbox.
- Installation, usage, shell-access, rebuild, and direct-`sbx` documentation.
- Install instructions and host requirements for Linux alongside macOS.
- `sbxclaude help` and `sbxclaude name` work before the `sbx` CLI is installed,
  and the commands that need it report both install recipes when it is missing.
- Context7 and GitHub MCP servers baked into every sandbox as user-scope MCP
  servers (`sbxclaude/files/home/.claude.json`), so they are available
  regardless of whether the target project defines its own. The GitHub server
  authenticates with a `GITHUB_TOKEN` custom secret stored on the host.

### Changed

- Sandbox size follows the host (every CPU, half the memory capped at 32 GiB)
  instead of a fixed 8 CPUs and 24 GB, so the kit also starts on smaller hosts.
  Uncomment `resources:` in `sbxclaude/spec.yaml` to pin a fixed size.

- Pin directly installed sandbox and CI tooling to exact versions (in-sandbox
  `sbx` `v0.39.0` with SHA-256 verification, Ruff `0.16.2`, yamllint
  `1.38.0`, markdownlint-cli2 `0.23.2`, CSpell `10.0.1`) and pin Context7
  MCP to `4.0.0`. The CI validate job still installs the latest `sbx` CLI so
  schema drift surfaces immediately.

### Fixed

- The wrapper no longer needs GNU `readlink -f`, so the symlink install works on
  macOS releases before 12.3.
- Sandbox names for projects whose directory name contains non-ASCII characters
  are derived consistently, and no longer risk aborting the wrapper.
- Repository-defined GitHub and Context7 MCP servers are reachable through the
  sandbox network allowlist.
- `git fetch` against GitHub SSH remotes works inside the sandbox by rewriting
  them to HTTPS on the allowlisted port 443, without changing the host
  checkout's remote URL.

### Security

- Claude Code runs without `--dangerously-skip-permissions`.
- Network access is default-deny with an explicit host allowlist.
- Unused OpenRouter and Pi hosts are no longer allowed network access.
- The kit ships no pre-approved Bash permissions, so tool use inside the
  sandbox still goes through Claude Code's own approval.
- Sandbox removal retains `sbx` confirmation, and invalid wrapper commands fail
  before invoking `sbx`.
