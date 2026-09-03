# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- `github.githubassets.com:443` on every kit's network allowlist, so github.com
  pages render with their CSS and JavaScript in the sandbox's Playwright
  browser instead of loading as unstyled HTML.
- A network-block escalation hook for `sbxcodex`, sharing the filter
  `sbxclaude` already uses. It is registered as a managed Codex `PostToolUse`
  hook in root-owned `/etc/codex/requirements.toml`, which user and project
  config cannot override. **It is weaker than the `sbxclaude` guard**: Codex
  replaces the blocked tool's result with the stop notice and lets the model
  continue, rather than ending the turn, because no Codex hook output ends a
  turn. The agent is told the host to allow and instructed to stop; nothing
  forces it to. Both guards match shell commands only, so a block surfacing
  solely in an MCP response is not caught.
- `sbxcodex` now sets `allow_managed_hooks_only`, so Codex ignores all user,
  project, session and plugin hooks in that sandbox and only the managed guard
  runs. This is stricter than `sbxclaude`, which leaves user hooks alone.

### Changed

- `sbxclaude` gains an `ALLOW_WEB` switch (default `true`) in its own setup
  step, which merges `permissions.deny` for the built-in `WebSearch` and
  `WebFetch` tools into the same admin-tier
  `/etc/claude-code/managed-settings.json` as the network-block escalation
  hook when flipped to `false`. Flip it in `kits/sbxclaude/spec.yaml` and
  rebuild the kit to deny both tools — they call out from Anthropic's
  servers, not the sandbox, so they would otherwise side-step the sbx
  network allow list.
- `sbxcodex` gains a matching `ALLOW_WEB` switch (default `true`). Codex has
  only one hosted internet tool, `web_search` (no separate fetch tool); when
  flipped to `false` the setup step prepends `web_search = "disabled"` to
  `~/.codex/config.toml`, before any `[table]` header, so the key stays top
  level regardless of `SBX_CRED_OPENAI_MODE`. Flip it in
  `kits/sbxcodex/spec.yaml` and rebuild the kit to deny it.
- `sbxcursor` now launches Cursor's CLI as `agent` rather than `cursor-agent`.
  Cursor made `agent` the primary entrypoint on 2026-01-08 and kept
  `cursor-agent` only as a backward-compatible alias, which it now prints a
  deprecation tip for. The sbx kit name is unaffected — `sbx run cursor` and
  `extends: cursor` are a different layer and unchanged. The Cursor CLI stays
  deliberately unpinned; it auto-updates in place, so a pin would not hold.

### Fixed

- The network-block guard's `self_reference` exemption no longer lets a network
  command suppress a real block. It matched any Bash command mentioning
  `AGENTS.md`, `CLAUDE.md`, `spec.yaml`, `network-block` or `toolchain_test`,
  so `curl https://blocked  # see spec.yaml` returned "no action" and the agent
  never saw the stop notice — the one outcome the guard exists to prevent. The
  exemption now also requires the command to show no sign of network egress, so
  a command that both reads one of those files and reaches out fails safe and
  fires. Local readers, including `git diff` and `git show`, stay exempt.
  Applies to `sbxclaude` and `sbxcodex`.
- The guard no longer tells the user to run `sbx policy allow` for a block
  caused by a local **deny** rule. Deny rules take precedence over allow rules,
  so that advice could never work; the message now points at `sbx policy ls
  --wide` and `sbx policy rm network --resource "<host>"` (with the `--sandbox`
  form for a sandbox-scoped rule) instead. Default-deny blocks still get
  `sbx policy allow`, and organisation-policy blocks still say to contact IT.
  The README and each kit's agent instructions were overstating this too, and
  now name all three remedies.

## [0.2.0] - 2026-09-01

### Added

- `sbxcodex` and `sbxcursor`, running Codex and Cursor on the same toolchain,
  network allowlist and agent instructions as `sbxclaude`. Each gets its own
  sandbox and its own credentials, so all three can run against one project at
  the same time.
- One script, `scripts/sbxagent`, serving all three commands. It dispatches on
  the name it was invoked as, so `sbxclaude`, `sbxcodex` and `sbxcursor` are
  symlinks to it. Run directly, or copied to an unrecognised name, it refuses
  and prints the `ln -s` recipe rather than guessing an agent.
- MCP servers for the two new agents, in each one's native form: `sbxcodex`
  appends `[mcp_servers.*]` to `~/.codex/config.toml` from `setup:`, because its
  parent kit rewrites that file on every create; `sbxcursor` ships
  `files/home/.cursor/mcp.json`, and pre-approves both servers so Cursor does
  not prompt for them.

### Changed

- **Breaking — the install path moved.** `scripts/sbxclaude` is now a symlink to
  `scripts/sbxagent`. Re-link the wrapper, once per agent you want:

  ```bash
  ln -s /path_to_sbxagent_repo/scripts/sbxagent ~/.local/bin/sbxclaude
  ln -s /path_to_sbxagent_repo/scripts/sbxagent ~/.local/bin/sbxcodex
  ln -s /path_to_sbxagent_repo/scripts/sbxagent ~/.local/bin/sbxcursor
  ```

- **Breaking — delete existing sandboxes before the first rebuild.** The
  `sbxclaude` sandbox name is unchanged and the wrapper's attach path never
  consults the kit, so a leftover sandbox is silently re-attached with the old
  kit baked in. Remove them on the host first (`sbx ls`, then `sbx rm <name>`).
  Not `sbx reset` — that also wipes network policies and the `github` secret.
- The kit moved from `sbxclaude/` to `kits/sbxclaude/`, alongside
  `kits/sbxcodex/` and `kits/sbxcursor/`. The guard filter it installs moved
  from `/usr/local/lib/sbxclaude/` to `/usr/local/lib/sbxagent/`.
- The network-block escalation hook remains **`sbxclaude` only**. It is built on
  Claude Code's managed-settings hook JSON, and neither Codex nor Cursor exposes
  a verified equivalent. In those two sandboxes the agent is asked to report a
  blocked host, but nothing enforces it.
- The baked-in `github` MCP server now runs `github-mcp-server` `1.11.0`
  locally over stdio instead of calling GitHub's hosted server at
  `api.githubcopilot.com`. The hosted endpoint is a Copilot endpoint and needs
  a fine-grained PAT with the Copilot Requests permission, so it rejected
  tokens that work fine for `git` and `gh` with
  `401 unauthorized: AuthenticateToken authentication failed`
  ([docker/sbx-releases#231](https://github.com/docker/sbx-releases/issues/231)).
  The local server talks to `api.github.com`, which the credential proxy
  already authenticates, so `sbx secret set github` is now the only credential
  the GitHub MCP tools need. The host now needs `brew install github-mcp-server`.
- Network allowlist: `api.githubcopilot.com:443` replaced by
  `api.github.com:443`.
- Project-scope MCP configs (`.mcp.json`, `.cursor/mcp.json`,
  `.vscode/mcp.json`) now match their kit counterparts so the mounted project
  and user scope do not disagree about the endpoint.

### Removed

- `scripts/sbxclaude` as a real file. It is a symlink to `scripts/sbxagent`
  now, and `scripts/sbxagent` refuses to run under its own name.

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
