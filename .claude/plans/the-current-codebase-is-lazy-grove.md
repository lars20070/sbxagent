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
  `sbxcursor-<slug>-<hash>`. The prefix is the command you type, which is the
  only property worth optimising for here.
- Codex and Cursor ship without the network-block escalation hook in v1.
- **No backwards compatibility.** No migration shims, no dual paths, no "old
  location still works" fallbacks. Every sandbox is deleted and rebuilt.
  Note that the Claude sandbox name is unchanged, and the wrapper's attach path
  never consults the kit — so a leftover sandbox would be re-attached silently
  with the old kit baked in. Delete them on the host (`sbx rm --all -f`, or
  `sbx ls` then `sbx rm <name>`) before the first rebuild. Not `sbx reset` —
  that also wipes network policies and the `github` secret.

### Target directory structure

```text
.
├── AGENTS.md  CLAUDE.md  CHANGELOG.md  LICENSE  Makefile  README.md
├── .coderabbit.yaml  .cspell.json  .editorconfig  .gitignore
├── .markdownlint-cli2.jsonc  .shellcheckrc  .yamllint.yaml
├── .github/workflows/ci.yml
│
│   # Configs for agents working ON this repo (unchanged, not part of any kit)
├── .mcp.json                         # Claude Code, project scope
├── .claude/{settings.json, plans/, skills/}
├── .cursor/{mcp.json, settings.json, plans/, skills/}
├── .vscode/{mcp.json, settings.json}
│
│   # NEW: one directory per wrapper command. Directory name == kit `name:`
│   #      == the sbx positional operand == the command you type.
├── kits/
│   ├── sbxclaude/                    # MOVED from ./sbxclaude/
│   │   ├── spec.yaml                 #   extends: claude
│   │   └── files/
│   │       ├── home/
│   │       │   ├── .claude.json                     # MCP, user scope
│   │       │   ├── .claude/output-styles/eli5.md    # Claude-only
│   │       │   └── .gitconfig                       # shared copy
│   │       └── workspace/.editorconfig              # shared copy
│   ├── sbxcodex/                     # NEW
│   │   ├── spec.yaml                 #   extends: codex
│   │   └── files/
│   │       ├── home/.gitconfig                      # shared copy
│   │       └── workspace/.editorconfig              # shared copy
│   └── sbxcursor/                    # NEW
│       ├── spec.yaml                 #   extends: cursor
│       └── files/
│           ├── home/
│           │   ├── .cursor/mcp.json                 # MCP, user scope
│           │   └── .gitconfig                       # shared copy
│           └── workspace/.editorconfig              # shared copy
│
├── scripts/
│   ├── sbxagent                      # RENAMED from scripts/sbxclaude
│   ├── sbxclaude -> sbxagent         # NEW symlink
│   ├── sbxcodex  -> sbxagent         # NEW symlink
│   └── sbxcursor -> sbxagent         # NEW symlink
│
└── tests/
    ├── sbxagent_test.sh              # RENAMED from tests/sbxclaude_test.sh
    └── toolchain_test.sh             # branches on the SANDBOX_NAME prefix
```

Why it is shaped this way:

- **`kits/` groups three things of one kind.** Three sibling top-level
  directories that are all sandbox kits would read as three unrelated projects.
  `sbx kit validate` takes any directory path, so the nesting costs nothing.
- **Directory name is the single source of identity.** `kits/sbxcodex/` implies
  `name: sbxcodex` in its `spec.yaml`, the `sbxcodex` positional passed to
  `sbx run`, the `sbxcodex-<slug>-<hash>` sandbox name, and the `sbxcodex`
  command. One string, derived once from `basename "$0"`. `make lint` should
  assert dir name == `name:` for each kit.
- **`files/home/` and `files/workspace/`** keep the existing convention. No new
  top level inside a kit.
- **`sbxcodex` ships no MCP file.** Its parent rewrites `~/.codex/config.toml`
  on every create, so the MCP servers are appended by a `setup:` step instead.
  An empty-looking `files/` there is deliberate, and the `spec.yaml` says so.
