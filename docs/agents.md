# Agent differences

How the four sandboxes diverge: how strongly each enforces a blocked network
request, how each wires up the GitHub MCP server, and how Codex signs in. See
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
before a project's config applies. Trust also lets a project's `.pi/mcp.json`
add MCP servers or override the kit's — a stdio server is an arbitrary command
— and switch `autoEnableCodemode` back on, and a project's `+builtin:mcp` beats
a user-level `-builtin:mcp`. The extension file itself is root-owned and
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
`sbxpi` extension tool's response. On `sbxpi` the guard deliberately stays
`bash`-only, so the gap is real there too: GitHub MCP results are not
inspected, whether the model calls an `mcp__github__*` tool directly or a
codemode script you turned on calls one.

`sbxcodex` is also the strictest sandbox in one respect: its admin-tier
`requirements.toml` sets `allow_managed_hooks_only`, so Codex ignores *all*
user, project, session and plugin hooks in there. That is deliberate — it stops
the guard being crowded out — but it is stricter than `sbxclaude`, which leaves
user hooks alone.

## GitHub MCP server

All four kits install
[`github-mcp-server`](https://github.com/github/github-mcp-server), and this
repo and those kits run it locally over stdio.

On `sbxpi` the server's tools are **deferred**: none is declared to the model
until Pi's `tool_search` tool, which the kit turns on with
`"defaultTools": ["+tool_search"]`, loads the ones a task needs. That keeps the
large GitHub toolset out of every request. The kit also sets
`"autoEnableCodemode": false`. That stops MCP from switching codemode on by
itself; it does not keep codemode away from the server. Once you enable
codemode, for example with `pi -t +codemode`, its scripts can call the deferred
GitHub tools too. `sbxpi` has no parent kit to inherit the `github` credential
from, so it declares it itself; `gh` and `git` over HTTPS use the same proxy
credential as the server.

Pi's `/share` command also works once the `github` secret is bound. It uploads
the session as a secret GitHub gist. A secret gist is unlisted, not private:
anyone with the link can read it. And the transcript holds everything the
session saw — prompts, file contents, tool output, and any secret a command
printed. Read a session before you share it, and remove the gist with
`gh gist delete <id>` once it has served its purpose.

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
| [`kits/sbxpi/files/home/.pi/agent/mcp.json`](../kits/sbxpi/files/home/.pi/agent/mcp.json) | `"${GITHUB_TOKEN}"` | Pi |

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
fine-grained PAT carrying the **Copilot Requests** permission, which `sbx`
keeps as a separate `copilot` secret
(see [docker/sbx-releases#231](https://github.com/docker/sbx-releases/issues/231)).
Running the server locally is a design choice, not a workaround: it talks to
the ordinary REST API at `api.github.com`, which the credential proxy already
authenticates with the `github` secret, so no Copilot PAT is needed.

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

Check it with `claude mcp list`, `codex mcp list`, `agent mcp list` or
`pi mcp list`; the `github` line should report connected, both on the host and
inside the sandbox. In a shell from `sbxpi exec bash`, which skips the
entrypoint's export, run `GITHUB_TOKEN="$GH_TOKEN" pi mcp list`.

## Codex login

`sbxcodex` signs in with either an OpenAI API key or a ChatGPT subscription.
The parent `codex` kit owns the flow: it runs on the host, and the sandbox only
ever sees a placeholder. The first run asks you to approve the `openai`
credential; say yes, or Codex starts logged out.

If a subscription login is not picked up, reset it:

```bash
sbx secret rm openai
sbx secret set openai --oauth
sbxcodex rm
sbxcodex
```

A stored API key beats OAuth, and a secret only takes effect when the sandbox
is created — hence all four lines.
