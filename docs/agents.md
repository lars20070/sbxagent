# Agent differences

How the four sandboxes diverge: how strongly each enforces a blocked network
request, and how each wires up the GitHub MCP server. See
[README.md](../README.md) for the agent table itself.

## Network-block guard

The README table says only whether a guard runs. It does not say how strongly,
and two of the four carry a qualification:

- **soft** (`sbxcodex`) — the guard reports the blocked host and tells the
  agent to stop, but nothing makes it stop.
- **overridable** (`sbxpi`) — the guard stops the run, but the agent can
  unregister it, though not rewrite it.

The guard is not equally strong in each sandbox because the four CLIs offer
different hook outputs:

- `sbxclaude` **ends the turn**. Claude Code treats the guard's `continue:
  false` as a hard stop, registered as managed-settings hook JSON.
- `sbxcodex` **cannot force a stop**. The same guard runs as a managed
  `PostToolUse` hook, but Codex's documented behaviour for every hook output —
  `continue: false` and `decision: "block"` alike — is to replace the tool
  result and let the model continue. So the agent sees the blocked host and a
  firm instruction to stop, and the user sees how to lift the block, but
  nothing prevents the agent from carrying on.
- `sbxcursor` has **no guard**. Its post-execution hooks are observation-only
  and cannot even inject feedback. Its instructions still ask for a blocked host
  to be reported, with nothing enforcing it.
- `sbxpi` **ends the run, one tool call later**. A Pi extension applies the same
  filter in two phases, because a Pi `tool_result` handler can patch a result
  but not stop a run: the blocked command's output is replaced with the remedy,
  and the agent's *next* tool call is then refused with `terminate`. The
  practical effect matches `sbxclaude`, one beat behind.

  Unlike the others, this binding is **overridable**. Pi has no
  managed-settings tier, so the guard is registered in
  `~/.pi/agent/settings.json`, which the agent can edit. A mounted project's
  own `.pi/settings.json` can displace the `extensions` entry too, once you
  have trusted that project — the kit sets `defaultProjectTrust: "ask"`, so Pi
  prompts before a project's config applies. The extension file itself is
  root-owned and outside `$HOME`, so it can be unregistered but not rewritten.
  That is the accepted cost of honouring project config.

All three guards share one coverage gap: they match shell commands only, so a
block that surfaces solely in an MCP server's response — or, on `sbxpi`, in an
extension tool's response — is not caught.

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
kits, and Pi uses `git` and `gh` for GitHub work instead. The definition has to agree across MCP configs, because the
sandbox mounts the project, so the repo's project-scope entry sits alongside the
kit's user-scope one and the agent warns about conflicting endpoints if the two
disagree. `make lint` enforces the Cursor pair.

Each agent reads the token differently, and the syntax is not interchangeable:

| Config | Form | Read by |
| --- | --- | --- |
| [`.mcp.json`](../.mcp.json), [`.vscode/mcp.json`](../.vscode/mcp.json), [`kits/sbxclaude/files/home/.claude.json`](../kits/sbxclaude/files/home/.claude.json) | `"${GITHUB_TOKEN}"` | Claude Code |
| [`.cursor/mcp.json`](../.cursor/mcp.json), [`kits/sbxcursor/files/home/.cursor/mcp.json`](../kits/sbxcursor/files/home/.cursor/mcp.json) | `"${env:GITHUB_TOKEN}"` | Cursor |
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

So `sbx secret set github` above stays the only credential the sandbox needs,
and the real token never enters it.

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
