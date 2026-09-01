# Generalise `sbxclaude` into `sbxagent` (Claude Code, Codex, Cursor)

## Context

Today this repo wraps exactly one coding agent. `scripts/sbxclaude` builds a
per-project Docker Sandbox from `sbxclaude/spec.yaml`, which sets
`extends: claude`. Everything else in the kit — the toolchain installs, the
network allowlist, the agent instructions, the MCP servers — is agent-agnostic
and would serve Codex and Cursor equally well.

The goal is one script, `scripts/sbxagent`, invoked under three names:

```bash
ln -s /path_to_sbxagent_repo/scripts/sbxagent ~/.local/bin/sbxclaude
ln -s /path_to_sbxagent_repo/scripts/sbxagent ~/.local/bin/sbxcodex
ln -s /path_to_sbxagent_repo/scripts/sbxagent ~/.local/bin/sbxcursor
```

The script reads `basename "$0"` and picks the matching kit. Each kit is a
separate sandbox with its own credentials, so Claude and Codex can run against
the same repo at the same time.

### Verified: all three parents exist

Checked against the `sbx` v0.39.0 binary (embedded agent kits) and
<https://docs.docker.com/ai/sandboxes/agents/>. `extends: claude`,
`extends: codex` and `extends: cursor` are all valid. The embedded parents are:

| Parent | Image | Entrypoint | Instruction file | MCP config |
| --- | --- | --- | --- | --- |
| `claude` | `docker/sandbox-templates:claude-code-docker` | `claude --dangerously-skip-permissions` | `CLAUDE.md` | `~/.claude.json` (JSON, `mcpServers`) |
| `codex` | `docker/sandbox-templates:codex-docker` | `codex --dangerously-bypass-approvals-and-sandbox` | `AGENTS.md` | `~/.codex/config.toml` (TOML, `[mcp_servers.<name>]`) |
| `cursor` | `docker/sandbox-templates:cursor-agent-docker` | `cursor-agent --yolo` | `AGENTS.md` | `~/.cursor/mcp.json` (JSON, `mcpServers`) |

Other differences that the plan has to handle:

- **Codex rewrites its own config.** The `codex` parent's `setup:` writes
  `~/.codex/config.toml` and `~/.codex/auth.json` **unconditionally on every
  create**, branching on `SBX_CRED_OPENAI_MODE`. A `files/home/.codex/config.toml`
  we ship would be clobbered. MCP servers must be *appended* by a `setup:`
  command instead, the same way the parent appends its own `mcp-gateway` entry.
- **Cursor keeps auth in memory** (`AGENT_CLI_CREDENTIAL_STORE=memory`,
  `CURSOR_AUTH_TOKEN` injected per run) and seeds
  `~/.cursor/cli-config.json` with `onlyIfMissing: true`. Shipping
  `files/home/.cursor/mcp.json` is a different file, so it is safe.
- **The network-block guard is Claude-only.** It installs
  `/etc/claude-code/managed-settings.json` with Claude Code hook JSON. Codex and
  Cursor have no equivalent we have verified. Decision taken: ship
  `sbxcodex` / `sbxcursor` without it and document the gap; revisit later.

### Decisions taken

- Three standalone `spec.yaml` files, no generator. Simple to read; the cost is
  that a pin bump touches three files.
- Separate sandbox per agent: `sbxclaude-<slug>-<hash>`, `sbxcodex-<slug>-<hash>`,
  `sbxcursor-<slug>-<hash>`. Existing `sbxclaude-*` sandboxes keep their names,
  so nothing already on disk is orphaned.
- Codex and Cursor ship without the network-block escalation hook in v1.

### Main risk

