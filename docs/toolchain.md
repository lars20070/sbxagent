# Toolchain

What is installed inside every sandbox, which versions are pinned, and how to
change them. See [README.md](../README.md) to get a sandbox running first.

## What each sandbox gets

Docker's agent kit (the *workload*) brings the agent and a small base: `git`,
`gh`, `curl`, `jq`, `ripgrep`, `tree` and Docker. Every kit in this repo adds
the same tools on top (three of them only with `SBXAGENT_LITE=false`):

| Tool | For | Version | `SBXAGENT_LITE` |
| --- | --- | --- | --- |
| `pandoc`, `python3`, `python3-yaml`, `shellcheck`, `uv`, `node`, `npm` | shell and script work | tracks the distribution | either |
| `ruff`, `yamllint` | Python lint and format, YAML lint | pinned below | either |
| `markdownlint-cli2`, `cspell` | Markdown and spelling checks | pinned below | either |
| `sbx`, `kit-tck` | daemon-free kit commands; `kit-tck` checks a built kit, so `make validate` runs in-sandbox | pinned below | either |
| `fd-find` (`fd`, `fdfind`) | `sbxpi` only, from Docker's Pi workload; the file finder Pi expects | tracks the workload | either |
| `go` | Go builds; the version `go.mod` asks for is fetched on demand | tracks the distribution | either |
| Playwright, with headless Chromium | loading pages and taking screenshots of UI changes | pinned below | `false` |
| `mmdc` (mermaid-cli) | rendering Mermaid to PNG or SVG, reusing that same Chromium | pinned below | `false` |
| XeTeX (`texlive-xetex`, `texlive-fonts-recommended`, `texlive-latex-extra`, `lmodern`) | `pandoc … --pdf-engine=xelatex` PDF output | tracks the distribution | `false` |

The environment is the same in every sandbox. Your project is mounted as the
workspace, so edits land on your real files. Each sandbox also gets a
wrapper-managed state folder under
`${XDG_STATE_HOME:-~/.local/state}/sbxagent/traces/<slug>-<hash>/`, keyed by the
project directory and shared read-only across every agent's sandbox for it,
with a per-agent subfolder (`sbxclaude/`, `sbxcodex/`, …) that only that
agent's own sandbox can write. Alongside it, a sibling
`${XDG_STATE_HOME:-~/.local/state}/sbxagent/messageboards/<slug>-<hash>/` is
mounted read-write and shared by every agent's sandbox for the project — one
folder, no per-agent subfolders (see
[messageboard.md](messageboard.md)). Set `CROSS_SANDBOX_VISIBILITY=false` when
creating a sandbox to mount only its own trace subfolder, hiding the other
agents' and the message board; an existing board on the host is not deleted.
Other projects' folders are never mounted, and `rm` leaves all of this in
place. Inside you get passwordless `sudo` and
Docker, every host CPU (at most 16 on a Linux arm64 host, where `sbx` caps
the default), and half the host memory capped at 32 GiB.

Network access is an allowlist, not the open internet, unless the sandbox was
created with `NETWORK_ALLOWLIST=false` — that stacks the `mixins/open-network`
mixin kit, which allows every host (deny rules still win). Every kit rewrites
GitHub SSH remotes to HTTPS for the sandbox user, so `git fetch` works on the
allowlisted port 443 without changing the host checkout. On `sbxclaude`,
`sbxcodex` and `sbxpi`, a root-owned guard catches a blocked request and prints
the remedy that fits it. A default-deny needs `sbx policy allow`. A local deny
rule needs `sbx policy rm`, because an allow rule cannot override a deny. An
organisation policy needs IT, because the user cannot lift it. See
[agents.md](agents.md) for how strongly each agent enforces it.

The agent itself runs with approvals bypassed on `sbxclaude`, `sbxcodex` and
`sbxcursor`. Context7 and GitHub MCP servers are registered whatever the
project's own MCP config says — except on `sbxpi`. There Context7 ships as a
native Pi package rather than an MCP server, and the GitHub MCP server, next
to `gh`, is registered in `~/.pi/agent/mcp.json`, which a trusted project's
`.pi/mcp.json` can override.

Each kit is a schema v3 mixin: a descriptor, `kits/<command>/<command>.yaml`,
and a content recipe, `kits/<command>/<command>.dockerfile`, which `sbx`
builds with Docker Buildx. `scripts/sbxagent` wraps the `sbx` CLI and stacks
the kit on its agent's workload (`claude`, `codex`, `cursor`, or
`docker.io/sbx/pi`), building, or re-attaching to, one sandbox per project, named
`<command>-<project_directory>-<hash>`. The hash comes from the
canonical absolute path, so same-named directories do not share a sandbox, and
the command name is the prefix, so the four agents never collide.

