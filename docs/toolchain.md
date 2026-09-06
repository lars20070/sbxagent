# Toolchain

What is installed inside every sandbox, which versions are pinned, and how to
change them. See [README.md](../README.md) to get a sandbox running first.

## What each sandbox gets

Each sandbox gets:

- The agent itself, running with approvals bypassed inside the sandbox
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
- `sbxclaude`, `sbxcodex` and `sbxpi`: a root-owned guard that catches a
  blocked request and prints the remedy that actually fits it — `sbx policy
  allow` for a default-deny, `sbx policy rm` for a local deny rule (deny beats
  allow, so allowing round it does nothing), or contact IT for an organisation
  policy the user cannot lift — ending the turn on `sbxclaude`, ending the run
  one tool call later on `sbxpi`, and advising the agent to stop on `sbxcodex`
- Your project mounted as the workspace — edits land on your real files
- GitHub SSH remotes rewritten to HTTPS inside the sandbox, so `git fetch`
  works on the allowlisted port 443 without changing the host checkout
- Context7 and GitHub MCP servers, so the agent can pull current library docs
  and use GitHub's MCP tools regardless of the project's own MCP configuration
  — except on `sbxpi`, where Pi supports no MCP at all: Context7 ships there as
  a native Pi package instead, and GitHub work goes through `git` and `gh`

Each kit spec lives in `kits/<command>/spec.yaml`, and `scripts/sbxagent` is a
wrapper around the `sbx` CLI that builds (or re-attaches to) one sandbox per
project, named `<command>-<project_directory>-<hash>`. The hash comes from the
canonical absolute path, so same-named directories do not share a sandbox, and
the command name is the prefix, so the four agents never collide.

Sandbox size follows the host: every host CPU, and half the host memory capped
at 32 GiB. To pin a fixed size instead, uncomment the `resources:` block in
that kit's `spec.yaml` and rebuild.

## Pinned versions

Directly installed tools are pinned so sandbox rebuilds and CI lint use the
same known versions. All four kits pin the same shared versions; `sbxpi`
adds two of its own, for Pi and its Context7 package.

| Tool | Where pinned | Version |
| --- | --- | --- |
| `sbx` (in-sandbox) | `kits/*/spec.yaml` | `v0.39.0` (SHA-256 verified) |
| `ruff` | `kits/*/spec.yaml` | `0.16.2` |
| `yamllint` | `kits/*/spec.yaml` | `1.38.0` |
| `markdownlint-cli2` | `kits/*/spec.yaml`, CI | `0.23.2` |
| `cspell` | `kits/*/spec.yaml`, CI | `10.0.1` |
| `playwright` (+ Chromium) | `kits/*/spec.yaml` | `1.62.1` |
| `mermaid-cli` (`mmdc`) | `kits/*/spec.yaml` | `11.16.0` |
| Context7 MCP | `.mcp.json`, `.cursor/mcp.json`, `.vscode/mcp.json`, `kits/*/` MCP configs | `4.0.0` |
| `github-mcp-server` | `kits/*/spec.yaml` | `1.11.0` (SHA-256 verified) |
| `@earendil-works/pi-coding-agent` | `kits/sbxpi/spec.yaml` | `0.84.4` |
| `@upstash/context7-pi` | `kits/sbxpi/spec.yaml` | `0.1.2` |
| `esbuild` (TypeScript lint) | `Makefile` | `0.28.2`, fetched via `npx` |

Intentional exceptions that stay on latest:

- CI `validate` installs the latest host `sbx` CLI so schema drift fails CI
  as soon as a new schema ships
- `extends: claude`, `extends: codex` and `extends: cursor`, the CI runner
  images, the packages those runners provide, and the host `sbx` install remain
  floating integration surfaces
- the host's own `github-mcp-server` comes from Homebrew and floats; only the
  in-sandbox copy is pinned, so the two can drift a version apart
- `sbxpi` has no parent kit to float, but its base image
  `docker/sandbox-templates:shell-docker` is a moving tag, and its apt packages
  — including `fd-find`, which Pi would otherwise download unpinned at first
  launch — track the distribution

To bump a pin: update the version (and sbx checksums) in **all four**
`kits/*/spec.yaml`, keep `tests/toolchain_test.sh` expectations in sync, then
rebuild the sandboxes and run `make lint`, `make test-unit`, `make validate`,
and `make test-toolchain AGENT=<agent>` for each.

## Rebuild after kit changes

Remove and re-create the sandbox to apply changes to the kit:

```bash
sbxclaude rm   # confirms (y/N)
sbxclaude      # recreates from the kit and attaches
```

Pin bumps in `kits/*/spec.yaml` only take effect after this rebuild.

Codex signs itself in on first run and stores that login inside its sandbox, so
a `sbxcodex rm` costs you one sign-in on the next start. Claude and Cursor are
re-seeded automatically.

## Repo version

The repo version lives in `VERSION`, and `sbx<agent> version` prints it.
`make lint` fails if it disagrees with any kit `version:` or with
`CHANGELOG.md`'s latest release.