- **The network-block guard stays inline** in `kits/sbxclaude/spec.yaml` as a
  heredoc, written by `setup:` as root to `/usr/local/lib/sbxagent/`. It is not
  moved into `files/`: being root-owned and outside `$HOME` is the whole point,
  and `files/home/` would not give that.
- **`.gitconfig` and `.editorconfig` are byte-identical triplicates.** That is
  the accepted cost of three standalone kits. Cheap guard: two `cmp` calls in
  `make lint` so they cannot drift silently.
- **`.claude/`, `.cursor/`, `.vscode/` and `.mcp.json` are untouched.** They
  configure agents editing this repo; they are not shipped into any sandbox.
  Optionally add a `.codex/config.toml` if you want to develop this repo with
  Codex too — `AGENTS.md` already covers the instruction half.

New constraint this layout creates: the sandbox mounts the project, so a
project-scope MCP config sits alongside the kit's user-scope one. `.mcp.json` vs
`kits/sbxclaude/files/home/.claude.json` must already agree (documented in the
README). **`.cursor/mcp.json` vs `kits/sbxcursor/files/home/.cursor/mcp.json`
now has the same requirement** — note the repo's file uses `${env:GITHUB_TOKEN}`
where `.mcp.json` uses `${GITHUB_TOKEN}`, so the kit copy must match the Cursor
form, not the Claude one. Codex has no project MCP scope, so it is unaffected.

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

Build the `sbxclaude` third of the target structure above. Use `git mv` so the
renames show up as renames in history:

```bash
git mv scripts/sbxclaude scripts/sbxagent
git mv tests/sbxclaude_test.sh tests/sbxagent_test.sh
mkdir kits && git mv sbxclaude kits/sbxclaude
ln -s sbxagent scripts/sbxclaude && git add scripts/sbxclaude
```

The in-repo `scripts/sbxclaude` symlink is what makes `make` and the tests go
through basename dispatch on every run, rather than only at install time.
`kits/sbxcodex/` and `kits/sbxcursor/` arrive in Stages 3 and 4.

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

- `lint`: glob `kits/*/spec.yaml` instead of `sbxclaude/spec.yaml`. Change the
  shellcheck / `bash -n` file list from `'scripts/*'` to `'scripts/sbxagent'` —
  naming the one real script beats excluding symlinks, which would otherwise
  need extending again in Stages 3 and 4. Add one structural check: each
  `kits/<dir>/spec.yaml` has `name: <dir>`. The `cmp` checks for the duplicated
  `files/` wait for Stage 3 — with one kit there is nothing to compare.
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
`tests/toolchain_test.sh` (`GUARD_FILTER`), and make its `REBUILD_HINT` string
agent-aware — it currently hardcodes `'sbxclaude rm' then 'sbxclaude'`.

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
3. Add a trivial `setup: install:` step (e.g. `apt-get install -y jq`), then
   `sbxcodex rm && sbxcodex`. Re-check the two files. The `rm` matters:
   `setup:` runs only on create, so an attach would prove nothing.

**If step 3 loses auth**, the workaround mirrors the existing Claude one: do the
work from `entrypoint:` instead of `setup:`, or replicate the parent's
config/auth seeding in our own `setup:`. Record which applies before Stage 3.

While in there, capture two things Stage 3 needs from observation rather than
guesswork:

- Which hosts the Codex CLI actually talks to (`api.openai.com`,
  `chatgpt.com/backend-api/codex`), via `sbxcodex policy log`.
- The exact `[mcp_servers.*]` shape the parent wrote into `~/.codex/config.toml`
  for its own gateway. Copy its key names verbatim in Stage 3 — a wrong TOML key
  fails silently, with the server simply absent.

### Spike results (run 2026-09-01, `sbx` v0.39.0, macOS host)

