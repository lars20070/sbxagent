# Agent differences

How the four sandboxes diverge: how strongly each enforces a blocked network
request, and how each wires up the GitHub MCP server. See
[README.md](../README.md) for the agent table itself.

## Network-block guard

The README table says only whether a guard runs. It does not say how strongly.
The same guard ships in three of the four kits — the Cursor kit carries none —
and the CLIs accept different hook outputs, so it lands with different force in
each sandbox:

| Agent | Registered as | On a blocked request | Agent can switch it off |
| --- | --- | --- | --- |
| Claude Code | managed-settings hook JSON | Ends the turn — `continue: false` is a hard stop | No |
| Codex | managed `PostToolUse` hook | Replaces the tool result and tells the agent to stop. **Soft**: nothing enforces it | No |
| Cursor | Not registered — Cursor exposes no verified equivalent of the Claude Code hook JSON | Nothing. Its instructions still ask for a blocked host to be reported, with nothing enforcing it | No guard to switch off |
| Pi | Extension listed in `~/.pi/agent/settings.json` | Ends the run, one tool call later | **Yes**, by unregistering the extension |

Two rows need more than a cell.

**Why Codex is soft.** Its documented behaviour for every hook output —
`continue: false` and `decision: "block"` alike — is to replace the tool result
and let the model continue. So the agent sees the blocked host and a firm
instruction to stop, and the user sees how to lift the block, but nothing
prevents the agent from carrying on.

**Why Pi is overridable, and why it lags by one call.** Pi has no
managed-settings tier, so the guard is registered in
`~/.pi/agent/settings.json`, which the agent can edit. A mounted project's own
`.pi/settings.json` can displace the `extensions` entry too, once you have
trusted that project — the kit sets `defaultProjectTrust: "ask"`, so Pi prompts
before a project's config applies. The extension file itself is root-owned and
outside `$HOME`, so it can be unregistered but not rewritten. That is the
accepted cost of honouring project config.

The one-call lag is separate. A Pi `tool_result` handler can patch a result but
not stop a run, so the extension works in two phases: the blocked command's
output is replaced with the remedy, and the agent's *next* tool call is then
refused with `terminate`. The practical effect matches `sbxclaude`, one beat
behind.

All three guards match on the tool name: `Bash|WebFetch` on `sbxclaude`,
`^Bash$` on `sbxcodex`, and `bash` on `sbxpi`. They share one coverage gap as a
result. A block that surfaces solely in an MCP server's response — those tool
names start `mcp__` — is not caught, and neither is one that surfaces in a
`sbxpi` extension tool's response.

`sbxcodex` is also the strictest sandbox in one respect: its admin-tier
`requirements.toml` sets `allow_managed_hooks_only`, so Codex ignores *all*
user, project, session and plugin hooks in there. That is deliberate — it stops
the guard being crowded out — but it is stricter than `sbxclaude`, which leaves
user hooks alone.

## GitHub MCP server

Every kit installs [`github-mcp-server`](https://github.com/github/github-mcp-server),
and this repo and every kit but `sbxpi` run it locally over stdio. `sbxpi` is
the exception: Pi has no built-in MCP, so that kit registers no MCP servers at
all — the binary is installed there only to keep the toolchain identical across
kits, and Pi uses `git` and `gh` for GitHub work instead.

One definition has to work on the host and inside the sandbox alike. The
sandbox mounts the project, so the repo's project-scope entry sits alongside
the kit's user-scope one, and the agent reports conflicting endpoints if the
two disagree. `make lint` enforces the Cursor pair.

Each agent reads the token differently, and the syntax is not interchangeable:

| Config | Form | Read by |
| --- | --- | --- |
| [`.mcp.json`](../.mcp.json), [`kits/sbxclaude/files/home/.claude.json`](../kits/sbxclaude/files/home/.claude.json) | `"${GITHUB_TOKEN}"` | Claude Code |
| [`.cursor/mcp.json`](../.cursor/mcp.json), [`kits/sbxcursor/files/home/.cursor/mcp.json`](../kits/sbxcursor/files/home/.cursor/mcp.json) | `"${env:GITHUB_TOKEN}"` | Cursor |
| [`.vscode/mcp.json`](../.vscode/mcp.json) | `"${env:GITHUB_TOKEN}"` | VS Code |
| `~/.codex/config.toml`, written by `kits/sbxcodex/spec.yaml` | `env_vars = ["GITHUB_PERSONAL_ACCESS_TOKEN"]` | Codex |

Codex is the odd one out: its `env` table is a static map with no `${VAR}`
expansion, so the token is named rather than interpolated, and the entrypoint
exports it.

`GITHUB_TOKEN` means something different on each side, and that is what lets one
definition serve both:

| | `GITHUB_TOKEN` is | reaches GitHub as |
| --- | --- | --- |
| Host | your own PAT | itself |
| Sandbox | a proxy-managed sentinel, exported by the entrypoint | the real token, swapped in by the proxy |

So the `sbx secret set github` step in [Host setup](setup.md) stays the only
credential the sandbox needs, and the real token never enters it.

The export covers only the session the entrypoint starts. A `claude` you launch
by hand from `sbxclaude exec bash` does not inherit it.

The GitHub-hosted server at `https://api.githubcopilot.com/mcp/` is
deliberately **not** used. That endpoint is a Copilot endpoint and needs a
fine-grained PAT carrying the **Copilot Requests** permission; a token that
works fine for `git` and `gh` is rejected there with
`401 unauthorized: AuthenticateToken authentication failed`
(see [docker/sbx-releases#231](https://github.com/docker/sbx-releases/issues/231)).
Running the server locally sidesteps that, because it talks to the ordinary
REST API at `api.github.com`, which the credential proxy already authenticates.

### Host setup

The sandbox installs the binary itself. On the host, install it once and export
your token:

```bash
brew install github-mcp-server          # Linux: see the project's releases page
export GITHUB_TOKEN="$(gh auth token)"  # or your own PAT, in your shell profile
```

If you previously stored a custom secret for the hosted Copilot endpoint, it is
now unused — retire it so it cannot shadow anything later:

```bash
sbx secret ls                      # find its placeholder
sbx secret rm --placeholder <the sbx-cs-… value>
```

Check it with `claude mcp list`, `codex mcp list` or `agent mcp list`;
the `github` line should report connected, both on the host and inside the
sandbox.