`sbx` currently **drops the parent kit's `setup:` when the child kit defines its
own `setup:`** ([docker/sbx-releases#415](https://github.com/docker/sbx-releases/issues/415)),
which is why `sbxclaude/spec.yaml` already carries a `chown` entrypoint
workaround. For Codex that parent setup is what seeds `auth.json` — losing it
could break login outright. Stage 2 is a go/no-go spike on exactly this, before
any Codex work is written.

---

## Stage 1 — Rename and generalise the wrapper (no new agents)

Behaviour-preserving. At the end of this stage `sbxclaude` works exactly as it
does today, but the machinery is agent-parametrised.

### Layout

```
scripts/sbxagent            # the real script (git mv from scripts/sbxclaude)
scripts/sbxclaude -> sbxagent   # in-repo symlink, so tests and `make` exercise dispatch
kits/sbxclaude/spec.yaml    # git mv from sbxclaude/spec.yaml
kits/sbxclaude/files/...    # git mv from sbxclaude/files/
tests/sbxagent_test.sh      # git mv from tests/sbxclaude_test.sh
```

Use `git mv` so the rename is visible in history.

### `scripts/sbxagent`

Add an agent-resolution block just after `SCRIPT_DIR` / `REPO` are computed:

```bash
# Dispatch on the name we were invoked as, so one script serves sbxclaude,
# sbxcodex and sbxcursor. Take the basename of $0 BEFORE resolving symlinks:
# resolve_dir walks the chain to find the repo, which would erase the name the
# user typed.
SELF="$(basename "$0")"
case "${SELF}" in
sbxclaude | sbxcodex | sbxcursor) ;;
*)
	# Covers a direct `./scripts/sbxagent` run and any copy under another name.
	# Deliberately no default agent: silently picking one is worse than failing.
	echo "sbxagent: run this through an agent name, not directly." >&2
	echo "Link it onto your PATH, once per agent you want:" >&2
	echo "  ln -s ${SCRIPT_DIR}/sbxagent ~/.local/bin/sbxclaude   # Claude Code" >&2
	echo "  ln -s ${SCRIPT_DIR}/sbxagent ~/.local/bin/sbxcodex    # Codex" >&2
	echo "  ln -s ${SCRIPT_DIR}/sbxagent ~/.local/bin/sbxcursor   # Cursor" >&2
	echo "Then run sbxclaude, sbxcodex or sbxcursor." >&2
	exit 1
	;;
esac
```

Notes on this block:

- No `SBXAGENT_AGENT` escape hatch. Nothing needs one: `make validate`,
  `make test-toolchain` and the unit tests all go through the in-repo symlinks
  (`scripts/sbxclaude` and friends), which is also what makes dispatch covered
  by every test run.
- No default agent. A `sbxagent` that quietly behaved as `sbxclaude` would let
  you believe you were in Codex when you were not.
- The hint prints an absolute, copy-pasteable path, which is why the block sits
  after `SCRIPT_DIR` rather than at the very top.
- The catch-all also handles someone `cp`-ing the script to an unrelated name,
  which is the one real failure mode of basename dispatch.
- `help` / `-h` / `--help` are **not** exempt. The message above already is the
  help you need in that state, and exiting non-zero keeps the "this is not a
  usable command" signal honest.

Then derive everything from `${SELF}`:

- `KIT="${REPO}/kits/${SELF}"` (was `${REPO}/sbxclaude`)
- `KIT_NAME="${SELF}"` — this is the positional `sbx run`/`sbx create` operand,
  and must equal `name:` in that kit's `spec.yaml`. Rename the existing `AGENT`
  variable to `KIT_NAME`; `AGENT` now reads as ambiguous.
- `SANDBOX="${SELF}-${SLUG:+${SLUG}-}${HASH}"`
- `die()` prefixes with `${SELF}`, not the literal `sbxclaude`.
- `usage()` is no longer a `<<'EOF'` heredoc — it interpolates `${SELF}` and the
  underlying CLI name. Add a small map for the "use X directly" line:
  `sbxclaude`→`claude`, `sbxcodex`→`codex`, `sbxcursor`→`cursor-agent`.
- `install_hint()` and `require_sbx()` are unchanged apart from the prefix.

`resolve_dir` is unchanged and still correct — the README install is a symlink,
and Stage 1 adds a second in-repo hop, which the existing loop already handles
(it is tested with two hops today).

Keep bash 3.2 compatible: no `declare -A`, no `${var,,}`.

### `Makefile`

- `lint`: glob `kits/*/spec.yaml` instead of `sbxclaude/spec.yaml`; add
  `':!scripts/sbxclaude'` to the shellcheck/`bash -n` file lists so the symlink
  is not linted as a second copy of the same script.
- The version-lockstep check reads `kits/sbxclaude/spec.yaml`; in Stage 5 it
  loops over all three and asserts they agree with each other and with
  `CHANGELOG.md`.
- `validate`: `./scripts/sbxclaude kit validate` (through the symlink).
- `test-unit`: `$(BASH) ./tests/sbxagent_test.sh`.
- `test-toolchain`: add `AGENT ?= claude` and call
  `./scripts/sbx$(AGENT) exec ./tests/toolchain_test.sh`.

### `tests/sbxagent_test.sh`

Existing coverage stays. Changes:

- Point `SCRIPT` at `scripts/sbxclaude` (the symlink) so basename dispatch is
  exercised on every assertion.
- `KIT="${ROOT}/kits/sbxclaude"`.
- Add a case: invoking `scripts/sbxagent` directly fails, makes no `sbx` call,
  and its message names all three commands and the `ln -s` recipe. Assert the
  same for `sbxagent help` — the direct-call refusal is not exempt.
- Add a case: a copy (not a symlink) of the script under an unrelated name fails
  the same way. This is the one real failure mode of basename dispatch, so it
  gets a test.
- The help assertion `"Use sbx or claude directly"` becomes agent-aware.

### `kits/sbxclaude/spec.yaml`

Only path-shaped edits: `/usr/local/lib/sbxclaude/network-block.jq` →
`/usr/local/lib/sbxagent/network-block.jq`. Keep `name: sbxclaude`, keep the
entrypoint workaround, keep the guard. Update the matching paths in
`tests/toolchain_test.sh` (`GUARD_FILTER`).

### CI

`.github/workflows/ci.yml`: `make validate` and `make test-unit` unchanged in
shape; only the comment naming `sbxclaude/spec.yaml` needs updating.

### Green checkpoint

```bash
make lint
make validate
make test-unit
make test-unit BASH=/bin/bash    # bash 3.2 floor, on a macOS host
sbxclaude rm && sbxclaude        # rebuild from the moved kit
make test-toolchain
```

---

## Stage 2 — Codex spike (go/no-go on issue #415)

No production code. Prove the parent kit still functions when a child defines
`setup:`.

1. Create `kits/sbxcodex/spec.yaml` with the bare minimum: `schemaVersion: "2"`,
   `kind: sandbox`, `name: sbxcodex`, `extends: codex`, `version: "0.1.0"`. No
   `setup:`, no `files:`, no `entrypoint:`.
2. `ln -s sbxagent scripts/sbxcodex`, then `sbxcodex` — confirm Codex starts and
   is authenticated (`~/.codex/auth.json` and `~/.codex/config.toml` exist and
   are owned by the sandbox user).
3. Add a trivial `setup: install:` step (e.g. `apt-get install -y jq`) and
   `sbxcodex rm && sbxcodex`. Re-check the two files.

**If step 3 loses auth**, the workaround mirrors the existing Claude one: do the
work from `entrypoint:` instead of `setup:`, or replicate the parent's
config/auth seeding in our own `setup:`. Record which applies before Stage 3.

Also confirm in this stage which host the Codex CLI actually talks to
(`api.openai.com`, `chatgpt.com/backend-api/codex`) via `sbxcodex policy log`,
so the Stage 3 allowlist is derived from observation, not guesswork.

---

## Stage 3 — Land `sbxcodex`

`kits/sbxcodex/spec.yaml`, copied from `kits/sbxclaude/spec.yaml` with:

- `name: sbxcodex`, `extends: codex`, `displayName: Codex with custom toolchain`.
- **Entrypoint**: same shape as the Claude one, but chowning `$HOME/.codex`
  instead of `$HOME/.claude`, and `exec codex "$@"`. Keep the
  `GH_TOKEN` → `GITHUB_TOKEN` export — the GitHub MCP server needs it here too.
  If Stage 2 showed the parent setup survives, drop the chown and use a plain
  entrypoint.
- **`permissions.network.allow`**: the shared list from the Claude kit, plus
  whatever Stage 2's policy log showed for OpenAI. Drop the Anthropic hosts —
  those come from `extends: claude` and are irrelevant here.
- **`setup.install`**: the same toolchain steps (CLI tools, `sbx`,
  `github-mcp-server`, ruff, yamllint, markdownlint/cspell, Playwright, mmdc),
  minus the `Network-block escalation hook` step.
- **New step — register MCP servers.** Append to `~/.codex/config.toml` as
  `user: "agent"`, mirroring how the parent registers its gateway:

  ```toml
  [mcp_servers.context7]
  command = "npx"
  args = ["-y", "@upstash/context7-mcp@4.0.0"]

  [mcp_servers.github]
  command = "github-mcp-server"
  args = ["stdio"]
  [mcp_servers.github.env]
  GITHUB_PERSONAL_ACCESS_TOKEN = "${GITHUB_TOKEN}"
  ```

  Do **not** ship this as `files/home/.codex/config.toml` — the parent rewrites
  that file on every create.
- **New step — kit marker.** Write `/etc/sbxagent-kit` containing `sbxcodex`.
  `tests/toolchain_test.sh` reads it to decide which agent-specific assertions
  to run. Add the same step to the Claude and Cursor kits.
- **`agentInstructions.content`**: the shared block, with the "MCP servers"
  bullet kept and the network-guard paragraph replaced by a plain statement that
  blocked hosts must be reported to the user (there is no hook to enforce it).
- `files/home/.gitconfig` and `files/workspace/.editorconfig`: copies of the
  Claude kit's. No `.claude.json`, no `eli5.md` output style (Claude-only).

Add `scripts/sbxcodex -> sbxagent`, extend `tests/sbxagent_test.sh` to assert
the `sbxcodex-` sandbox prefix and the `kits/sbxcodex` kit path, and confirm the
three names produce three different sandbox names for the same directory.

Make `tests/toolchain_test.sh` branch on `/etc/sbxagent-kit`: the guard-filter,
managed-settings and `~/.claude.json` blocks run only for `sbxclaude`; a
`~/.codex/config.toml` MCP assertion runs only for `sbxcodex`. Everything else
(tool versions, Chromium launch, mmdc render, CA bundle, git `insteadOf`) is
shared.

Verify with `make test-toolchain AGENT=codex`.

---

## Stage 4 — Land `sbxcursor`

Same shape as Stage 3. Differences:

- `name: sbxcursor`, `extends: cursor`, entrypoint `exec cursor-agent "$@"`.
- Network allowlist adds the Cursor hosts the parent uses — `api2.cursor.sh`,
  `api3.cursor.sh`, `repo42.cursor.sh`, `cursor.com` — confirmed against
  `sbxcursor policy log` in a spike first, as in Stage 2.
- MCP servers **can** ship as `files/home/.cursor/mcp.json`, since the parent
  only writes `~/.cursor/cli-config.json` (`onlyIfMissing: true`). Match the
  repo's own `.cursor/mcp.json` format — note it uses `${env:GITHUB_TOKEN}`,
  not `${GITHUB_TOKEN}`; keep whichever the Cursor CLI actually resolves and
  say so in a comment.
- Do not chown `~/.cursor` blindly — Cursor's credential store is in memory and
  the parent's `cli-config.json` is `onlyIfMissing`. Only add a chown if the
  spike shows root-owned files.
- `/etc/sbxagent-kit` contains `sbxcursor`; toolchain test gains a
  `~/.cursor/mcp.json` branch.

Verify with `make test-toolchain AGENT=cursor`.

---

## Stage 5 — Docs, lint, CI, release

- **`README.md`**: retitle to `sbxagent`. Replace the single install snippet
  with the three-symlink block from the request. Turn the commands table into
  one table using `sbx<agent>` with a note that all three take the same
  signatures. Add a "Supported agents" table (parent kit, entrypoint,
  instruction file, MCP config, guard hook yes/no). Update every pinned-versions
  path from `sbxclaude/spec.yaml` to `kits/*/spec.yaml`. State plainly that the
  network-block guard exists only for `sbxclaude`.
- **`AGENTS.md`**: update the Repository Map (`kits/`, `scripts/sbxagent` plus
  three symlinks) and the Critical Requirement (`make validate` now covers all
  three kits).
- **`Makefile`**: `validate` loops the three kits; the version check asserts all
  three `spec.yaml` versions match each other and `CHANGELOG.md`.
- **`.cspell.json`**: add `sbxagent`, `sbxcodex`, `sbxcursor`, `codex`,
  `openai`, and any TOML key that trips it.
- **`.github/workflows/ci.yml`**: no structural change needed once `make
  validate` loops internally; update the job comment.
- **`CHANGELOG.md`**: under `## [Unreleased]`, `### Added` for the two new
  agents and the `sbxagent` dispatch; `### Changed` for the kit move to `kits/`
  and the script rename. Then cut `## [0.2.0] - YYYY-MM-DD` and bump `version:`
  in all three specs to `0.2.0` in the same commit (`make lint` enforces this).
  Do not push a tag without confirming.

---

## Out of scope (candidate follow-ups)

- A network-block guard equivalent for Codex and Cursor. Needs research into
  what hook mechanisms those CLIs actually expose.
- De-duplicating the ~240 shared lines across the three specs, either by
  generating them from fragments or by trying `sbx`'s `mixins:` field (present
  in the v2 schema, undocumented in the CLI's embedded reference).
- Renaming the GitHub repository itself.

---

## Verification

Run at the end of each stage, not only at the end:

```bash
make lint
make validate
make test-unit
make test-unit BASH=/bin/bash          # macOS host only — bash 3.2 floor

# Per agent, after the corresponding stage:
sbxclaude rm && sbxclaude create && make test-toolchain AGENT=claude
sbxcodex  rm && sbxcodex  create && make test-toolchain AGENT=codex
sbxcursor rm && sbxcursor create && make test-toolchain AGENT=cursor
```

Manual checks that the test suite cannot cover:

- Each agent starts interactively and reaches a prompt (`sbxclaude`,
  `sbxcodex`, `sbxcursor`) without a login prompt.
- MCP tools resolve inside each sandbox: `claude mcp list` for Claude,
  `codex mcp list` (or the Codex equivalent) for Codex, and Cursor's MCP status
  view for Cursor. `context7` and `github` should both connect.
- Running `sbxclaude` and `sbxcodex` from the same project directory yields two
  live sandboxes with different names and neither disturbs the other.
- `git fetch` over an SSH-style GitHub remote works in all three (the
  `insteadOf` rewrite).
- In `sbxclaude` only: a blocked request still ends the turn with the
  `sbx policy allow network "<host>"` message.