**Verdict: NO-GO on the naive approach, GO on workaround (b).** The parent's
steps are dropped, and replicating them in our own kit fully restores them.

**1. Issue #415 confirmed, and it is worse for Codex than for Claude.**
A bare `kits/sbxcodex/spec.yaml` (`extends: codex`, nothing else) produced an
agent-owned `~/.codex/config.toml` with the yolo keys and the `mcp-gateway`
block. Adding a single trivial child `setup: install:` step (`apt-get install -y
jq`) and rebuilding left `~/.codex` **completely empty** — no `config.toml`, no
`auth.json`, no gateway registration. The child step itself ran (`jq-1.8.1`
present), so this is a silent replacement, not a failure.

**2. `setup:` is an alias for `environment:` — same node.** The embedded `codex`
parent declares its steps as `environment.install` / `environment.startup`
(alongside `environment.variables`); the string table in the `sbx` binary carries
a literal `setupalias`. Renaming our block would not dodge the bug.

**3. The merge is per-field within that node, not whole-node.**
`environment.variables` from the parent **survived** (`CODEX_HOME`,
`GIT_TERMINAL_PROMPT` both set in the rebuilt sandbox). Only the fields the child
declares are replaced. Note that `startup` was lost too, even though the child
declared only `install` — so it is not a simple per-field override; treat the
whole `install`+`startup` pair as lost once either is declared.

**4. Workaround (b) — replicate the parent's seeding in our own `setup:` — works.**
Copying the parent's install step verbatim (with `user: "agent"`) plus its
`startup:` gateway step into the child kit rebuilt a byte-equivalent
`config.toml`, gateway block included. A child `startup:` step is honoured (a
marker file probe was written). **Stage 3 must carry both replicated steps.**
Workaround (a) (move the work into `entrypoint:`) is *not* usable here: the
toolchain installs need root at create time, which `entrypoint:` does not give.

The two steps to copy verbatim into `kits/sbxcodex/spec.yaml` are reproduced in
full at the end of this section.

**5. Codex CLI version in the parent image:** `codex-cli 0.149.1`.

**6. Network: no OpenAI hosts need adding.** `sbxcodex policy check` says
`api.openai.com`, `auth.openai.com` and `chatgpt.com` are already **allowed** by
the base preset (`**.openai.com:443`, `**.chatgpt.com:443`). `context7.com` is
**denied** by default. So Stage 3's `permissions.network.allow` is the Claude
kit's list minus the Anthropic hosts, plus nothing OpenAI-specific. (The policy
log could not observe live Codex traffic — see the caveat below.)

**7. The `[mcp_servers.*]` shape the parent writes** (copy these key names):

```toml
[mcp_servers.mcp-gateway]
type = "http"
url = "$MCP_GATEWAY_URL"
[mcp_servers.mcp-gateway.headers]
Authorization = "Bearer $MCP_SENTINEL_TOKEN_NAME"
```

Our own servers are `command`/`args`-shaped instead of `type = "http"`, as the
Stage 3 sketch already has them.

#### The auth half — tested, and the gap is upstream of this kit

Re-run after storing an OpenAI credential (`sbx secret set openai`, shown by
`sbx secret ls` as `openai (oauth configured)`) and adding the binding sbx asked
for. The binding block added to `~/.config/sbx/credentials.yaml` was:

```yaml
    openai:
        apiKey:
            domains:
                - api.openai.com
                - openai.com
        oauth:
            domains:
                - auth.openai.com
```

It is a mechanical read of the codex parent's `credentials:` block —
`apiKey.domains` are its `apiKey.inject` domains, `oauth.domains` is its
`oauth.tokenEndpoint.host` — and matches the shape of the existing `anthropic`
entry exactly. After it was added the `no binding authorizes openai` note stopped
appearing on create.

**`SBX_CRED_OPENAI_MODE` is still `none`, and `auth.json` is still absent.**
Things that did *not* change it: adding the binding, restarting `sandboxd`
(`sbx daemon restart`), and recreating from scratch.

