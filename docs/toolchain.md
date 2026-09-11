# Toolchain

What is installed inside every sandbox, which versions are pinned, and how to
change them. See [README.md](../README.md) to get a sandbox running first.

## What each sandbox gets

Every kit installs the same tools:

| Tool | For | Version |
| --- | --- | --- |
| `curl`, `jq`, `python3`, `python3-yaml`, `ripgrep`, `shellcheck`, `tree` | shell and script work | tracks the distribution |
| `ruff`, `yamllint` | Python lint and format, YAML lint | pinned below |
| `markdownlint-cli2`, `cspell` | Markdown and spelling checks | pinned below |
| Playwright, with headless Chromium | loading pages and taking screenshots of UI changes | pinned below |
| `mmdc` (mermaid-cli) | rendering Mermaid to PNG or SVG, reusing that same Chromium | pinned below |
| `sbx` | daemon-free kit commands — `version`, `kit validate`, `kit inspect`, `kit pack` — so `make validate` runs in-sandbox | pinned below |
| `fd-find` | `sbxpi` only; the file finder Pi expects | tracks the distribution |

The environment is the same in every sandbox. Your project is mounted as the
workspace, so edits land on your real files. Inside you get passwordless
`sudo` and Docker, every host CPU, and half the host memory capped at 32 GiB.

Network access is an allowlist, not the open internet. Every kit rewrites
GitHub SSH remotes to HTTPS for the sandbox user, so `git fetch` works on the
allowlisted port 443 without changing the host checkout. On `sbxclaude`,
`sbxcodex` and `sbxpi`, a root-owned guard catches a blocked request and prints
the remedy that fits it. A default-deny needs `sbx policy allow`. A local deny
rule needs `sbx policy rm`, because an allow rule cannot override a deny. An
organisation policy needs IT, because the user cannot lift it. See
[agents.md](agents.md) for how strongly each agent enforces it.

The agent itself runs with approvals bypassed on `sbxclaude`, `sbxcodex` and
`sbxcursor`. Context7 and GitHub MCP servers are registered whatever the
project's own MCP config says — except on `sbxpi`, where Pi supports no MCP at
all: Context7 ships as a native Pi package, and GitHub work goes through `git`
and `gh`.

Each kit spec lives in `kits/<command>/spec.yaml`. `scripts/sbxagent` wraps the
`sbx` CLI and builds, or re-attaches to, one sandbox per project, named
`<command>-<project_directory>-<hash>`. The hash comes from the
canonical absolute path, so same-named directories do not share a sandbox, and
the command name is the prefix, so the four agents never collide.

To give a sandbox a fixed CPU and memory size instead of the host-derived
default above, uncomment the `resources:` block in that kit's `spec.yaml` and
rebuild.

## Pinned versions

Directly installed tools are pinned so sandbox rebuilds and CI lint use the
same known versions. All four kits pin the same shared versions; `sbxpi`
adds two of its own, for Pi and its Context7 package.

| Tool | Where pinned | Version |
| --- | --- | --- |
| `sbx` (in-sandbox) | `kits/*/spec.yaml` | `v0.42.1` (SHA-256 verified) |
| `ruff` | `kits/*/spec.yaml` | `0.16.2` |
| `yamllint` | `kits/*/spec.yaml` | `1.38.0` |
| `markdownlint-cli2` | `kits/*/spec.yaml`, CI | `0.23.2` |
| `cspell` | `kits/*/spec.yaml`, CI | `10.0.1` |
| `playwright` (+ Chromium) | `kits/*/spec.yaml` | `1.62.1` |
| `mermaid-cli` (`mmdc`) | `kits/*/spec.yaml` | `11.16.0` |
| Context7 MCP | `.mcp.json`, `.cursor/mcp.json`, `.vscode/mcp.json`, `kits/*/` MCP configs | `4.0.0` |
| `github-mcp-server` | `kits/*/spec.yaml`, except `sbxpi` | `1.11.0` (SHA-256 verified) |
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
  track the distribution. That includes `fd-find`, which Pi would otherwise
  download unpinned at first launch

To bump a pin:

1. Update the version, and the `sbx` checksums, in **all four**
   `kits/*/spec.yaml`. The `sbx` digest is also pinned as `SBX_SHA256` in
   `.github/workflows/release.yml`, next to `SBX_VERSION`; bump both there
   too, or the release workflow refuses the download.
2. Keep the `tests/toolchain_test.sh` expectations in sync.
3. Rebuild the sandboxes.
4. Run `make lint`, `make test-unit` and `make validate`, then
   `make test-toolchain AGENT=<agent>` once per agent.

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
