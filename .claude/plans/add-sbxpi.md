# Add `sbxpi`: a fourth kit running the Pi agent on OpenRouter → DeepInfra

> Revised three times since the first draft: against
> `add-sbxpi-plan-review.md`, then `research-report-pi-coding-agent.md`, then
> restructured into stages.
>
> **On approval, copy this over `.claude/plans/add-sbxpi.md`** (keep the old
> filename) and delete this file.

## Context

`sbxagent` wraps terminal coding agents as Docker Sandbox Kits — one
`kits/<command>/spec.yaml` plus a `scripts/sbx<agent>` symlink into a shared
wrapper. Three exist today: `sbxclaude`, `sbxcodex`, `sbxcursor`. We want a
fourth, `sbxpi`, running the **Pi** agent (`pi.dev`,
`@earendil-works/pi-coding-agent`) against **OpenRouter** with model calls
pinned to the **DeepInfra** backend.

**The governing objective is resemblance.** `sbxpi` must look and behave like
its three siblings: same toolchain, same network allowlist, same hooks as
`sbxclaude`. Where Pi/sbx/OpenRouter mechanics raise a question the siblings
cannot answer, the reference is the working sibling repo
[md2okf](https://github.com/lars20070/md2okf) (`pi/` directory). Clone it into
the session scratchpad and keep it as a read-only reference throughout
implementation. Its `skills/` folder and its `AGENTS.md` are specific to that
repo's wiki-compiling task — **do not carry those over**.

### Decisions taken

| # | Question | Decision |
|---|---|---|
| 1 | Guard strength | **Two-phase hard stop** via a Pi extension |
| 2 | Allowlist | **Superset**: every `sbxclaude` host + no-parent-kit hosts |
| 3 | GitHub MCP | **No MCP in v1**; install `github-mcp-server` for toolchain parity only |
| 4 | Default model | `qwen/qwen3-coder` — confirmed by research, no longer provisional |
| 5 | OpenRouter secrets | md2okf's dual `set` + `set-custom` |
| 6 | "Same toolchain" | Includes `github-mcp-server`, even though Pi never calls it |
| 7 | Project trust | `defaultProjectTrust: "always"` — no prompt, mounted project config honoured |
| 8 | `models.json` form | **Minimal** — no `baseUrl`/`api`; inherit the built-in catalogue |
| 9 | `pi.dev` on siblings | **Leave it.** No cleanup pass; the other three kits are not touched by this work |
| 10 | BYOK dashboard toggles | **No action.** The same setup already works in md2okf; treated as a documented note, not required setup |

### Facts established (verified against primary sources — do not re-derive)

- `extends: shell` is **not** valid — documented values are `claude`, `codex`,
  `copilot`, `cursor`, `gemini`, `kiro`, `opencode`. `sbx kit validate`
  accepts any `extends:` string including nonsense, so a green `make validate`
  proves nothing here. Use `image:`.
- **No kit in this repo declares a `credentials:` block.** The other three
  inherit credentials from their parent kit. `sbxpi`'s must be modelled on
  md2okf's.
- Pi's extension API: `pi.on("tool_call", …)` may return
  `{ block, reason, terminate }`. `pi.on("tool_result", …)` may return only
  `{ content, details, isError, usage }` — **no `terminate`**. This shapes the
  guard.
- Extensions load from `settings.json` `extensions: []` (absolute paths) and
  from auto-discovered `~/.pi/agent/extensions`.
- **Pi has no MCP.** Its README is explicit: *"No MCP. Build CLI tools with
  READMEs, or build an extension that adds MCP support"*, and *"No MCP
  configuration, CLI flags, or stdio server compatibility exists in the
  codebase."* The research report's claim that Pi natively reads `.mcp.json`
  is **wrong** — only an extension can add MCP. Wording in our docs: "not
  built-in; an extension could add it, deferred past v1."
- **`pi install` and `settings.json` `packages` are one mechanism**, not two.
  `pi install` writes the entry into `packages` and materialises it under
  `~/.pi/agent/npm/`. A package listed but never installed is **fetched from
  the network at first launch** — unacceptable in a sealed image. Pre-install
  at build time.
- **`qwen/qwen3-coder`**: 262,144-token context, 65,536 max output, present in
  Pi's built-in OpenRouter catalogue, and **non-reasoning** (Qwen's model
  card: *"supports only non-thinking mode"*) — no `reasoning: true`, no
  `thinkingLevelMap`. Avoid `:free` (often rejects tool-calling) and `:nitro`
  (sorts by throughput, fighting the DeepInfra pin).