## Pinned versions

Directly installed tools are pinned so sandbox rebuilds and CI lint use the
same known versions. All four kits pin the same shared versions; `sbxpi`
adds Pi's Context7 package.

| Tool | Where pinned | Version |
| --- | --- | --- |
| `sbx` (in-sandbox) | `kits/*/*.dockerfile` | `v0.54.0` (SHA-256 verified) |
| `kit-tck` | `kits/*/*.dockerfile`, CI | `3.0.0-m.12` (SHA-256 verified) |
| `docker/sandbox-kit` frontend | `# syntax=` line of `kits/*/*.yaml`, `mixins/*/*.yaml` | `3` at `sha256:8561468d…` (kit-spec `v3.0.0-m.12`) |
| `ruff` | `kits/*/*.yaml` | `0.16.8` |
| `yamllint` | `kits/*/*.yaml` | `1.38.0` |
| `markdownlint-cli2` | `kits/*/*.yaml`, CI | `0.23.3` |
| `cspell` | `kits/*/*.yaml`, CI | `10.3.3` |
| `playwright` (+ Chromium) | `kits/*/*.yaml` | `1.63.0` |
| `mermaid-cli` (`mmdc`) | `kits/*/*.yaml` | `11.17.0` |
| Context7 MCP | `.mcp.json`, `.cursor/mcp.json`, `.vscode/mcp.json`, `kits/*/` MCP configs | `4.1.1` |
| `github-mcp-server` | `kits/*/*.dockerfile` | `1.12.2` (SHA-256 verified) |
| `@upstash/context7-pi` | `kits/sbxpi/sbxpi.yaml` | `0.1.3` |
| `esbuild` (TypeScript lint) | `Makefile` | `0.28.2`, fetched via `npx` |

Intentional exceptions that stay on latest:

- Docker's workloads, `claude`, `codex`, `cursor` and `docker.io/sbx/pi`,
  float: each new sandbox gets the latest, and the wrapper passes
  `--pull always` so a cached copy is refreshed. That includes the agents
  themselves, Pi among them. The CI runner images, the packages those runners
  provide, and the host `sbx` install float too
- the host's own `github-mcp-server` comes from Homebrew and floats; only the
  in-sandbox copy is pinned, so the two can drift a version apart
- apt packages, installed by each kit's install hooks, track the
  distribution
- `go` comes from Debian's `golang-go` and is deliberately not pinned.
  A project's `go.mod` is the pin: since Go 1.21, `GOTOOLCHAIN=auto` fetches
  the version it names from `proxy.golang.org`, which every kit allowlists.
  A kit pin would be a second pin that never wins

To bump a pin:

1. Update the version in **all four** kits. Binaries fetched at build time
   (`sbx`, `github-mcp-server`, `kit-tck`) and their SHA-256 checksums live
   in the recipe, `kits/<kit>/<kit>.dockerfile`, which is byte-identical in
   every kit (`make lint` checks it). Tools installed at create time live in
   the descriptor, `kits/<kit>/<kit>.yaml`. The `sbx` digest is also pinned
   as `SBX_SHA256` in `.github/workflows/release.yml`, next to
   `SBX_VERSION`; bump both there too, or the release workflow refuses the
   download.
2. Keep the `tests/toolchain_test.sh` expectations in sync.
3. Rebuild the sandboxes.
4. Run `make lint`, `make test-unit` and `make validate`, then
   `make test-toolchain AGENT=<agent>` once per agent.

The frontend on each descriptor's `# syntax=` line is pinned by digest
because it produces the published bytes. Bump it deliberately, to the
kit-spec version the pinned `sbx` bundles, and move `kit-tck` with it.

## Rebuild after kit changes

Remove and re-create the sandbox to apply changes to the kit:

```bash
sbxclaude rm   # confirms (y/N)
sbxclaude      # recreates from the kit and attaches
```

Pin bumps in `kits/` only take effect after this rebuild, and so
do the create-time settings `SBXAGENT_LITE`, `CROSS_SANDBOX_VISIBILITY` and
`NETWORK_ALLOWLIST`.

A rebuild also picks up the newest workload. `sbx` reads each agent's login
from the credentials stored on the host, so a rebuild needs no new sign-in.

## Repo version

The repo version lives in `VERSION`, and `sbx<agent> version` prints it.
`make lint` fails if it disagrees with any kit `version:` or with
`CHANGELOG.md`'s latest release.
