# Plan: upgrade `sbxpi` to Pi 1.3.0

## Context

`sbxpi` pins Pi `0.84.4` and installs it with `npm install -g`. Pi `1.3.0`
adds MCP, code mode and new trace records, and since 1.0.1 it no longer ships
a lockfile. `tmp/upgrade-pi-130.md` lists the options. `decisions.md` picks
them: run Pi from Docker's Pi image pinned by digest (D3, D8), add GitHub MCP
(D1), keep the guard Bash-only (D2-A), update the trace skill (D4), plus some
small config changes (D5–D7, D9, D10).

What we want at the end: one branch where `sbxpi` runs Pi 1.3.0 from a
digest-pinned image, has GitHub MCP, reads 1.3.0 traces correctly, and has
been checked live on the host.

Facts checked while planning:

- `docker.io/sbx/pi-image` is built `FROM docker/sandbox-templates:shell-docker`
  (`docker/sbx-kits-contrib` `pi/Dockerfile`), so Docker, apt and Node 22.22.1
  stay the same. The image also adds `fd-find` and an `fd` symlink, and
  builds amd64 and arm64 together.
- Where Pi lands in the image:
  - The template sets `NPM_CONFIG_PREFIX=/usr/local/share/npm-global` and puts
    `/usr/local/share/npm-global/bin` on PATH *before* `/usr/local/bin`.
  - So `command -v pi` finds the npm-global bin. `/usr/local/bin/pi` is only
    a fallback symlink.
  - The package lives under `npm root -g`.
- Pi 1.3.0 config (Context7 `/earendil-works/pi/v1.3.0`):
  - `~/.pi/agent/mcp.json` takes `mcpServers.<name>.{command,args,env,exposure}`,
    and `autoEnableCodemode` sits next to `mcpServers`.
  - `env` values expand `${VAR}`.
  - `tool_search` is enabled with `"defaultTools": ["+tool_search"]`.
  - `pi mcp list [--json]` exits 1 if an entry is invalid or an enabled
    server is not connected.
