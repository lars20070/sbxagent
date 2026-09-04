# Add `sbxpi`: a fourth kit running the Pi agent on OpenRouter → DeepInfra

## Context

This repo (`sbxagent`) wraps three coding agents — Claude Code, Codex,
Cursor — each as its own Docker Sandbox Kit (`kits/sbxclaude`,
`kits/sbxcodex`, `kits/sbxcursor`) plus a `scripts/sbx<agent>` symlink that
dispatches to a shared wrapper script. We want a fourth: `sbxpi`, running
the **Pi** agent (pi.dev), talking to **OpenRouter**, with model calls
pinned to route through **DeepInfra** specifically.

Two facts (checked against Docker's and Pi's own docs) shape the whole
design, and make `sbxpi` structurally different from the other three kits:

- **Docker Sandboxes has no built-in Pi agent kit.** The three existing
  kits each do `extends: claude` / `codex` / `cursor` and inherit a lot
  (network baseline, an agent-aware entrypoint) from that built-in parent.
  Pi isn't on Docker's supported-agent list, so `sbxpi` has **no
  `extends:`** — it builds straight on the generic, agent-less `Shell`
  template (`docker/sandbox-templates:shell-docker`) and sets up
  everything itself, network allowlist included.
- **Pi has no built-in MCP support.** Pi's own docs say so explicitly —
  its extension mechanism is native packages/skills, not MCP. So unlike
  the other three kits, `sbxpi` configures **no GitHub MCP server**. This
  is a real, permanent capability gap for this kit, not an oversight —
  state it plainly in the docs, don't paper over it.

A real, working reference exists for the Pi+OpenRouter+DeepInfra part: a
sibling repo, `md2okf` (github.com/lars20070/md2okf), has a `pi/` kit doing
exactly this shape of thing (different end task — it's a Markdown→wiki
compiler — but the kit mechanics are directly reusable). Clone that repo
into this session's scratchpad directory and keep it there as a read-only
reference throughout planning and implementation; its `pi/` subdirectory
is the part that matters. Its `skills/` folder and its `AGENTS.md` content
are 100% specific to that repo's own wiki-compiling task — **do not carry
those over**. Everything else (install mechanics, provider config shape,
credential wiring, network allowlist reasoning) is generic and worth
reusing.

**Model choice**: you asked for `Qwen/Qwen3-Coder-480B-A35B-Instruct-Turbo`
on DeepInfra, via the routing pin below. On OpenRouter that model's id is
`qwen/qwen3-coder` (DeepInfra's "Turbo" backend is one of the providers
behind it) — that's the id to use in config, not DeepInfra's own internal
name. **You're setting up BYOK yourself** on openrouter.ai (Settings →
Integrations → your DeepInfra key) — nothing in this repo needs to know
about that; the kit only ever holds `OPENROUTER_API_KEY`.

## The new kit: `kits/sbxpi/`

**`kits/sbxpi/spec.yaml`** (new). Same top-level shape as
`kits/sbxclaude/spec.yaml` (`name`, `version` matching the root `VERSION`
file — currently `0.2.0` — `displayName`, `description`, commented-out
`resources:`), but built like `md2okf/pi/spec.yaml` underneath:

- `sandbox.image: "docker/sandbox-templates:shell-docker"`, no `extends:`.
- `sandbox.entrypoint: [pi]` — the simple form. The other three kits wrap
  their entrypoint in a `chown`-fixing `sh -c` script, but only because of
  a specific bug ([docker/sbx-releases#415](https://github.com/docker/sbx-releases/issues/415))
  where `sbx` drops a *parent* kit's setup when a child kit defines its
  own `setup:`. `sbxpi` has no parent kit, so nothing to drop — the plain
  form is what `md2okf/pi/spec.yaml` actually runs in production.
  *(Verify once, after the first real build: `sbxpi exec ls -la
  ~/.pi/agent` — if files come out root-owned, add the same chown
  workaround the other three use.)*
- `agentInstructions.filename: AGENTS.md`, `content:` = the same generic
  "Sandbox environment / Preinstalled tools" blurb `kits/sbxclaude`
  already uses (copy it, drop nothing agent-specific), plus one added
  paragraph stating plainly that this kit has no GitHub MCP server and
  no MCP support at all, so use `git` directly.
- `permissions.network.allow` — has to be a **complete** list, not just
  extras (no parent kit to inherit a baseline from): `openrouter.ai`,
  `pi.dev`, `registry.npmjs.org:443`, `pypi.org:443`,
  `files.pythonhosted.org:443`, `cdn.playwright.dev:443`,
  `playwright.download.prss.microsoft.com:443`, `context7.com:443`,
  `github.com:443`, `github.githubassets.com:443`,
  `release-assets.githubusercontent.com:443` (for the `sbx` CLI download),
  and the apt/Docker mirrors `archive.ubuntu.com:80`,
  `security.ubuntu.com:80`, `ports.ubuntu.com:80`,
  `download.docker.com:443`. Deliberately **no** `api.github.com` /
  `gist.github.com*` — nothing in this kit calls them (no
  `github-mcp-server`, no `gh` CLI).
- `credentials`: one entry, identical in shape to `kits/sbxclaude`'s —
  `service: openrouter`, `apiKey.name: OPENROUTER_API_KEY`,
  `proxyManaged: true`, injected as `Authorization: Bearer %s` to
  `openrouter.ai`.
- `setup.install`: apt tools (curl, jq, python3, ripgrep, shellcheck,
  ca-certificates) → **the `sbx` CLI, pinned `v0.39.0`, checksums copied
  verbatim from `kits/sbxclaude/spec.yaml:127-156`** (verified those
  checksums are the real ones already in use elsewhere in this repo, not
  invented) → `ruff@0.16.2` / `yamllint@1.38.0` (uv tool install) →
  `markdownlint-cli2@0.23.2` + `cspell@10.0.1` → Playwright `1.62.1` +
  Chromium → mermaid-cli `11.16.0` wrapper (same four steps as
  `kits/sbxclaude`, byte-for-byte reusable) → **Pi itself**, pinned
  global npm install of `@earendil-works/pi-coding-agent`, using the
  proxy-config + 5-attempt retry wrapper from `md2okf/pi/spec.yaml`
  (npm-through-the-sandbox-proxy is flaky) → **Context7**, via `pi
  install "npm:@upstash/context7-pi@0.1.2"` (Pi's native package
  mechanism, not MCP — this is how every other kit's Context7 access gets
  its Pi-side equivalent). No `github-mcp-server` install step — nothing
  in this kit would ever call it.
  *(Verify the exact Pi version pin at implementation time —
  `npm view @earendil-works/pi-coding-agent version` — rather than
  trusting `md2okf`'s pin blindly; same for context7-pi.)*

**`kits/sbxpi/files/home/.gitconfig`** and
**`kits/sbxpi/files/workspace/.editorconfig`** — byte-identical copies of
`kits/sbxclaude`'s (this repo's `make lint` diffs every kit's copy against
sbxclaude's as the reference and fails otherwise).

**`kits/sbxpi/files/home/.pi/agent/AGENTS.md`** (new, generic — this is
the base file `agentInstructions.content` gets appended to):

```markdown
# Pi coding agent

You are Pi, a terminal coding agent, working inside a Docker Sandbox microVM
on the user's project. Follow the project's own conventions, tests, and
tooling first. Make focused changes, verify them before reporting done, and
ask before large or irreversible changes.
```

**`kits/sbxpi/files/home/.pi/agent/models.json`** (new):

```json
{
  "providers": {
    "openrouter": {
      "baseUrl": "https://openrouter.ai/api/v1",
      "api": "openai-completions",
      "apiKey": "$OPENROUTER_API_KEY",
      "modelOverrides": {
        "qwen/qwen3-coder": {
          "compat": {
            "openRouterRouting": {
              "only": ["deepinfra"],
              "allow_fallbacks": false
            }
          }
        }
      }
    }
  }
}
```

No top-level `models` array — deliberate, same reasoning as `md2okf`:
leaving it out lets Pi's built-in catalogue fill in `qwen/qwen3-coder`'s
real context/output-token limits (262K context, 64K output) instead of
generic small defaults. `allow_fallbacks: false` matters here specifically
because it stops OpenRouter silently falling back to a different backend
if DeepInfra ever has an issue — without it, a DeepInfra hiccup would
silently route to a different (non-BYOK) provider instead of failing loud.

**`kits/sbxpi/files/home/.pi/agent/settings.json`** (new):

```json
{
  "defaultProvider": "openrouter",
  "defaultModel": "qwen/qwen3-coder",
  "packages": ["npm:@upstash/context7-pi@0.1.2"]
}
```

No `skills/` directory — none of the other three kits ship one either.

## Wiring the new command into the rest of the repo

Same pattern as the existing three everywhere; add a fourth entry
alongside each:

- **`scripts/sbxagent`**: add `sbxpi) CLI="pi" ;;` to the dispatch `case`,
  and a fourth `ln -s ... sbxpi` hint line in the no-name-given error
  message.
- **`scripts/sbxpi`**: a new checked-in symlink to `sbxagent`, same as
  `scripts/sbxclaude` etc. (`ln -s sbxagent scripts/sbxpi && git add
  scripts/sbxpi`).
- **`Makefile`**: add `./scripts/sbxpi kit validate` to the `validate`
  target. (Everything else in the Makefile — `lint`'s name/version
  checks, `test-toolchain`'s `AGENT` parameter — is already glob-based or
  parameterized and needs no change.)
- **`tests/sbxagent_test.sh`**: add `sbxpi` to the `reject_wrong_name`
  expected-strings list; add a `PI_SCRIPT`/`run_pi`/`PI_KIT` block
  matching the **lighter Codex/Cursor spot-check style** (own name, own
  kit path, own `create` dispatch, help text names `pi`) rather than
  duplicating Claude's exhaustive first-kit block — the generic dispatch
  machinery it proves is already covered once; extend the 3-way
  distinctness check to 4-way.
- **`tests/toolchain_test.sh`**: add a `sbxpi`-only block (mirroring the
  existing per-kit `if` blocks) checking `pi` is on `PATH`, and that
  `~/.pi/agent/models.json` / `settings.json` exist, parse as JSON, and
  have the expected `openrouter` provider / `defaultProvider`. **Also**:
  the existing `github-mcp-server --version` check (currently
  unconditional, shared by all kits) needs to skip `sbxpi` specifically —
  this kit installs no such binary, on purpose.
- **`README.md`**: add `sbxpi` to — the intro's `sbx run <agent>` list,
  the "one script serves N commands" prose, the Mermaid diagram, the
  "Supported agents" table (new row: Pi / no parent kit / `pi` /
  `AGENTS.md` / `~/.pi/agent/{models,settings}.json` / no network-block
  guard), the install-symlink instructions, the usage example, "all N
  commands take the same signatures," "all N kits pin the same versions."
  For the GitHub-MCP-config table and the `<agent> mcp list` sentence:
  **leave `sbxpi` out of both** (a row that's "n/a" in every column adds
  noise, not information) and add one plain sentence instead: Pi has no
  MCP support, so this kit configures no GitHub MCP server.
- **`AGENTS.md`** (repo root): update the Repository Map's "There are
  three" sentence and kit list, the `scripts/sbxagent` bullet's symlink
  list, and the "`make validate` — validates all three kits" line (reword
  to "every kit" so it doesn't need updating again for a fifth).
- **`CHANGELOG.md`**: new `## [Unreleased]` / `### Added` entry describing
  `sbxpi` (no parent kit, no MCP support, Context7 via native package
  instead) — match the existing entries' voice/detail level.
- **`.cspell.json`**: add `sbxpi`, `deepinfra`, `earendil` to `words`.

## Cleanup found along the way

All three existing kits (`kits/sbxclaude/spec.yaml`,
`kits/sbxcodex/spec.yaml`, `kits/sbxcursor/spec.yaml`) carry a stray,
unused network-allowlist entry:
```yaml
      # Pi agent development
      - "pi.dev"
```
This looks like leftover prep for exactly this work, sitting on kits that
have nothing to do with Pi. Remove all three (verified via grep — it's in
all three files, not just Claude's). `sbxpi` is the one kit that
legitimately needs `pi.dev`. Worth its own small `### Security`
`CHANGELOG.md` line, mirroring the `0.1.0` entry that already recorded
removing "unused OpenRouter and Pi hosts" once before.

## Verification

- `make lint` — must pass with the new kit in place (name/version sync,
  shared-file byte-identity, cspell, shellcheck/bash -n on the new setup
  script, markdownlint on the new `AGENTS.md`).
- `make validate` — validates all four kits' `spec.yaml` against the
  Sandbox Kit schema, no Docker/network needed.
- `make test-unit` — exercises the new `sbxpi` dispatch block.
- `make test-toolchain AGENT=pi` — builds a real `sbxpi` sandbox and runs
  the smoke test; this is the real proof the kit boots, installs Pi
  correctly, and can reach `openrouter.ai`. Needs a live sandbox, so run
  it last, after `lint`/`validate`/`test-unit` are clean.
- Manual check once built: `sbxpi exec pi --list-models openrouter` (or
  equivalent) to confirm `qwen/qwen3-coder` resolves and the DeepInfra
  routing pin is actually in effect — plus confirm your OpenRouter BYOK
  setup (the dashboard side) is picking it up rather than falling back to
  pooled credits.