The decisive observation is that this is **not caused by our kit**:

- A **bare** `sbxcodex` kit — `extends: codex` and nothing else, no `setup:` at
  all, i.e. the parent running unmodified — also yields `SBX_CRED_OPENAI_MODE=none`
  and no `auth.json`.
- The replicated kit produces a **byte-equivalent** `~/.codex/config.toml` to that
  bare kit. Replication is therefore proven equivalent to the parent, which is
  all Stage 2 can be asked to prove.
- `sbx inspect` shows the same thing from the other side: the codex sandbox's
  `Secrets:` line lists `github`, `mcpgateway`, `openrouter` — no `openai`. The
  **working** `sbxclaude` sandbox likewise lists no `anthropic`. OAuth credentials
  never appear as uploaded secrets in either.

Why Claude works anyway and Codex may not: the `claude` parent declares
`credentials[].oauth.credentialFile` (`~/.claude/.credentials.json`, written by
sandboxd's OAuth hook), and that file **is** present and agent-owned in the live
Claude sandbox despite `SBX_CRED_ANTHROPIC_MODE=none`. The `codex` parent
declares **no** `credentialFile`; its only auth path is its install step writing
`auth.json`, gated entirely on `SBX_CRED_OPENAI_MODE`. So when that variable is
`none`, Codex has no seeded credential by design — the parent's `none` branch
deletes `auth.json` deliberately so a stale `proxy-managed` placeholder cannot
reach OpenAI and 401.

**What this means for Stage 3.** Nothing to change in the kit: carry the
replicated steps as written. The open question is an `sbx`/host credential-
plumbing one, not a kit one, and it would bite an unmodified `extends: codex`
kit identically. Stage 3's first task is to run `sbxcodex` interactively and see
what actually happens:

- If Codex reaches a prompt, `SBX_CRED_OPENAI_MODE` is a red herring on this
  `sbx` build and there is nothing to fix.
- If Codex asks to log in, log in once inside the sandbox and check whether it
  survives a rebuild. If it does not, the fix belongs in the kit as a persisted
  volume for `~/.codex` (mirroring how the claude parent persists
  `~/.claude/projects` and `~/.claude/sessions`), **not** in the replicated
  seeding step.

Either way this does not block Stage 3, and it is not a reason to prefer a
different workaround for #415.

#### Replicated parent steps (verbatim, verified working)

The spike spec that produced the passing result is reproduced below; lift these
two steps into `kits/sbxcodex/spec.yaml` unchanged.

```yaml
schemaVersion: "2"
kind: sandbox
name: sbxcodex
version: "0.1.0"
displayName: Codex spike
description: Stage 2 spike — replicate the parent seeding inside our own setup

extends: codex

setup:
  install:
    - command: |
        set -eu
        apt-get update
        apt-get install -y jq
      description: Spike probe — trivial child install step
    # Replicated verbatim from the embedded `codex` parent kit, because sbx
    # drops the parent's setup once this kit defines its own (issue #415).
    - command: |
        set -e
        mkdir -p /home/agent/.codex /home/agent/.agents
        MODE="${SBX_CRED_OPENAI_MODE:-none}"
        cat > /home/agent/.codex/config.toml << 'EOF'
        # Codex configuration for Docker sandbox
        # This configuration enables "yolo mode" - no approvals, full access
        approval_policy = "never"
        sandbox_mode = "danger-full-access"
        mcp_oauth_credentials_store = "file"
        EOF
        case "$MODE" in
          oauth|apikey)
            cat >> /home/agent/.codex/config.toml << 'EOF'
        forced_login_method = "api"
        EOF
            ;;
        esac
        if [ "$MODE" = oauth ]; then
          cat >> /home/agent/.codex/config.toml << 'EOF'
        model_provider = "sandboxd"
        [model_providers.sandboxd]
        name = "Sandbox Proxy"
        base_url = "https://chatgpt.com/backend-api/codex"
        experimental_bearer_token = "oai-oat01-proxy-managed"
        requires_openai_auth = false
        EOF
        fi
        case "$MODE" in
          oauth|apikey)
            cat > /home/agent/.codex/auth.json << 'EOF'
        {
          "OPENAI_API_KEY": "proxy-managed"
        }
        EOF
            ;;
          *)
            rm -f /home/agent/.codex/auth.json
            ;;
        esac
      user: "agent"
      description: Seed Codex config/auth from SBX_CRED_OPENAI_MODE (replicated parent step)
  startup:
    # Also replicated from the parent — dropped along with its install steps.
    - command:
        - sh
        - -c
        - |
          set -e
          [ -n "$MCP_GATEWAY_URL" ] || exit 0
          cfg="$HOME/.codex/config.toml"
          touch "$cfg"
          grep -q "^\[mcp_servers.mcp-gateway\]" "$cfg" && exit 0
          cat >> "$cfg" <<EOF
          [mcp_servers.mcp-gateway]
          type = "http"
          url = "$MCP_GATEWAY_URL"
          [mcp_servers.mcp-gateway.headers]
          Authorization = "Bearer $MCP_SENTINEL_TOKEN_NAME"
          EOF
      user: "agent"
      description: Register the sandbox MCP gateway (replicated parent step)
    # Spike probe — proves a child `startup:` step runs at all.
    - command: ["sh", "-c", "echo spike-startup-ran > /home/agent/.codex/spike-marker"]
      user: "agent"
      description: Spike probe — child startup marker
```

---

## Stage 3 — Land `sbxcodex`

`kits/sbxcodex/spec.yaml`, copied from `kits/sbxclaude/spec.yaml` with:

- `name: sbxcodex`, `extends: codex`, `displayName: Codex with custom toolchain`.
- **Entrypoint**: same shape as the Claude one, but chowning `$HOME/.codex`
  instead of `$HOME/.claude`, and `exec codex "$@"`. Keep the
  `GH_TOKEN` → `GITHUB_TOKEN` export — the GitHub MCP server needs it here too.
  Stage 2 showed the parent setup does **not** survive, so keep the chown.
  Note that `~/.codex` is created agent-owned by the template image, so the
  chown may be a no-op here; keep it only if a rebuild shows root-owned files.
- **`permissions.network.allow`**: the shared list from the Claude kit, and
  nothing more. Stage 2 confirmed `api.openai.com`, `auth.openai.com` and
  `chatgpt.com` are already allowed by the base preset, so no OpenAI hosts need
  adding. Drop the Anthropic hosts — those come from `extends: claude` and are
  irrelevant here.
- **`setup.install`**: the same toolchain steps (CLI tools, `sbx`,
  `github-mcp-server`, ruff, yamllint, markdownlint/cspell, Playwright, mmdc),
  minus the `Network-block escalation hook` step, **plus the replicated parent
  seeding step from Stage 2** — without it Codex has no `config.toml` and no
  `auth.json` at all.
- **`setup.startup`**: the replicated parent `mcp-gateway` registration step
  from Stage 2. It is lost along with `setup.install` and has to be carried
  explicitly.
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
- **`agentInstructions.content`**: the shared block, with the "MCP servers"
  bullet kept and the network-guard paragraph replaced by a plain statement that
  blocked hosts must be reported to the user (there is no hook to enforce it).
- `files/home/.gitconfig` and `files/workspace/.editorconfig`: copies of the
  Claude kit's. No `.claude.json`, no `eli5.md` output style (Claude-only).

Add `scripts/sbxcodex -> sbxagent`, extend `tests/sbxagent_test.sh` to assert
the `sbxcodex-` sandbox prefix and the `kits/sbxcodex` kit path, and confirm the
three names produce three different sandbox names for the same directory.

Make `tests/toolchain_test.sh` branch on its `KIT_NAME` (added in Stage 1; it
comes from the `SANDBOX_NAME` prefix, so no marker file is needed): the guard-filter,
managed-settings and `~/.claude.json` blocks run only for `sbxclaude`; a
`~/.codex/config.toml` MCP assertion runs only for `sbxcodex`. Everything else
(tool versions, Chromium launch, mmdc render, CA bundle, git `insteadOf`) is
shared.

Now that a second kit exists, add the `cmp` checks to `make lint`:
`files/home/.gitconfig` and `files/workspace/.editorconfig` must be
byte-identical across kits.

Verify with `make test-toolchain AGENT=codex`.

---

## Stage 4 — Land `sbxcursor`

Same shape as Stage 3. Differences:

- `name: sbxcursor`, `extends: cursor`, entrypoint `exec cursor-agent "$@"`.
- Network allowlist adds the Cursor hosts the parent uses — `api2.cursor.sh`,
  `api3.cursor.sh`, `repo42.cursor.sh`, `cursor.com` — confirmed against
  `sbxcursor policy log` in a spike first, as in Stage 2.
- MCP servers **can** ship as `files/home/.cursor/mcp.json`, since the parent
  only writes `~/.cursor/cli-config.json` (`onlyIfMissing: true`). It must stay
  byte-identical to the repo's own `.cursor/mcp.json`, for the same reason
  `.mcp.json` and `~/.claude.json` must agree today: the sandbox mounts the
  project, so project scope and user scope sit side by side. Note the Cursor
  form uses `${env:GITHUB_TOKEN}`, not `${GITHUB_TOKEN}`. Add a `cmp` of the
  two to `make lint`, as the README already demands for the Claude pair.
- Do not chown `~/.cursor` blindly — Cursor's credential store is in memory and
  the parent's `cli-config.json` is `onlyIfMissing`. Only add a chown if the
  spike shows root-owned files.
- Toolchain test gains a `~/.cursor/mcp.json` branch, keyed on `KIT_NAME`.

Verify with `make test-toolchain AGENT=cursor`.

---

## Stage 5 — Docs, lint, CI, release

- **`README.md`**: retitle to `sbxagent`. Replace the single install snippet
  with the three-symlink block from the request, replacing the old
  `ln -s .../scripts/sbxclaude` line outright. Turn the commands table into
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
  validate` loops internally; update the job comment (line 71).
- **`.coderabbit.yaml`**: one comment line (line 3) names the project
  `sbxclaude`.
- **`CHANGELOG.md`**: under `## [Unreleased]`, `### Added` for the two new
  agents and the `sbxagent` dispatch; `### Changed` for the kit move to `kits/`
  and the script rename; `### Removed` for the old `scripts/sbxclaude` install
  path. Say plainly that this is breaking: re-link the wrapper, and delete
  existing sandboxes first. Then cut `## [0.2.0] - YYYY-MM-DD` and bump
  `version:` in all three specs to `0.2.0` in the same commit (`make lint`
  enforces this). Do not push a tag without confirming.

---

## Out of scope (candidate follow-ups)

- A network-block guard equivalent for Codex and Cursor. Needs research into
  what hook mechanisms those CLIs actually expose.
- De-duplicating the ~240 shared lines across the three specs, either by
  generating them from fragments or by trying `sbx`'s `mixins:` field (present
  in the v2 schema, undocumented in the CLI's embedded reference).
- Renaming the GitHub repository itself.
- Lifting the ~60-line jq guard filter out of the `spec.yaml` heredoc into its
  own linted file. Nice for readability, but it would change how the filter gets
  its root ownership, so it does not belong in the same change as the rename.

---

## Verification

Everything below runs on the **host** — `sbx run`, `rm`, `ls` and `policy` all
need the host CLI and `sandboxd`, and are unavailable from inside a sandbox.

Run at the end of each stage, not only at the end:

```bash
make lint
make validate
make test-unit
make test-unit BASH=/bin/bash          # macOS host only — bash 3.2 floor

# Per agent, after the corresponding stage. `rm` first: setup: runs only on
# create, so re-attaching an existing sandbox tests the previous kit.
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