- Deferred MCP tools can still be called from code mode (`mcp.md`: "Tools
  with `codemode` or `deferred` exposure can be reached through either
  indirect mechanism"). The code-mode tool just doesn't list them.
  `autoEnableCodemode: false` only stops MCP from switching code mode on.
  - So with D2-A, GitHub MCP results are not inspected by the guard, whether
    called directly or from a code-mode script the user turned on.
  - Docs must say this plainly.
- The `github` credential shape comes from Docker's `github-clone` mixin
  (`docker/sbx-kits-contrib`):
  - `apiKey.name: GH_TOKEN`, `proxyManaged: true`
  - inject `api.github.com` as `Authorization: Bearer %s`
  - inject `github.com` as `Authorization`, `username: x-access-token`,
    `format: "%s"`
  - `SBX_CRED_GITHUB_MODE=none` means no host secret was bound when the
    sandbox was created.
  - Both hosts are already on `sbxpi`'s allowlist.

## Workflow (applies to every stage)

- AGENTS.md: no `git commit` or `push` by me. Changelog entries go under
  `## [Unreleased]`. No version bump.
- Each stage ends with a pause, in this order:
  1. I run the sandbox checks.
  2. I stage only that stage's paths with an explicit `git add <paths>`.
  3. I draft the commit message.
  4. The user runs any host checks and commits.
  5. Only then does the next stage start.
- Stage new files (for example `mcp.json`) before running `make lint`. Lint
  only sees files listed by `git ls-files`.
- Never run `git add -A` or `git add .`. The worktree has unrelated untracked
  files: `.claude/settings.local.json`, `decisions.md`, `review-plan.md`.
- Skills:
  - `skill-creator` before editing the trace skill (Stage 1).
  - `readme` before editing `README.md` (Stages 2 and 3).
  - `context7-docs` before writing code against Pi's formats.

## Stage 0 — pick the image digest (user, on host)

This reads Pi's `package.json` from both platform images without running
them, so it works without CPU emulation:

```bash
docker buildx imagetools inspect docker.io/sbx/pi-image:latest   # note the top "Digest:"
D=sha256:<index digest>
for p in linux/amd64 linux/arm64; do
  c=$(docker create --platform "$p" "docker.io/sbx/pi-image@$D")
  docker cp "$c:/usr/local/share/npm-global/lib/node_modules/@earendil-works/pi-coding-agent/package.json" - \
    | tar -xO | jq -r '"\(.name) \(.version)"'
  docker rm "$c" >/dev/null
done
```

- Pin the **index** digest, so the spec names exactly the manifest list that
  was checked.
- Use it only if both platforms print `1.3.0`.
- If `latest` has already moved past 1.3.0, stop and decide again. Don't fall
  back to a tag.
- The live sandbox test in Stage 2 then proves Pi actually runs on the host's
  own architecture.

## Stage 1 — trace skill for Pi 1.3.0 (D4), offline

Files are under `.claude/skills/read-pi-session-traces/`. First get the exact
field shapes from Pi's `session-format.md` at `v1.3.0`.

`scripts/pi_trace_projection.py`:

- `KNOWN_ROLES += system`, `KNOWN_TYPES += usage, context_edit`. Every new
  type gets its own branch in `project_entry()`. Without one, it falls
  through to the field-names stub (around line 209), which would hide the
  unknown-type warning without making the record readable.
- `system` message:
  - Show only section names, plus `toolsAdded` / `toolsRemoved`.
  - Never show section text.
- `usage` entry:
  - Project `kind`, `provider` and `model`, plus `usage` through the
    existing `project_usage()`.
  - Render it with `_usage_text()`.
- `context_edit` entry:
  - Project `targetId`, plus `hidden: true` when `replacement` is `null`, or
    `replaced: true` when it isn't.
  - Never render the replacement content.
- `show` annotation: if the target and a later `context_edit` are both on the
  selected path, mark the target either "hidden from later context" or
  "replaced in later context". This is the same pattern already used for
  compaction and branch summaries.
- Assistant messages: show `thinkingLevel`.
- Tool results: show the `nestedCalls` count.

`scripts/pi_trace_commands.py`:

- Standalone `usage` entries count as a new `auxiliary` source, attributed
  `provider/model`.
- `nestedCalls` go in a separate `nestedTools` section, keyed by nested tool
  name. Each entry has `calls`, `errors`, and `durationMs {total, max}` taken
  from the recorded status, error and duration.
  - They never feed the direct call/result matching.
  - They don't change direct `calls`, `errors`, `withoutResult` or
    `elapsedMs`.
- Re-pin the docstring (line 1) and the usage note (line ~689) to 1.3.0.

`SKILL.md:15` and `references/schema.md`:

- Re-pin to 1.3.0 and document each new carrier.
- Add the `auxiliary` row to the usage table (lines 105–111).
- Document the `nestedTools` section and the `context_edit` annotation.

`tests/pi_trace_test.py` gets one test per behaviour:

- `system` messages: a first message and a patch. No section text may leak.
- A `usage` entry with `kind: "cache_warm"` and a cost, counted under
  `auxiliary` and in the total.
- `context_edit` with a `null` replacement, and with a non-null replacement.
  The `show` annotation is checked for both.
- `nestedCalls`, counted in `nestedTools`, with the direct-call numbers
  unchanged.
- `thinkingLevel`.

`CHANGELOG.md`, Changed: the trace skill reads Pi 1.3.0 traces and counts
standalone usage.

## Stage 2 — Pi 1.3.0 from the pinned image (D3, D8, D2-A, D5–D7, D9, D10)

`kits/sbxpi/spec.yaml`:

- `sandbox.image: "docker.io/sbx/pi-image@sha256:<Stage 0 digest>"`. Rewrite
  the comment at lines 17–22: image reuse, not `extends:`, and the frozen
  base (D8).
- Delete the "Pi coding agent" `npm install` step (lines ~536–562).
- Drop `fd-find` from the apt list, along with its comment, since the image
  owns it now. Update the instructions line about `fdfind`: both `fd` and
  `fdfind` are on PATH.
- `CONTEXT7_PI_VERSION=0.1.3` (line ~566).
- Allowlist comment at line ~123: npm is no longer used for
  `pi-coding-agent`.
- Agent instructions, lines ~86–89: Pi now supports MCP. Stage 2 wording is
  "this kit configures no MCP servers yet"; Stage 3 replaces it.
- Guard heredoc: add the D2-A comment by the `tool_result` return. It says
  `structuredContent` is left out on purpose:
  - Pi then drops the bash `structuredContent`, and code mode throws
    `Error(remedy)` into the script.
  - A bash-shaped value would resolve normally, so a script could ignore it.
  - Make the same edit in the `BEGIN-SYNCED` body of `kits/network-block.ts`.
    `make lint` checks that the two match.

`kits/sbxpi/files/home/.pi/agent/settings.json`:

- Add `"$schema": "https://pi.dev/schemas/settings.schema.json"` as the first
  key (D7).
- Add the D10 `compaction.modelOverrides` block, exactly as in
  `decisions.md`.
- Do not set `tuiMode` (D5) or `cacheWarming` (D6).

`kits/sbxpi/files/home/.pi/agent/models.json`: add
`"$schema": "https://pi.dev/schemas/models.schema.json"` as the first key.

`tests/toolchain_test.sh`:

- `EXPECTED_PI_VERSION="1.3.0"`, `EXPECTED_CONTEXT7_PI_VERSION="0.1.3"`.
- The sbxpi block checks the install through known roots only. It does not
  search the filesystem, so the user's project can't trip it. `readlink -f`
  is fine here because the test runs inside the Linux sandbox, like the
  existing `stat -c`.
  - The `readlink -f` of `command -v pi` lies inside
    `$(npm root -g)/@earendil-works/pi-coding-agent/`.
  - `readlink -f /usr/local/bin/pi` resolves to that same file.
  - `/opt/pi` does not exist.
  - There is no `@earendil-works/pi-coding-agent` anywhere under
    `~/.pi/agent/npm/node_modules`, so Context7 pulled in no second Pi.
  - `$schema` is set in both JSON files, and the compaction override values
    match.

Docs:

- `README.md:164–171` (with the `readme` skill): update the Pi row and
  paragraph. Pi is built on Docker's Pi image, pinned by digest. Say "no
  built-in Pi agent" (D8 / doc C7).
- `docs/toolchain.md`:
  - lines 53–56
  - line 85: Pi `1.3.0`, source is the image digest in
    `kits/sbxpi/spec.yaml`
  - line 86: `0.1.3`
  - lines 99–101: the base is now frozen with the digest, and `fd` comes
    from the image
- `docs/agents.md`: Stage 3 handles the MCP section. Stage 2 only fixes "Pi
  has no built-in MCP", so the docs aren't wrong in between.

`CHANGELOG.md`:

- Changed: Pi 1.3.0, now from Docker's Pi image pinned by digest. npm no
  longer pins Pi's dependencies, and Pi's `protobufjs` override is not
  applied (D3).
- Added: the compaction override for `qwen2.5-coder:7b`, and the `$schema`
  declarations.
- Changed: Context7 Pi package 0.1.3.

Host check after Stage 2: Verification sections A–C.

## Stage 3 — GitHub MCP and credential (D1, D2 docs)

**Host preflight, before this stage's sandbox is created.** The credential
mode is fixed when the sandbox is created, so bind the secret first. Use the
same command as `docs/setup.md`, which passes the token on stdin:

```bash
echo "$(gh auth token)" | sbx secret set github
```

`kits/sbxpi/spec.yaml`:

- `credentials:` gets a second entry, `service: github`, with the
  `github-clone` inject block quoted above.
- `entrypoint:` becomes the sibling wrapper, shaped like
  `kits/sbxcodex/spec.yaml:30-50`:
  - export `GITHUB_TOKEN` and `GITHUB_PERSONAL_ACCESS_TOKEN` from `GH_TOKEN`
  - then `exec pi "$@"`, with `sbxpi-entrypoint` as `$0`
- Add the `github-mcp-server` v1.12.2 install step. Copy it verbatim from
  `kits/sbxcodex/spec.yaml:211-242`, with the same SHA-256 values.
- Allowlist comment (lines 136–137) and agent instructions:
  - GitHub MCP tools are deferred, so `tool_search` loads them.
  - `gh` and `git` now carry the proxy credential.

`kits/sbxpi/files/home/.pi/agent/mcp.json` (new; stage it before running
lint):

```json
{
  "autoEnableCodemode": false,
  "mcpServers": {
    "github": {
      "command": "github-mcp-server",
      "args": ["stdio"],
      "env": { "GITHUB_PERSONAL_ACCESS_TOKEN": "${GITHUB_TOKEN}" },
      "exposure": "deferred"
    }
  }
}
```

There is no `toolExposure`, so no tools are promoted to direct.

`settings.json`: add `"defaultTools": ["+tool_search"]`.

`tests/toolchain_test.sh`:

- Lines 94–99: check the `github-mcp-server` version on every kit.
  - Delete the sbxpi "absent" assertion (lines ~588–593).
  - Delete its comments at lines 94–95 and 580–583.
- New sbxpi config checks:
  - `mcp.json` is valid JSON and owned by the user.
  - It has `autoEnableCodemode == false` and the github entry exactly as
    above, with no `toolExposure`.
  - `settings.json` `defaultTools` contains `+tool_search`.
- Credential gate: if `GH_TOKEN` is empty or `SBX_CRED_GITHUB_MODE` is
  `none`, fail with this message: "no GitHub token was bound when this
  sandbox was created. See `docs/setup.md`, run
  `echo "$(gh auth token)" | sbx secret set github` on the host, then
  `./scripts/sbxpi rm && ./scripts/sbxpi create`."
- `gh auth status` succeeds.
- Export `GITHUB_TOKEN` and `GITHUB_PERSONAL_ACCESS_TOKEN` from `GH_TOKEN`,
  like the entrypoint does, because `sbx exec` skips the entrypoint.
- `pi mcp list --json` exits 0 and shows `github` connected, with a non-empty
  tool list.
- One authenticated read-only request through the server, using an inline
  `python3 - <<'PY'` harness (standard library only). Steps:
  1. Start `github-mcp-server stdio`. A reader thread puts each stdout line
     into a queue.
  2. Send `initialize` (id 1) and wait for the response with id 1.
  3. Send `notifications/initialized`.
  4. Send `tools/call` `get_me` (id 2) and wait for id 2.
  5. Require `isError` to be false. Parse `result.content[0].text` as JSON
     and require a non-empty `login`.
  - One overall deadline of 60 s.
  - On any failure, print the captured server stderr and exit non-zero.

Docs:

- `docs/agents.md`:
  - Pi trust paragraph (29–36): a trusted project's `.pi/mcp.json` can add or
    override servers, and its `+builtin:mcp` beats the user's
    `-builtin:mcp`.
  - Coverage-gap paragraph (44–48): the gap is now real for `sbxpi`. GitHub
    MCP results aren't inspected, whether called directly or from a
    code-mode script the user turned on (D2-A).
  - GitHub MCP section (56–62):
    - `sbxpi` installs the server.
    - Explain the credential path, and the deferred exposure behind
      `tool_search`.
    - `autoEnableCodemode` is off. That stops MCP from switching code mode
      on, but code mode can still call the GitHub tools once the user
      enables it.
  - Add an `mcp.json` row to the table at lines 74–76 (`"${GITHUB_TOKEN}"`,
    Pi).
  - Add `pi mcp list` at line 124.
  - Add the `/share` warning: a shared transcript can contain secrets.
- `docs/setup.md` (lines 21–26):
  - Public Git operations still need no token.
  - On `sbxpi`, the GitHub MCP server, authenticated `gh` and `/share` need
    the `github` secret.
  - So does `make test-toolchain AGENT=pi`.
  - Bind the secret before creating the sandbox, or recreate it afterwards.
- `README.md` (with the `readme` skill): the Pi MCP column becomes
  `~/.pi/agent/mcp.json`. "No MCP support" goes.
- `docs/toolchain.md`:
  - line 84: `github-mcp-server` on every kit
  - lines 53–56: Context7 stays native, and GitHub is MCP plus `gh`

`CHANGELOG.md`, Added:

- the GitHub MCP server, deferred, behind `tool_search`
- the GitHub credential for `sbxpi`, so `gh`, `git` over HTTPS and `/share`
  are now authenticated (needs the `github` secret)

Host check after Stage 3: preflight first, then Verification section D.

## Verification

Inside the sandbox, after every stage (with new files staged first):

- `make lint`. It covers the heredoc sync, esbuild over the guard, cspell and
  shellcheck. Put new words in `.cspell.json`.
- `env -u SBXAGENT_LITE -u NETWORK_ALLOWLIST make test-unit`
- `python3 .claude/skills/read-pi-session-traces/tests/pi_trace_test.py`
- From Stage 2 on: `sbx kit pack kits/sbxpi --output <scratchpad>/sbxpi.zip`.
  This also checks that the spec accepts a digest image reference.

On the host (user), after Stages 2 and 3:

```bash
make validate
./scripts/sbxpi rm
./scripts/sbxpi create
make test-toolchain AGENT=pi
```

Manual checks in the new sandbox:

- **A. Base.**
  - `pi --version` prints `1.3.0`.
  - `sbx policy log` on the host shows no new blocked hosts at startup.
  - The agent shows up correctly in `sbx ls`. The image sets flavor `pi`.
- **B. Guard (D2-A).**
  - Direct path: ask Pi to `curl https://example.org`. Expect the remedy,
    then the run ends at the next call.
  - Code mode, uncaught: run `pi -t +codemode` and paste this script
    verbatim:
    `await tools.bash({ command: "curl -sS https://example.org" }); return "done";`
    Expect `Script error:` followed by the remedy.
  - Code mode, caught:
    `try { await tools.bash({ command: "curl -sS https://example.org" }); } catch (e) {} return await tools.bash({ command: "echo still-here" });`
    Expect the second call to be refused with the remedy.
- **C. Models, TUI, traces.**
  - `/model` lists the pinned OpenRouter models, and one tool call works on
    each.
  - One tool call works on an Ollama model, if Ollama is enabled.
  - Fullscreen TUI: scroll, select, copy, detach, re-attach (D5). Pin
    `"tuiMode": "regular"` only if one of these breaks.
  - The trace skill's `inspect` on this session shows `system` messages and
    counts any `usage` entries.
- **D. GitHub (Stage 3).**
  - Without `-t +codemode`, a GitHub question makes Pi call `tool_search` and
    then an `mcp__github__*` tool.
  - `codemode` does not appear among the active tools, so it didn't switch
    itself on. This checks auto-activation only. Code mode *can* reach the
    deferred server once it's enabled.
  - `/share`, in a **fresh, throwaway session** that only has a harmless
    prompt (for example "say hi"):
    1. Open the gist link to confirm it worked.
    2. Delete the gist with `gh gist delete <id>`.
    3. Note the deletion in the checklist.
    - Never share the session used for the checks above.
