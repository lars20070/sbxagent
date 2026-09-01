# sbxclaude

`sbxclaude` runs Claude Code in an isolated sandbox, with a fixed toolchain
already installed. Think of it as a customized version of [`sbx run claude`](https://docs.docker.com/ai/sandboxes/agents/claude-code/).

## What it does

Each sandbox gets:

- Claude Code, with `--dangerously-skip-permissions` turned off
- `jq`, `ripgrep`, `curl`, Python 3, and ShellCheck
- `ruff` and `yamllint` as Python development tools
- `markdownlint-cli2` and `cspell` for documentation checks
- Playwright, with headless Chromium, so the agent can load pages and
  screenshot UI changes itself
- mermaid-cli (`mmdc`), reusing that same Chromium, so the agent can render
  Mermaid diagrams to PNG/SVG from the terminal
- An `sbx` CLI for daemon-free kit commands (`version`, `kit validate`,
  `kit inspect`, `kit pack`) so `make validate` works inside the sandbox
- Passwordless `sudo`, and Docker, inside the sandbox
- A network allowlist, not open internet access
- A root-owned hook that stops the agent on a blocked request and prints the
  `sbx policy allow` command to run
- Your project mounted as the workspace — edits land on your real files
- GitHub SSH remotes rewritten to HTTPS inside the sandbox, so `git fetch`
  works on the allowlisted port 443 without changing the host checkout
- Context7 and GitHub MCP servers, so the agent can pull current library docs
  and use GitHub's MCP tools regardless of the project's own MCP configuration

The kit spec lives in `sbxclaude/spec.yaml`. `scripts/sbxclaude` is a wrapper
around the `sbx` CLI that builds (or re-attaches to) one sandbox per project,
named `sbxclaude-<project_directory>-<hash>`. The hash comes from the
canonical absolute path, so same-named directories do not share a sandbox.

Sandbox size follows the host: every host CPU, and half the host memory capped
at 32 GiB. To pin a fixed size instead, uncomment the `resources:` block in
`sbxclaude/spec.yaml` and rebuild.

## Install

You need macOS 14 or later on Apple silicon, or Linux on x86_64 or aarch64 with
KVM available. Docker Desktop is not required. Install the `sbx` CLI, sign in,
and put `sbxclaude` on your `PATH`.

[macOS:](https://docs.docker.com/ai/sandboxes/install/#install-on-macos)

```bash
brew trust docker/tap
brew install docker/tap/sbx
sbx login
ln -s /path_to_sbxclaude_repo/scripts/sbxclaude ~/.local/bin/sbxclaude
```

[Linux:](https://docs.docker.com/ai/sandboxes/install/#linux)

```bash
curl -fsSL https://get.docker.com | sudo REPO_ONLY=1 sh
sudo apt-get install docker-sbx
sudo usermod -aG kvm "$USER" && newgrp kvm
sbx login
ln -s /path_to_sbxclaude_repo/scripts/sbxclaude ~/.local/bin/sbxclaude
```

## Use

Run `sbxclaude` from any project directory:

```bash
sbxclaude
```

The first run builds a sandbox for that directory and attaches to it. Later
runs re-attach to the same sandbox, so your work carries over.

To enter the sandbox with a Bash shell:

```bash
sbxclaude exec bash
```

### Commands

| Command | Effect |
| --- | --- |
| `sbxclaude` | Attach; create the sandbox first if missing |
| `sbxclaude create` | Build the sandbox without attaching |
| `sbxclaude rm` | Remove the sandbox after confirmation |
| `sbxclaude name` | Print the derived sandbox name |
| `sbxclaude version` | Print the kit name and version |
| `sbxclaude exec CMD...` | Run a command inside the sandbox |
| `sbxclaude inspect` | Show the sandbox's state |
| `sbxclaude policy log` | Show the sandbox policy log |
| `sbxclaude policy check HOST` | Check sandbox network access to `HOST` |
| `sbxclaude kit validate` | Check the kit against the current schema |
| `sbxclaude help` | Show usage |

The wrapper accepts only these signatures. It does not forward prompts or
Claude flags. Use `sbx` and the name directly for
anything outside the table. For example

```bash
S="$(sbxclaude name)"
sbx inspect "${S}"
```

### Rebuild after kit changes

Remove and re-create the sandbox to apply changes to the kit:

```bash
sbxclaude rm   # confirms (y/N)
sbxclaude      # recreates from the kit and attaches
```

Pin bumps in `sbxclaude/spec.yaml` only take effect after this rebuild.

### Pinned toolchain versions

Directly installed tools are pinned so sandbox rebuilds and CI lint use the
same known versions:

| Tool | Where pinned | Version |
| --- | --- | --- |
| `sbx` (in-sandbox) | `sbxclaude/spec.yaml` | `v0.39.0` (SHA-256 verified) |
| `ruff` | `sbxclaude/spec.yaml` | `0.16.2` |
| `yamllint` | `sbxclaude/spec.yaml` | `1.38.0` |
| `markdownlint-cli2` | `sbxclaude/spec.yaml`, CI | `0.23.2` |
| `cspell` | `sbxclaude/spec.yaml`, CI | `10.0.1` |
| `playwright` (+ Chromium) | `sbxclaude/spec.yaml` | `1.62.1` |
| `mermaid-cli` (`mmdc`) | `sbxclaude/spec.yaml` | `11.16.0` |
| Context7 MCP | `.mcp.json`, `.cursor/mcp.json`, `.vscode/mcp.json`, `sbxclaude/files/home/.claude.json` | `4.0.0` |
| `github-mcp-server` | `sbxclaude/spec.yaml` | `1.11.0` (SHA-256 verified) |

Intentional exceptions that stay on latest:

- CI `validate` installs the latest host `sbx` CLI so schema drift fails CI
  as soon as a new schema ships
- `extends: claude`, the CI runner images, the packages those runners provide,
  and the host `sbx` install remain floating integration surfaces
- the host's own `github-mcp-server` comes from Homebrew and floats; only the
  in-sandbox copy is pinned, so the two can drift a version apart

To bump a pin: update the version (and sbx checksums) in the files above,
keep `tests/toolchain_test.sh` expectations in sync, then rebuild the
sandbox and run `make lint`, `make test-unit`, `make validate`, and
`make test-toolchain`.

### Git over HTTPS

Sandbox network policy allows `github.com:443` but not SSH port 22. The kit
rewrites `git@github.com:` and `ssh://git@github.com/` remotes to
`https://github.com/` for the sandbox user only, so `git fetch` works without
changing the host checkout's remote URL.

Public repositories need no extra setup. For private repositories, store a
GitHub token on the host so the credential proxy can inject it:

```bash
echo "$(gh auth token)" | sbx secret set github
```

### GitHub MCP server

Both the kit and this repo run [`github-mcp-server`](https://github.com/github/github-mcp-server)
locally over stdio. The definition is byte-identical in all four MCP configs —
[`.mcp.json`](.mcp.json), [`.cursor/mcp.json`](.cursor/mcp.json),
[`.vscode/mcp.json`](.vscode/mcp.json) and
[`sbxclaude/files/home/.claude.json`](sbxclaude/files/home/.claude.json) —
because the sandbox mounts the project, so the repo's project-scope entry sits
alongside the kit's user-scope one. Claude Code warns about conflicting
endpoints if the two disagree.

Both read `GITHUB_PERSONAL_ACCESS_TOKEN` from `${GITHUB_TOKEN}`, which means
something different on each side and is what lets one definition serve both:

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

#### Host setup

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

Check it with `claude mcp list`; the `github` line should read `✔ Connected`,
both on the host and inside the sandbox.
