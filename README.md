# sbxagent

[![CI](https://github.com/lars20070/sbxagent/actions/workflows/ci.yml/badge.svg)](https://github.com/lars20070/sbxagent/actions/workflows/ci.yml)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/lars20070/sbxagent/badge)](https://scorecard.dev/viewer/?uri=github.com/lars20070/sbxagent)
[![Ask DeepWiki](https://deepwiki.com/badge.svg)](https://deepwiki.com/lars20070/sbxagent)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

`sbxagent` runs a coding agent in an isolated sandbox, with a fixed toolchain
already installed. Think of it as a customized version of
[`sbx run claude`](https://docs.docker.com/ai/sandboxes/agents/claude-code/), [`sbx run codex`](https://docs.docker.com/ai/sandboxes/agents/codex/) and so on.

A single script `sbxagent` serves four different commands — `sbxclaude`, `sbxcodex`, `sbxcursor` and
`sbxpi` — by dispatching on the name it was invoked as. Each gets its own
sandbox and its own credentials, so all four can run against the same project
at once.

```mermaid
flowchart LR
  subgraph IN[" "]
    direction TB
    PROJ["your project<br/>(host working tree)"]
    DRV["scripts/sbxclaude<br/>scripts/sbxcodex<br/>scripts/sbxcursor<br/>scripts/sbxpi"]
    KIT["kits/*/spec.yaml<br/>kits/*/files/"]
  end

  subgraph VM["sbx sandbox"]
    AGENT["Claude Code, Codex,<br/>Cursor, Pi CLI"]
    TOOLS["git, docker, rg, jq,<br/>ruff, playwright, ..."]
    PROXY["credential + network<br/>allowlist proxy"]
  end

  subgraph NET[" "]
    direction TB
    LLM("Anthropic, OpenAI, <br/>OpenRouter, Ollama, ...")
    GH("GitHub")
  end

  PROJ -.->|"mounted"| VM
  DRV -->|"creates / attaches"| VM
  KIT -->|"builds"| VM
  AGENT -.->|"runs"| TOOLS
  AGENT -->|"via proxy"| PROXY
  PROXY -->|"allowlisted"| LLM & GH
  AGENT ==>|"edits"| PROJ

  classDef data    fill:aliceblue,stroke:steelblue,stroke-width:2px,color:#10314F
  classDef host    fill:#FDF3E0,stroke:#B8860B,stroke-width:2px,color:#4A3405
  classDef helper  fill:#E3F2F1,stroke:#0E7C86,stroke-width:2px,color:#0B3D40
  classDef agent   fill:#FCE7E7,stroke:#B23A48,stroke-width:2px,color:#5A1015
  classDef ext     fill:#F0F0EE,stroke:#7A8482,stroke-width:1.5px,color:#3A4250
  class PROJ data
  class KIT,DRV host
  class TOOLS,PROXY helper
  class AGENT agent
  class GH,LLM ext
  style VM fill:#F6F6F5,stroke:#7A8482,stroke-width:1.5px
  style IN fill:none,stroke:none
  style NET fill:none,stroke:none
```

<br>*The wrapper (amber) builds the sandbox from the matching kit spec and attaches to it. Inside, the agent (red) uses the pinned toolchain (teal) and talks out only through the credential and network-allowlist proxy, which lets through the agent's own LLM API and GitHub (grey) and blocks everything else. Your project (blue) is mounted straight into the sandbox and edited in place.*

## Contents

- [Install](#install)
- [Quick start](#quick-start)
- [Commands](#commands)
- [Supported agents](#supported-agents)
- [Further documentation](#further-documentation)
- [Support](#support)

<br>

![sbxcodex quickstart](docs/assets/quickstart.gif)

## Install

You need macOS 14 or later on Apple silicon, or Linux on x86_64 or aarch64 with
KVM available. Docker Desktop is not required. Install the `sbx` CLI, sign in,
and link `scripts/sbxagent` onto your `PATH` once per agent you want.

> **sbx v0.42.1 is required.** sbx is
> experimental. A later version may break `sbxagent`.

[macOS:](https://docs.docker.com/ai/sandboxes/install/#install-on-macos)

```bash
brew trust docker/tap
brew install docker/tap/sbx
sbx login
```

[Linux:](https://docs.docker.com/ai/sandboxes/install/#linux)

```bash
curl -fsSL https://get.docker.com | sudo REPO_ONLY=1 sh
sudo apt-get install docker-sbx
sudo usermod -aG kvm "$USER" && newgrp kvm
sbx login
```

Then, on either platform:

```bash
ln -s /path_to_sbxagent_repo/scripts/sbxagent ~/.local/bin/sbxclaude
ln -s /path_to_sbxagent_repo/scripts/sbxagent ~/.local/bin/sbxcodex
ln -s /path_to_sbxagent_repo/scripts/sbxagent ~/.local/bin/sbxcursor
ln -s /path_to_sbxagent_repo/scripts/sbxagent ~/.local/bin/sbxpi
```

Link only the agents you want; each is independent. `sbxagent` deliberately has
no default agent — run it under its own name and it refuses, rather than
silently picking one for you.

## Quick start

Run the command for the agent you want, from any project directory:

```bash
sbxclaude     # or sbxcodex, sbxcursor, or sbxpi
```

The first run builds a sandbox for that directory and attaches to it. Later
runs re-attach to the same sandbox, so your work carries over.

To enter the sandbox with a Bash shell:

```bash
sbxclaude exec bash
```

## Commands

All four commands take the same signatures. `sbx<agent>` below is any of
`sbxclaude`, `sbxcodex`, `sbxcursor` or `sbxpi`.

| Command | Effect |
| --- | --- |
| `sbx<agent>` | Attach to the sandbox, creating it if missing |
| `sbx<agent> create` | Build the sandbox without attaching |
| `sbx<agent> rm` | Remove the sandbox after confirmation |
| `sbx<agent> name` | Print the derived sandbox name |
| `sbx<agent> version` | Print the kit name and version |
| `sbx<agent> exec CMD...` | Run a command inside the sandbox |
| `sbx<agent> inspect` | Show the sandbox's state |
| `sbx<agent> policy log` | Show the sandbox policy log |
| `sbx<agent> policy check HOST` | Check sandbox network access to `HOST` |
| `sbx<agent> kit validate` | Check the kit against the current schema |
| `sbx<agent> help` | Show usage |

The wrapper accepts only these signatures. It does not forward prompts or agent
flags. Use `sbx` and the name directly for anything outside the table. For
example

```bash
S="$(sbxclaude name)"
sbx inspect "${S}"
```

You can skip the wrapper altogether. Every release publishes the four kits to a
registry, so `sbx run <kit-ref>` builds the same sandbox — toolchain, network
policy, credentials and agent instructions — without cloning this repository.
You give up the per-project sandbox naming and every subcommand in the table
above. [docs/published-kits.md](docs/published-kits.md) names the packages,
shows how to verify the signature, and covers stacking your own kit on top.

## Supported agents

| Agent | Command | Instruction file | MCP config | Network-block guard |
| --- | --- | --- | --- | --- |
| Claude Code | `sbxclaude` | `CLAUDE.md` | `~/.claude.json` | yes |
| Codex | `sbxcodex` | `AGENTS.md` | `~/.codex/config.toml` | yes |
| Cursor | `sbxcursor` | `AGENTS.md` | `~/.cursor/mcp.json` | no |
| Pi | `sbxpi` | `AGENTS.md` | none | yes |

`sbxpi` is the odd one out twice over. It has **no parent kit** — `sbx` ships
no Pi agent, so the kit builds on the bare `shell-docker` template and installs
everything itself. And Pi has **no MCP support at all**, so the kit lists no
MCP config; its model and provider settings live in
`~/.pi/agent/models.json` and `~/.pi/agent/settings.json` instead.

A `yes` means a guard runs, not that it cannot be escaped.
[docs/agents.md](docs/agents.md) says how strong each one is, why the four CLIs
differ, and what every guard misses.

The wrapper also preserves each agent's native session traces in its
per-project state folder, where sibling agents can read them by default.
[docs/toolchain.md](docs/toolchain.md#session-traces) lists the paths and the
create-time privacy setting.

## Further documentation

| Guide | Covers |
| --- | --- |
| [docs/setup.md](docs/setup.md) | Host-side credentials: a GitHub token, an OpenRouter key, and optional local models through Ollama |
| [docs/toolchain.md](docs/toolchain.md) | What is installed in every sandbox, which versions are pinned, and how to rebuild after changing one |
| [docs/agents.md](docs/agents.md) | How strictly each agent enforces a blocked request, and how each wires up the GitHub MCP server |
| [docs/published-kits.md](docs/published-kits.md) | Running a kit from the registry without cloning this repository |

## Support

Bugs and questions go to the
[issue tracker](https://github.com/lars20070/sbxagent/issues).