- `openrouter` is a **built-in provider**, so `baseUrl` and `api` are already
  known to Pi.
- `only: ["deepinfra"]` matches DeepInfra's endpoint for this model
  (OpenRouter lists it as "DeepInfra (Turbo)"; base-slug matching includes
  turbo). `deepinfra/turbo` is the strict slug if ever needed.
- **`AGENTS.md` files concatenate** — global `~/.pi/agent/AGENTS.md`, then
  each ancestor directory, then cwd. Our append-to-a-base-file approach is
  therefore sound.
- `pi.dev` serves telemetry (`/api/report-install`) and version checks
  (`/api/latest-version`); both are disableable.
- The official npm install line is `npm install -g --ignore-scripts`.
- The legacy `@mariozechner/*` scope is frozen at 0.73.1 and missing security
  fixes — check the **scope**, not just the version, on the install line.
- Pi needs `~/.pi/agent/` writable: `auth.json` (0600), session JSONL, `npm/`,
  `git/`, and `models-store.json`.

## Staging

Three stages, in this order, because **the guard cannot be tested until the
kit boots** — there is nowhere to run a Pi extension before Stage 1 lands.

| Stage | Scope | Risk | Gates |
|---|---|---|---|
| 1 | Kit boots and talks to OpenRouter | Low — mostly copied from `sbxclaude` + md2okf | Stage 2 |
| 2 | The network-block guard | **High** — net-new, no reference implementation anywhere | Stage 3 |
| 3 | Docs | None | — |

Docs come last on purpose: Stage 3 writes a README row claiming `sbxpi` has a
network-block guard. If Stage 2 cannot be made to work, that row would be a
lie. Find out first, document after.

Each stage ends green on `make lint`, `make validate`, and `make test-unit`,
so each is a mergeable commit. Stages 1 and 2 leave the README temporarily
saying "three kits" — fine on a feature branch, not something to merge to
`main` mid-way.

---

## Stage 1 — Kit boots and talks to OpenRouter

**Goal:** a real `sbxpi` sandbox that starts, has the full sibling toolchain,
and can reach `openrouter.ai` with the DeepInfra pin in effect.

### Files

**`kits/sbxpi/spec.yaml`** (new) — same top-level shape as
`kits/sbxclaude/spec.yaml` (`name`, `version` matching root `VERSION`,
`displayName`, `description`, commented-out `resources:`), built like
`md2okf/pi/spec.yaml` underneath:

- `sandbox.image: "docker/sandbox-templates:shell-docker"`, no `extends:`.
- `sandbox.entrypoint: [pi]` — the plain form. The siblings' `sh -c` wrapper
  exists only to work around
  [sbx-releases#415](https://github.com/docker/sbx-releases/issues/415)
  (a child's `setup:` drops a *parent's* setup). No parent here, so no bug.
- Environment: `PI_TELEMETRY=0`, `PI_SKIP_VERSION_CHECK=1`.
- `permissions.network.allow` — the **union**, not a Pi-specific list:
  - every host in `kits/sbxclaude/spec.yaml` today, *including*
    `api.github.com:443`, `gist.github.com:443`,
    `gist.githubusercontent.com:443` (Playwright still browses these; dropping
    them is a policy change we are not making), plus `registry.npmjs.org`,
    `cdn.playwright.dev`, `playwright.download.prss.microsoft.com`,
    `context7.com`, `github.com`, `github.githubassets.com`,
    `release-assets.githubusercontent.com`, `pypi.org`,
    `files.pythonhosted.org`, `pi.dev`;
  - hosts a parent kit would otherwise supply: `archive.ubuntu.com:80`,
    `security.ubuntu.com:80`, `ports.ubuntu.com:80`, `download.docker.com:443`;
  - `openrouter.ai` — **the only provider host needed**; DeepInfra sits
    upstream of OpenRouter and is never contacted directly.
  - *Verify during the first `sbx` install on `shell-docker`* whether
    `objects.githubusercontent.com:443` is needed for a release redirect
    (md2okf allows it; this repo does not). Add only if observed.
- `credentials` — modelled on md2okf's `pi/spec.yaml`: `service: openrouter`,
  `apiKey.name: OPENROUTER_API_KEY`, `proxyManaged: true`, injected as
  `Authorization: Bearer %s` to `openrouter.ai`.
- `setup.install` — the same steps as `kits/sbxclaude`, same order, reusing
  its pins verbatim: apt tools (ca-certificates, curl, jq, python3, ripgrep,
  shellcheck) → `sbx` CLI `v0.39.0` with the checksums already in
  `kits/sbxclaude/spec.yaml` → `ruff@0.16.2` / `yamllint@1.38.0` →
  `markdownlint-cli2@0.23.2` + `cspell@10.0.1` → Playwright `1.62.1` +
  Chromium → mermaid-cli `11.16.0` wrapper → `github-mcp-server` at the same
  pin (`v1.11.0`) and checksums as the siblings (toolchain parity only; no MCP
  client registered) → **Pi**, `npm install -g --ignore-scripts
  @earendil-works/pi-coding-agent@<pin>` (note the **scope**), keeping
  md2okf's npm-proxy config and retry wrapper → **Context7**, `pi install
  "npm:@upstash/context7-pi@<pin>"` at build time.
  - The research report argues the retry loop masks a fixable transient
    failure. Keep it anyway: it exists because npm-through-the-sbx-proxy is
    flaky in *this* environment, which the report did not test. Take the
    `--ignore-scripts` and exact-pin half of its advice.
  - `git` and `gh` must be on `PATH` — Pi's idiomatic replacement for a GitHub
    MCP server.
  - *Verify pins at implementation time* (`npm view
    @earendil-works/pi-coding-agent version`; latest at time of research was
    0.84.4) rather than trusting md2okf's blindly.
- `agentInstructions.filename: AGENTS.md` + `content:` — **rewrite, do not
  copy `sbxclaude`'s verbatim.** Two bullets must change or they lie to the
  agent: the MCP bullet (Context7 on Pi is a native package registering tools
  directly, not an MCP server; there is no GitHub MCP — use `git` and `gh` via
  bash) and the network-guard paragraph. In Stage 1 that paragraph says there
  is no guard yet; Stage 2 rewrites it. The rest of the "Sandbox environment /
  Preinstalled tools" blurb copies across.
- No `ALLOW_WEB` toggle — Pi has no WebSearch/WebFetch tool to gate. Say so in
  a comment so a later implementer does not "match sbxclaude" by inventing a
  no-op.

**`kits/sbxpi/files/home/.pi/agent/models.json`** (new) — minimal form.
`openrouter` is built-in, so declaring `baseUrl`/`api` risks shadowing the
catalogue entry that supplies the real 262,144-token context window:

```json
{
  "providers": {
    "openrouter": {
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

Use `modelOverrides`, never a full `models[]` array — a full entry silently
drops Pi's built-in compat defaults (`thinkingFormat`, `supportsDeveloperRole`,
`maxTokensField`, `supportsStrictMode`) and subtly breaks requests. Unknown
model ids are silently ignored, so the id string must be exact.
`allow_fallbacks: false` makes an unavailable DeepInfra return a hard 404
instead of silently rerouting. Optionally add
`"cost": { "input": 0.22, "output": 1.80 }` — cosmetic only, never affects
routing.

**`kits/sbxpi/files/home/.pi/agent/settings.json`** (new):

```json
{
  "defaultProvider": "openrouter",
  "defaultModel": "qwen/qwen3-coder",
  "defaultThinkingLevel": "off",
  "defaultProjectTrust": "always",
  "enableInstallTelemetry": false,
  "retry": { "enabled": true, "maxRetries": 3,
             "provider": { "maxRetries": 0, "timeoutMs": 3600000 } }
}
```

`defaultThinkingLevel: "off"` because Qwen3 Coder is non-reasoning.
`provider.maxRetries: 0` so SDK-level retries do not swallow quota errors
before Pi sees them. **No hand-written `packages` key** — `pi install` writes
it at build time. The `extensions` key arrives in Stage 2.

**`kits/sbxpi/files/home/.pi/agent/AGENTS.md`** (new) — short generic base
file, kept lean (under ~200 lines per Pi's own guidance). Pi concatenates
`AGENTS.md` files, so the spec's `agentInstructions.content` composes onto it.

**`kits/sbxpi/files/home/.gitconfig`** and
**`kits/sbxpi/files/workspace/.editorconfig`** — byte-identical copies of
`kits/sbxclaude`'s; `make lint` diffs every kit's copies against sbxclaude's
and fails otherwise.

No `skills/` directory — the siblings ship none, and Pi's guidance is that
skills are task-specific, not general-purpose kit furniture.

### Wiring (the minimum needed to build and test)

- **`scripts/sbxagent`** — add `sbxpi) CLI="pi" ;;` to the dispatch `case`,
  and a fourth `ln -s` hint line in the no-name-given error message.
- **`scripts/sbxpi`** — new checked-in symlink to `sbxagent`.
- **`Makefile`** — add `./scripts/sbxpi kit validate` to `validate`. Nothing
  else changes (`lint` is glob-based, `test-toolchain` is parameterised).
- **`tests/sbxagent_test.sh`** — add `sbxpi` to the `reject_wrong_name` list;
  add a `PI_SCRIPT`/`run_pi`/`PI_KIT` block in the **lighter Codex/Cursor
  spot-check style**; extend the 3-way distinctness check to 4-way.
- **`tests/toolchain_test.sh`** — add an `sbxpi` block checking `pi` is on
  `PATH`, that `~/.pi/agent/{models,settings}.json` parse and carry the
  expected `openrouter` provider / `defaultProvider`, and that `git`/`gh`
  resolve. The shared `github-mcp-server --version` check **stays
  unconditional** — every kit now installs the binary.
- **`.cspell.json`** — add `sbxpi`, `deepinfra`, `earendil`. Needed now, or
  `make lint` fails on the new spec.

### Verification

1. `make lint` — name/version sync, shared-file byte-identity, cspell,
   shellcheck/`bash -n`, markdownlint.
2. `make validate` — all four specs against the kit schema. Necessary, not
   sufficient: it does not check `extends:`/image validity.
3. `make test-unit` — exercises the new `sbxpi` dispatch.
4. `make test-toolchain AGENT=pi` — builds a real sandbox; proves it boots, Pi
   installs, and `openrouter.ai` is reachable.
5. **Context-window check** — `sbxpi exec pi --list-models openrouter` must
   show `qwen/qwen3-coder` with a **262144** context window. If it reads
   128000, the minimal `models.json` did not inherit the catalogue entry;
   fall back to md2okf's explicit `baseUrl`/`api` form.
6. **Package pre-install** — confirm nothing is fetched at first launch (watch
   for `registry.npmjs.org` traffic on a cold start).
7. **Ownership** — `sbxpi exec ls -la ~/.pi/agent`; `auth.json` must be 0600
   and everything owned by the agent user. Add the sibling `chown` entrypoint
   wrapper if anything lands root-owned.

**Done when:** all seven pass and a real prompt gets a real answer from
Qwen3 Coder.

---

## Stage 2 — The network-block guard

**Goal:** parity with `sbxclaude`'s hard stop on a blocked host. This is the
only genuinely novel work in the project — budget accordingly.

`sbxclaude` hard-stops via managed `PostToolUse` / `PostToolUseFailure` hooks
piping the payload through `/usr/local/lib/sbxagent/network-block.jq`.

**Reuse the existing policy, do not port it.** Ship a thin Pi extension at
`/usr/local/lib/sbxagent/network-block.ts` (root-owned, outside `$HOME`, same
tamper-resistance rationale as the jq filter) that **shells out to the
existing `jq -f /usr/local/lib/sbxagent/network-block.jq`**, passing the
payload shape that filter already expects and mapping its
`{continue, stopReason, systemMessage}` verdict onto Pi's return types. One
policy source, and `make lint`'s existing `JQFILTER` sync check keeps covering
it unchanged. The kit installs the same jq filter heredoc as the other two.

**Two-phase hard stop**, because `tool_result` cannot terminate:

```ts
pi.on("tool_result", (e) => {
  if (BLOCK_RE.test(text(e))) {
    blocked = advice(text(e));           // verdict from the jq filter
    return { content: [{ type: "text", text: blocked }], isError: true };
  }
});

pi.on("tool_call", () => {
  if (blocked) return { block: true, reason: blocked, terminate: true };
});
```

Detected on the result, turn ended on the next tool call. Net effect matches
`sbxclaude`, one beat later.

### Files

- **`kits/sbxpi/spec.yaml`** — add the jq-filter heredoc install step (copied
  from `kits/sbxclaude`) and the extension install step; rewrite the
  `agentInstructions` network-guard paragraph to describe the two-phase stop.
- **`kits/sbxpi/files/home/.pi/agent/settings.json`** — add
  `"extensions": ["/usr/local/lib/sbxagent/network-block.ts"]`.
- **`tests/toolchain_test.sh`** — extend the `sbxpi` block: the extension is
  registered, the jq filter is present at the expected path, and the filter
  still passes the same probe payloads the other kits assert on.
- Consider **`~/.pi/agent/APPEND_SYSTEM.md`** (appended to the system prompt
  at higher authority than `AGENTS.md`) as a belt-and-braces restatement of
  the "do not work around a block" rule.

### Known limitation — document it, do not paper over it

`sbxclaude`'s managed settings are root-owned and cannot be overridden. Pi has
no managed-settings equivalent, so the guard is weaker in two ways: the agent
can edit its own `~/.pi/agent/settings.json`, and — because
`defaultProjectTrust` is `"always"` — a mounted repo's `.pi/settings.json` can
override the `extensions` array. That is the accepted cost of a smooth launch
and honoured project config. It goes in the Stage 3 README row verbatim.

### Verification

1. `make lint` — the `JQFILTER` sync check must still pass with the guard
   reusing the same filter.
2. `make test-toolchain AGENT=pi`.
3. **Guard end-to-end** — have Pi run a command against a host that is not on
   the allowlist. Confirm the result is rewritten with the `sbx policy allow`
   advice **and** that the next tool call is blocked and the turn ends. No
   reference implementation exists for this anywhere, so test it deliberately
   rather than assuming.
4. **Routing failure is loud** — temporarily pin a provider that cannot serve
   the model and confirm Pi surfaces the OpenRouter
   `404 "No allowed providers are available"` as a non-zero exit or error
   event. Several other harnesses have shipped bugs misclassifying that 404 as
   success; verify Pi does not.
5. **Headless footgun** — if any test drives `pi -p --mode json`, pipe an
   empty string rather than letting stdin be `/dev/null`; Pi hangs forever
   otherwise (upstream issue #4303).

**Done when:** a blocked host reliably ends the turn, and the limitation above
is written down.

---

## Stage 3 — Docs

**Goal:** the repo describes four kits instead of three, accurately.

- **`README.md`** — add `sbxpi` to the intro list, the "one script serves N
  commands" prose, the Mermaid diagram, the Supported agents table (new row:
  Pi / no parent kit / `pi` / `AGENTS.md` /
  `~/.pi/agent/{models,settings}.json` / network-block guard **with the
  override caveat from Stage 2**), the install-symlink instructions, the usage
  example, and the "all N …" counts. Add **Pinned toolchain versions** rows
  for `@earendil-works/pi-coding-agent` and `@upstash/context7-pi`. Leave
  `sbxpi` out of the GitHub-MCP-config table and the `<agent> mcp list`
  sentence; add one sentence: Pi has no built-in MCP, so this kit registers no
  MCP servers (the `github-mcp-server` binary is installed for toolchain
  parity only; Pi uses `git`/`gh` directly). Add an **OpenRouter setup**
  subsection:

  ```bash
  echo "$OPENROUTER_API_KEY" | sbx secret set openrouter
  # And again as a custom secret, to work around
  # https://github.com/docker/sbx-releases/issues/25
  sbx secret set-custom --sandbox <sbxpi-sandbox-name> \
    --host openrouter.ai --env OPENROUTER_API_KEY \
    --value "$OPENROUTER_API_KEY"
  ```

  `--sandbox` takes the actual `sbxpi-…` sandbox name, not a fixed one.
  Add a short **note** (not a required setup step) that OpenRouter will
  complete a request through another provider and bill OpenRouter credits if a
  BYOK key fails, and that a workspace "never use shared capacity" setting
  closes that path — flagged for awareness only, since the same configuration
  already works in md2okf.
- **`AGENTS.md`** (repo root) — update the "There are three" sentence and kit
  list, the `scripts/sbxagent` symlink list, and reword "validates all three
  kits" to "every kit" so a fifth needs no edit.
- **`CHANGELOG.md`** — `## [Unreleased]` / `### Added` entry for `sbxpi`
  (no parent kit, OpenRouter→DeepInfra pin, Context7 as a native package, no
  built-in MCP), matching existing entries' voice.

### Verification

`make lint` — markdownlint and cspell over the changed docs. Then re-read the
Supported agents row against what Stage 2 actually shipped, so the guard
column is true.

**Done when:** nothing in the repo still says "three".

---

## Explicitly not doing

- **No `pi.dev` cleanup on the other three kits.** They keep the entry; this
  work does not touch `kits/sbxclaude`, `kits/sbxcodex`, or `kits/sbxcursor`.
- **No OpenRouter dashboard changes.** The existing BYOK configuration is
  known-good from md2okf; documented as a note only.
- **No `pi-mcp-adapter`.** MCP is deferred past v1, not designed around.
- **No container hardening pass** (capability drops, `no-new-privileges`).
  The siblings do not do it; resemblance wins.
