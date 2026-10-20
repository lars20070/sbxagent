# Upgrading `sbxpi` from Pi 0.84.4 to Pi 1.3.0

Decision document, researched 2026-10-19. Nothing in the repository has been
changed yet; every section below ends in a decision for you to make.

- **From:** `@earendil-works/pi-coding-agent` `0.84.4`, released 2026-08-28,
  pinned at [`kits/sbxpi/spec.yaml:538`](kits/sbxpi/spec.yaml)
- **To:** `1.3.0` (2026-10-15), current `latest` on npm
- **Distance:** 17 releases — 0.85.0, 0.85.1, 0.86.0, 0.86.1, 0.87.0, 0.87.1,
  0.99.0, 0.99.1, 0.99.2, 1.0.0 – 1.0.4, 1.1.0, 1.2.0, 1.3.0

## 0. Summary

Pi reached 1.0 along the way. In
[semantic versioning](#11-semantic-versioning-and-what-10-means) that is a
stabilisation milestone, not a breaking change in itself. Incompatibilities
can come from anywhere in the 0.84.4 → 1.3.0 interval, because 0.x releases
make no compatibility promise. The changes that matter for this repo are not
the ones Pi labels "Breaking": those mostly hit SDK and custom-provider
authors. Four things matter here.

1. **Pi has MCP now** (0.99.0). The repo states in six places that it does
   not, and the kit's whole GitHub story rests on that.
2. **npm installs are no longer reproducible** (1.0.1). Pi stopped shipping its
   dependency lockfile in the npm package. The kit's current
   `npm install -g` would silently float about 100 transitive packages.
3. **Session traces gained new record types** (0.86.0, 0.87.0). The
   `read-pi-session-traces` skill would silently undercount cost.
4. **The network-block guard still works.** Its API is unchanged, and on the
   new codemode path it still refuses every tool call after a block. One
   weaker spot: a script that catches the error can keep the remedy from
   reaching the model. That was checked in Pi's source, not assumed (see
   [C2](#c2-the-network-block-guard)).

### Decision table

| # | Decision | Options | Recommendation | Effort | Risk if wrong |
| --- | --- | --- | --- | --- | --- |
| D1 | What `sbxpi` does with Pi's new MCP support | A: parity, no servers configured · B: add `github-mcp-server` like the siblings · C: disable the built-ins | **A now, B as a follow-up** | A: docs only · B: medium | Low |
| D2 | Network-block guard extension | A: unchanged, add a live codemode test · B: also return a bash-shaped `structuredContent` · C: widen it to MCP tools | **A** (C only together with D1-B) | Tiny | Medium: B would weaken the guard |
| D3 | How Pi is installed | A: keep `npm install -g` · B: `curl pi.dev/install.sh \| sh` · C: fetch upstream's per-release lockfile, verify its SHA-256, fill in the seven missing integrity hashes, `npm ci` · D: vendor a completed lockfile in the repo | **C**, into `/opt/pi` (hygiene, not a security boundary) | Medium | Medium: A is unreproducible |
| D4 | Trace-skill update timing | Same change · follow-up | **Same change** | Medium | Silent cost undercount |
| D5 | TUI mode (fullscreen is the new default) | Keep fullscreen · pin `tuiMode: "regular"` | **Keep, but check it during the live test** | Tiny | Cosmetic |
| D6 | Prompt-cache warming (on by default) | Keep `"streaming"` · `"off"` | **Keep** | None | Small cost either way |
| D7 | `$schema` in `settings.json` / `models.json` | Add · don't | **Add**; leave a lint-time schema check optional | Tiny | None |
| D8 | Base `sbxpi` on Docker's own Pi kit | Yes · no | **No** | — | High: unpinned, Anthropic-only |
| D9 | Context7 Pi package `0.1.2` → `0.1.3` | Bump · stay | **Bump** | Tiny | None |
| D10 | Per-model compaction for small Ollama models (opportunity) | Add · don't | **Add**, at least for `qwen2.5-coder:7b` | Tiny | Low |

[§3](#3-new-features-worth-considering) lists further opportunities that are
not needed for the upgrade.

---

## 1. Concepts used in this document

This section is for readers without a computer-science background. Skip any
subsection you already know.

### 1.1 Semantic versioning and what "1.0" means

A version `MAJOR.MINOR.PATCH` is a promise about compatibility
([semver.org](https://semver.org)). PATCH fixes bugs, MINOR adds features
without breaking existing users, and MAJOR may break them. Before 1.0 the
promise is weaker: `0.y.z` means "anything may change", and 1.0.0 is the
release that first *defines* the public API. It need not break anything
itself; Pi's 1.0.0 changelog has no "Breaking Changes" section.

Pi used 0.x for a long time, then jumped 0.87 → 0.99 → 1.0 in ten days. Its
biggest functional change, MCP and codemode, landed in 0.99.0, *before* 1.0.
For this upgrade, the whole 0.84.4 → 1.3.0 interval is where
incompatibilities can come from, not the 1.0 tag in particular.

### 1.2 Dependency graphs, lockfiles and reproducibility

An npm package lists its direct dependencies, usually as version *ranges*
(`^5.0.0` means "any 5.x"). Each dependency has dependencies of its own. The
full set, the *transitive closure*, here runs to about 120 packages for Pi.

When the ranges are resolved depends on *when* you install. Two installs a
week apart can produce different trees if any package published a new version
in between. That is like an experiment whose boundary conditions depend on
the date it is run: same procedure, different result.

A **lockfile** (`package-lock.json`, or `npm-shrinkwrap.json` when it ships
inside a published package) fixes every node of that graph to an exact
version and download URL. Running `npm ci` against it installs exactly those
versions, or fails loudly. "Same versions" is not quite "same bytes", though:
that additionally needs a content hash for every entry ([§1.3](#13-content-hashes-and-integrity)).

### 1.3 Content hashes and integrity

A lockfile entry *may* also carry an `integrity` field such as
`sha512-/y4/bH9Y…`. That is a cryptographic hash of the package tarball: a
fixed-length fingerprint, where changing one bit of input changes about half
the bits of output. Finding a second input with the same fingerprint is
computationally infeasible. If a registry or a man-in-the-middle swaps the
tarball, the hash no longer matches and the install aborts. An entry *without*
`integrity` gets no such check: npm downloads whatever the URL serves.

The kit already uses this pattern for the `sbx` binary (`expected_sha256=…` in
the spec). [D3](#c3-installation-and-supply-chain) extends it from one file to
the Pi dependency tree. The idea is to hash the lockfile, which itself holds
the hashes of the packages. That is a two-level hash tree, the same idea
behind git and Merkle trees.

A hash tree is only as complete as its leaves: a leaf with no hash is
covered only by its *name*, not by its *content*. Pi's published lockfile has
seven such leaves (C3). Closing the chain means filling them in.

### 1.4 Extension hooks (event handlers)

Pi exposes *events* at fixed points of its agent loop: `agent_start`, then for
each tool call `tool_call` before it runs and `tool_result` after it returns.
An *extension* is a TypeScript module that registers *handlers* for these
events. A handler may observe, modify or veto what passes through.

Several handlers on one event compose in order, each seeing the previous
one's output, much like operators applied in sequence. The repo's
network-block guard
([`kits/network-block.ts`](kits/network-block.ts), shipped as a heredoc in the
spec) is one such extension.

### 1.5 Why the guard stops "one call late"

A `tool_result` handler may rewrite a result, but it cannot end the run; only
a `tool_call` handler can, by vetoing with `terminate: true`. So the guard
works in two phases:

1. It replaces the blocked command's output with the remedy and arms a flag.
2. It vetoes the *next* tool call and ends the run.

This is the asynchrony between observation and actuation that control
engineers know well. The guard cannot act at the moment it observes, only at
the next actuation point.

### 1.6 MCP: Model Context Protocol

MCP is a remote-procedure-call protocol (JSON-RPC 2.0) between an agent and a
*tool server*. The server advertises a list of tools, each with a JSON schema
for its arguments; the agent calls them and gets results back. Transport is
either `stdio`, where the agent spawns the server as a child process and they
talk over pipes, or HTTP. The other three kits run `github-mcp-server`
(GitHub API tools) and Context7 (library docs) over stdio.

### 1.7 Codemode: the model writes a program instead of issuing calls

Normally a model emits one tool call, waits for the result, then emits the
next: one network round trip and one model turn per call. With **codemode**
the model writes a short JavaScript program that calls many tools — in
parallel, with loops and filtering — and only the program's printed output
comes back.

The program runs in **QuickJS**, a small JavaScript interpreter compiled to
WebAssembly, inside a worker. It has no file system, network or timers; its
only way out is the `tools.*` functions Pi hands it. Each such call is a
*nested tool call*. It goes through the same `tool_call` / `tool_result`
pipeline as a direct call, which is why the guard still sees it.

The analogy is a batch measurement script versus taking each reading by hand.

### 1.8 Prompt caching

LLM providers can cache the internal state computed for a prompt *prefix*.
If the next request starts with exactly the same bytes, that work is billed
at a large discount. Caches expire after a few minutes. *Cache warming* sends
a cheap request just before expiry to keep one alive, like refreshing DRAM.

Pi 0.86.0 added cost-aware warming. It only fires when Pi estimates the
refresh saves at least $0.05.

### 1.9 Project trust

When Pi starts in a folder containing `.pi/settings.json`, `.pi/extensions/`
and similar, it asks before loading them. Those files can run arbitrary code
as you. The kit sets `defaultProjectTrust: "ask"`. Trust controls *loading*
only. It is not a security boundary for what the agent does afterwards; Pi's
own [`security.md`](https://github.com/earendil-works/pi/blob/v1.3.0/packages/coding-agent/docs/security.md)
says so explicitly.

---

## 2. Changes that affect sbxagent

Each subsection covers what changed upstream, why it matters here, and the
repo files involved, then the options and a recommendation.

### C1. Built-in MCP, codemode and tool search

**Upstream.** Pi 0.99.0 (2026-09-29) added
([#10040](https://github.com/earendil-works/pi/issues/10040)):

- **MCP client.** Servers over stdio or streamable HTTP, with OAuth, read from
  `~/.pi/agent/mcp.json` (user) and `.pi/mcp.json` (project, only after trust).
  Managed with `/mcp` and `pi mcp add|remove|list|login|logout`.
- **`codemode` tool.** See [§1.7](#17-codemode-the-model-writes-a-program-instead-of-issuing-calls).
- **`tool_search` tool.** Loads tool declarations on demand, so large MCP
  servers don't bloat every request.
- All three ship as **built-in extensions** named `builtin:mcp`,
  `builtin:codemode` and `builtin:tool-search`. They load by default and can
  be disabled with `"extensions": ["-builtin:mcp"]` or `pi config`, or for one
  run with `--no-mcp`.

These were refined across 0.99.2, 1.0.x and 1.2.0. Servers now connect in the
background. MCP tool names are normalised to `mcp__<server>__<tool>`, with
`-` replaced by `_` (0.99.2,
[#10239](https://github.com/earendil-works/pi/issues/10239)). Projects can
override user servers (1.0.1).

**Exposure modes.** Each MCP server or tool has an exposure:

| Exposure | Meaning |
| --- | --- |
| `codemode` (default) | Callable only from codemode scripts; not declared to the model |
| `deferred` | Declared once `tool_search` loads it |
| `direct` | Declared like a built-in tool |
| `hidden` | Registered but unreachable |

Pi *automatically activates `codemode`* when a server with `codemode`
exposure connects. Setting `"autoEnableCodemode": false` in `mcp.json`
prevents this.

**What is not on by default.** `codemode` and `tool_search` are registered but
*inactive* unless named in `defaultTools` or `--tools`, or auto-activated by
an MCP server. With no `mcp.json`, nothing changes in a fresh `sbxpi`
session: the default tool set is still `read`, `bash`, `edit`, `write`.

**Why it matters here.** The repo's statements that Pi has no MCP become
false. These lines need rewording:

- [`kits/sbxpi/spec.yaml:88`](kits/sbxpi/spec.yaml): in the agent's own
  instructions, so the model would be told something untrue
- [`README.md:163`](README.md) and the `MCP config: none` cell in the agent
  table at `README.md:161`
- [`docs/agents.md:61`](docs/agents.md)
- [`docs/toolchain.md:54`](docs/toolchain.md)
- [`tests/toolchain_test.sh:94`, `:580`, `:588`](tests/toolchain_test.sh):
  comments only, but they justify the "github-mcp-server is absent" assertion

The `CHANGELOG.md` entries at lines 275 and 446 are history and stay as they
are.

#### D1: what to do with MCP

- **A. Parity upgrade (recommended now).** Ship no `~/.pi/agent/mcp.json`, and
  correct the docs to say Pi supports MCP but the kit configures no servers.
  The kit's *MCP tool exposure* stays as it is today (none) unless a
  *trusted* project brings its own `.pi/mcp.json`. Other behaviour does
  change with the upgrade (TUI, traces, cache warming, model list, retries;
  see C4–C6). The trust gate here is the same one that already guards project
  extensions, which can run arbitrary code anyway. Smallest diff; keeps the
  upgrade reviewable.
- **B. Add `github-mcp-server`, like the sibling kits (good follow-up).** That
  gives parity with `sbxclaude`/`sbxcodex`/`sbxcursor` and a richer GitHub
  toolset than `gh`. It means a separate change, larger than it first
  looks, because **`sbxpi` has no GitHub credential path today**:
  - declare the credential. The kit's only `credentials:` entry is
    `openrouter` (`kits/sbxpi/spec.yaml:157`). The siblings get `GH_TOKEN`
    from their parent kits' `github` service and re-export it as
    `GITHUB_TOKEN` / `GITHUB_PERSONAL_ACCESS_TOKEN` in an entrypoint wrapper
    (`kits/sbxcodex/spec.yaml:40-48`, `kits/sbxcursor/spec.yaml:40-49`).
    `sbxpi` has no parent, so it would have to declare the `github` service
    (env var, target host, header) itself, plus an equivalent wrapper.
    Allowlisting `api.github.com` alone does not inject anything.
  - re-add the SHA-256-pinned binary the siblings install
  - write `~/.pi/agent/mcp.json` with an `env` entry for the token (Pi
    expands `${GITHUB_TOKEN}` in `env` and `headers`). The variable has to
    exist first, which is the step above.
  - choose an exposure: `deferred` keeps requests small, `direct` for a
    handful of tools
  - decide on `autoEnableCodemode` (see O1)
  - extend the guard (D2-C)
  - add tests, including one authenticated read-only GitHub call through
    the server, and update `docs/agents.md`'s MCP table

  It is worth doing separately because it changes what the agent *can do*,
  while the upgrade only changes what it *runs on*.
- **C. Disable the built-ins** with
  `"extensions": [..., "-builtin:mcp", "-builtin:codemode", "-builtin:tool-search"]`.
  This is the tightest, but it is weaker than it looks. A trusted project's
  `+builtin:mcp` overrides the user setting
  ([settings docs](https://github.com/earendil-works/pi/blob/v1.3.0/packages/coding-agent/docs/settings.md#resources)),
  so it is not a lock. It also forecloses O1/O2 for users who want them.

**Context7 stays a native Pi package** under every option. `@upstash/context7-pi`
is the official Context7 extension. Its tool descriptions and wire format are
"copied verbatim from `@upstash/context7-mcp`" (its 0.1.0 changelog), and it
needs no `npx` fetch at runtime. Switching to the MCP server would add a moving
part for no gain.

### C2. The network-block guard

**What was checked.** `src/core/extensions/types.ts` at `v0.84.4` and
`v1.3.0`, plus the extension runner and codemode sources at `v1.3.0`.

**Unchanged — the guard needs no edit to keep working:**

- `pi.on("agent_start")`, `pi.on("tool_call")` and `pi.on("tool_result")`
  still exist with the same shapes.
- `ToolCallEventResult` is still `{ block?, reason?, terminate? }`, with the
  same `terminate` semantics: early stop once every result in the batch agrees.
- `ToolResultEventResult` still accepts `{ content, isError }`; it gained an
  optional `structuredContent`.
- `event.toolName === "bash"`, `event.input.command`, `event.content` and
  `event.details` are where the guard expects them.
- The import `import type { ExtensionAPI } from "@earendil-works/pi-coding-agent"`
  is unchanged. It is type-only, so esbuild strips it.

**New — nested calls.** A codemode script's `tools.bash({command})` (and an MCP
bridge's calls) go through `tool_call` and `tool_result` "like model-issued
calls" ([extensions docs](https://github.com/earendil-works/pi/blob/v1.3.0/packages/coding-agent/docs/extensions.md#tools)).
They carry an extra `parentToolCallId`, and their results go to the *script*,
not the transcript. Tracing what happens when a nested `curl` hits a block:

1. Bash returns text containing `Blocked by network policy: domain …`, plus a
   machine-readable `structuredContent` `{ output, truncated, exit_code, wall_time_seconds }`.
2. The guard's `tool_result` handler returns `{ content: [remedy], isError: true }`.
3. Pi's runner ([`runner.ts:1201-1205`](https://github.com/earendil-works/pi/blob/v1.3.0/packages/coding-agent/src/core/extensions/runner.ts))
   sees `content` replaced without `structuredContent` and **deletes**
   `structuredContent`, since it may no longer match the new content.
4. Codemode's `toScriptValue()` ([`execute.ts:428-434`](https://github.com/earendil-works/pi/blob/v1.3.0/packages/coding-agent/src/extensions/codemode/execute.ts))
   returns `structuredContent` if present. Otherwise, because `isError` is
   true, it **throws `Error(remedy)`** into the script.
5. If the script does not catch it, the codemode result reads
   `Script failed … Script error: <remedy>`, and the model sees the remedy.
   If the script *does* catch it, every later `tools.*` call in that script
   hits the armed `tool_call` handler and is refused, so the script cannot
   route around the block through another tool.
6. The model's next top-level call (codemode or anything else) is vetoed with
   `terminate: true`, exactly as today.

**Limit of step 5: enforcement holds, visibility does not.** A script can
catch the exception, make no further tool call and return ordinary output.
The model then never sees the remedy. The run ends only if the model attempts
another tool call; if it answers in prose instead, it may simply not mention
the block. The request itself stays blocked, so the network policy is not
defeated. What weakens is the guarantee that the block gets *reported*. The
direct `bash` path has no such gap, because there the remedy *is* the tool
result the model reads.

#### D2: guard options

- **A. Leave the guard as is; add a live codemode test (recommended).** The
  behaviour above is the best available: a block turns into a script
  *exception*, which surfaces unless the script deliberately catches it, and
  any further tool use is refused either way. Add one comment to the
  extension explaining why it
  deliberately does not set `structuredContent`, so nobody "fixes" it later.
  Add a manual verification step (see [§5](#5-verification-plan-for-the-upgrade)).
- **B. Return a bash-shaped `structuredContent`** (`{output: remedy, exit_code: 1, …}`),
  as Pi's docs suggest for redacting handlers. **Not recommended.** By step 4,
  the script would then *resolve normally* with a nonzero exit code, which a
  script can easily ignore (`if (r.exit_code) …`). B turns a hard failure into
  a soft one.
- **C. Widen the guard beyond `bash`.** Today it only inspects `bash`, matching
  `Bash|WebFetch` on `sbxclaude`. Every MCP tool result also passes through
  `tool_result`, so the guard *could* inspect `mcp__*` results. Then a
  GitHub-MCP request blocked by the proxy would also trip it. That closes
  the coverage gap
  [`docs/agents.md:45-48`](docs/agents.md) documents, which the siblings
  share. Only worth doing together with D1-B, because without MCP servers
  there is nothing to inspect. The self-reference exemption in
  `network-block.jq` is keyed on `tool_name == "Bash"`, so an MCP payload
  would need its own `tool_name` and care with the exemption.

The guard's per-run reset (`agent_start`) is still correct. In 1.2.0, runs
started by an extension's `sendMessage(..., {triggerTurn: true})` also emit
`agent_start`, so they reset the flag like a user prompt does, which is the
intended behaviour.

The tamper story is unchanged. The guard is still registered from the
agent-editable `~/.pi/agent/settings.json`. Pi still has no admin-tier
settings. A trusted project can still add `-<path>` to `extensions`.

One qualification applies to the tamper story as it stands today, upgrade or
not. `sudo` is passwordless in this sandbox, and the agent is told so in its
own instructions (`kits/sbxpi/spec.yaml`, "Sandbox environment"). The guard
file being root-owned under `/usr/local/lib/sbxagent/` therefore stops
accidental edits and ordinary unprivileged writes, but not an agent that runs
`sudo`. [`docs/agents.md:34-35`](docs/agents.md) says the file "can be
unregistered but not rewritten"; strictly, it cannot be rewritten *without
sudo*. That is outside this upgrade's scope, but worth knowing when weighing
D3's root-owned prefix.

### C3. Installation and supply chain

**Upstream.** Up to 1.0.0 the npm package contained an `npm-shrinkwrap.json`,
a lockfile that npm honours even for `npm install -g`. 1.0.1 removed it
([#5653](https://github.com/earendil-works/pi/issues/5653)): "npm
installations no longer pin transitive dependencies … Use the pi.dev installer
for pinned installations."

Verified on the registry: `_hasShrinkwrap` is `true` for 0.84.4 and 1.0.0 and
absent for 1.0.1 and 1.3.0. 1.3.0 does pin its *direct* and internal
dependencies exactly (`@earendil-works/pi-ai: "1.3.0"`, `undici: "8.10.2"`, …;
[#10865](https://github.com/earendil-works/pi/issues/10865)). Their own
dependencies still float. Node requirement unchanged: `>=22.19.0`. No install
scripts, so `--ignore-scripts` stays safe; upstream says "Pi does not require
dependency lifecycle scripts".

**What the managed installer does.** `https://pi.dev/install.sh` downloads two
files per release from `https://pi.dev/api/installer/releases/<version>/`: a
`package.json` and a `package-lock.json`. It then installs from the lockfile.

Probed for 1.3.0: lockfile v3, 120 entries under `packages`, which is the
root entry plus 119 installed packages. Every one has an exact version and a
`resolved` registry URL. **112 of the 119 have an `integrity` hash; seven do
not.** The seven are Pi's own packages, all at `1.3.0`:

- `@earendil-works/pi-agent-core`
- `@earendil-works/pi-ai`
- `@earendil-works/pi-codemode`
- `@earendil-works/pi-coding-agent`
- `@earendil-works/pi-mcp`
- `@earendil-works/pi-telemetry`
- `@earendil-works/pi-tui`

npm cannot verify the content of these seven against the lockfile. Their
`sha512` hashes do exist on the registry (`npm view <pkg>@1.3.0 dist.integrity`
returns one for each), so the gap can be filled; see D3-C.

The `package.json` also carries `"overrides": {"protobufjs": "7.6.6"}`,
which a plain `npm install -g` **does not apply**. So the npm route is not
just unpinned; it can resolve a different `protobufjs` than upstream ships.

**Why it matters here.** The kit's philosophy, visible in
[`docs/toolchain.md`](docs/toolchain.md), is that every binary is pinned and,
where possible, checksummed. With 1.3.0 the current install line
([`kits/sbxpi/spec.yaml:561`](kits/sbxpi/spec.yaml)) would pin one package
out of 120.

#### D3: options

- **A. Keep `npm install -g …@1.3.0`.** Zero work. Rebuilds are no longer
  reproducible, and the `protobufjs` override is missed.
- **B. `curl -fsSL https://pi.dev/install.sh | sh`.** Pinned dependencies, but
  the script itself is unpinned and unverified: whatever pi.dev serves that
  day runs as the build user. It is interactive (a logo animation, a
  "Start pi now?" prompt), installs the *latest* release rather than a chosen
  one, and is built around `pi update` self-updating. That is the opposite of
  a kit pin. **Not recommended.**
- **C. Reuse the installer's artifacts, not its script (recommended).**
  1. Download `package.json` and `package-lock.json` for a fixed `PI_VERSION`
     from `pi.dev/api/installer/releases/${PI_VERSION}/`. `pi.dev` is already
     allowlisted.
  2. Compare their SHA-256 digests against values pinned in the spec, exactly
     like the `sbx` tarball step does. This pins the versions, URLs and
     override, and the 112 integrity hashes written in the lockfile.
  3. Fill in the seven missing `integrity` fields from values pinned in the
     spec, e.g. one `jq` pass over `.packages["node_modules/@earendil-works/<name>"]`.
     Take the values once from `npm view @earendil-works/<name>@<v> dist.integrity`
     when bumping. Fail the build if any of the seven entries is missing or
     already carries a *different* hash.
  4. `npm ci --ignore-scripts` in a dedicated directory such as `/opt/pi`.
     `npm ci` refuses to run if the lockfile and `package.json` disagree. With
     step 3 done, every one of the 119 tarballs has an `integrity` to be
     checked against. Without step 3, the seven Pi packages would be
     version-pinned but not content-verified.
  5. Symlink `/opt/pi/node_modules/.bin/pi` onto `PATH`.

  Bumping Pi then means updating one version, two file digests and seven
  package hashes: more than for `sbx`, but the same kind of ritual. If seven
  extra hashes feel excessive, the narrower guarantee of steps 1, 2 and 4 is
  still far better than A: an exact dependency graph plus Pi's `protobufjs`
  override, with 112 of 119 packages content-verified.

  **Sub-decision: install prefix.** Installing as root in `/opt/pi`, rather
  than as user 1000 into npm's global prefix as today, is good *hygiene*.
  It is a conventional system location, and it stops ordinary unprivileged
  writes such as an accidental `npm install -g` over it. **It is not a
  security boundary against the agent.** The agent has passwordless `sudo`
  and is told so, so it can replace anything under `/opt/pi`. Making Pi's
  code genuinely tamper-proof would need a sandbox-authority change, such as
  removing passwordless `sudo`, not different file ownership. That would
  also break workflows the kit advertises. `pi install` packages still go to
  the user-owned `~/.pi/agent/npm`, so Context7 is unaffected.
  **Recommended for hygiene.** Verify that Pi's Node compile cache (0.86.0)
  does not try to write inside the install directory; Node's default cache
  location is the OS temp dir.
- **D. Vendor a completed lockfile** (with the seven hashes already filled
  in) and `package.json` into `kits/sbxpi/files/`. That gives the same
  integrity as C, with no build-time fetch from pi.dev and no patch step.
  But kit files are copied into the user's home as UID 1000, so installing
  into `/opt/pi` needs an extra copy step, and every bump adds a 119-entry
  lockfile diff to review. A reasonable alternative if you would rather not
  depend on a pi.dev endpoint that is undocumented (it lives under
  `/api/installer/`).

**Test impact.** `tests/toolchain_test.sh` should assert `pi --version`
(already does) and that `pi` resolves to the `/opt/pi` install. That install
should be root-owned, so a plain unprivileged write fails; with sudo
available, that is a hygiene check, not a tamper check. It should also
assert no second copy of `@earendil-works/pi-coding-agent` under
`~/.pi/agent/npm/node_modules`. The Context7 package lists Pi as a peer
dependency, and Pi suppresses automatic peer installation for managed
packages
([packages docs](https://github.com/earendil-works/pi/blob/v1.3.0/packages/coding-agent/docs/packages.md)),
so the assertion guards against a regression there.

### C4. Session traces and the `read-pi-session-traces` skill

**Upstream.** The trace format is still **version 3**; the header line is
unchanged. Inside, new records appear:

| New carrier | Since | What it is | Skill impact |
| --- | --- | --- | --- |
| `message` with `role: "system"` | 0.86.0 | The prompt and tool loadout, persisted in the transcript: the first one holds every prompt section and tool declaration; later ones patch `sections` by name and list `toolsAdded` / `toolsRemoved` | `KNOWN_ROLES` lacks `system`, so these become opaque metadata |
| `usage` entry | 0.86.0 | Model usage that is not an assistant message, e.g. `kind: "cache_warm"` from cache warming. "Usage entries contribute to session token and cost totals" | **Cost is undercounted** if ignored |
| `context_edit` entry | 0.87.0 | An append-only edit: `targetId` plus `replacement` (`null` = omit from future context). Raw history is unchanged | Unknown type; `show` cannot annotate that a message was hidden from the model |
| `nestedCalls` on tool results | 0.99.0 | Bounded record (name, args, status, duration, error; never results) of a codemode script's inner calls | Tool statistics miss inner calls |
| `thinkingLevel` on assistant messages | 0.99.0+ | Thinking level requested for that response | Nice to show |
| `custom` `codemode-store`, `pi.bug-report` | 0.99.0, 0.86.0 | Codemode's key-value store, `/bug` report ids | Already handled as generic `custom` |

Also new: the session file is now created when the first user message is
sent ([#10000](https://github.com/earendil-works/pi/issues/10000)), so a
launch-and-quit leaves no file. That does not conflict with
[`docs/traces.md`](docs/traces.md) or `mount-state.sh`, which creates the
directory, not the file.

**Why it matters here.** The skill pins itself to 0.84.4 by name
(`SKILL.md:15`, `references/schema.md:1-4`, `scripts/pi_trace_commands.py:1`
and `:689`). Its allowlists live in `scripts/pi_trace_projection.py:9-21`.
Unknown types and roles degrade gracefully into metadata, so it will not
crash. But the `inspect` cost totals will be wrong, and wrong without any
warning.

**D4: update the skill in the same change (recommended).** Add `system` to
`KNOWN_ROLES` (render section names and tool deltas, never full section
text). Add `usage` and `context_edit` to `KNOWN_TYPES`. Add a fourth cost
source, `auxiliary`, attributed `provider/model`, to the usage table in
`references/schema.md:105-111`. Surface `nestedCalls` counts. Re-pin the
text to 1.3.0. Extend `tests/pi_trace_test.py` with one fixture per new
carrier. Doing it later means every trace recorded meanwhile is read with
the wrong totals.

### C5. Settings and defaults

`kits/sbxpi/files/home/.pi/agent/settings.json` and `models.json` were
validated against the 1.3.0 published schemas (`settings.schema.json`,
`models.schema.json`): **0 errors**. The schemas allow unknown keys, so every
key the kit uses was also checked by hand against the
[1.3.0 settings reference](https://github.com/earendil-works/pi/blob/v1.3.0/packages/coding-agent/docs/settings.md).
All still exist with the same meaning:

- `defaultProvider`, `defaultModel`, `defaultThinkingLevel`
- `defaultProjectTrust` (agent-directory only)
- `enableInstallTelemetry`, `extensions`
- `retry.enabled`, `retry.maxRetries`, `retry.provider.maxRetries`,
  `retry.provider.timeoutMs`
- environment variables `PI_TELEMETRY` and `PI_SKIP_VERSION_CHECK`

New and changed defaults that apply to `sbxpi` without any edit:

**D5: fullscreen TUI (1.0.0).** `tuiMode` now defaults to `"fullscreen"`: the
terminal's alternate screen, Pi's own scrollback and mouse selection, and
copy-on-select via OSC 52 when no display exists (restored in 0.86.1,
[#9688](https://github.com/earendil-works/pi/issues/9688)). Inside
`sbx run`/attach this *should* work. It is the same as any SSH session, and
Pi's own docs recommend Docker Sandboxes. But the terminal's native
scrollback no longer holds the conversation, and detach/re-attach redraw has
not been tried. **Recommendation:** keep the upstream default; check it
during the live test; pin `"tuiMode": "regular"` only if it misbehaves.
`fullscreenExitOutput: "transcript"` (default) prints the transcript on exit,
so nothing is lost when Pi quits.

**D6: prompt-cache warming (0.86.0).** `cacheWarming` defaults to
`"streaming"`: refresh caches during long tool runs. It applies only to
models that declare a cache lifetime, and only when the estimated saving is
at least $0.05. Spend is recorded as `usage` entries (see C4). Over OpenRouter
the pinned open-weight models may not declare lifetimes at all, in which case
this is a no-op. **Recommendation:** keep it. Setting `"off"` buys
predictability at the price of more cache misses, and the skill update in D4
makes the spend visible either way.

**D7: `$schema` (1.2.0).** Upstream publishes
`https://pi.dev/schemas/settings.schema.json` and `…/models.schema.json`.
Adding `"$schema": …` as the first key gives editors completion and
validation, with no runtime effect. **Recommendation:** add both. A
`make lint` step that validates against the schemas is possible. It would
need vendored schema copies, because CI should not fetch from pi.dev, and the
schemas are permissive enough to catch only type errors. Optional, low value.

**`/share` destination (1.3.0, no decision needed).** `/share` is a *user*
slash command, not a model tool. Its new `sessionShareDestination` setting
defaults to `"auto"`: Radius if signed in, otherwise a private GitHub gist.
The gist path first runs `gh auth status` and stops with "GitHub CLI is not
logged in" if that fails, then runs `gh gist create --public=false`
([`session-share.ts:79-81,182`](https://github.com/earendil-works/pi/blob/v1.3.0/packages/coding-agent/src/modes/interactive/session-share.ts)).

In `sbxpi` the gist hosts are allowlisted, but no GitHub credential is
declared: the only `credentials:` entry is `openrouter`, and nothing sets
`GH_TOKEN` or `GITHUB_TOKEN`. Allowlisting alone injects nothing. So
`/share` will normally report that the GitHub CLI is not logged in. Radius
fails too: it is not signed in, and not allowlisted. That was equally true
in 0.84.4; 1.3.0 only made the destination configurable.

**No action needed for the upgrade.** If `/share` is *meant* to work, it
needs the same GitHub credential path as D1-B. It would also need a test
(`gh auth status` succeeds inside the sandbox) and a note in
`docs/agents.md` that shared transcripts can contain secrets. A related
point, outside this upgrade: the kit's instructions tell Pi to "use `git`
and `gh` via bash for GitHub operations" (`kits/sbxpi/spec.yaml:87-89`), and
the same missing credential limits what `gh` can do there. Worth one live
`gh auth status` check during the upgrade test.

**`/bug` (0.86.0, no decision needed).** Uploads redacted diagnostics to
Radius. Its gateway is not on the allowlist, so uploads fail closed; the
"export zip" path still works. Crash records go to `~/.pi/agent/crashes.json`.

### C6. Models and providers

No change to `models.json` is required. Changes to know about:

- **Per-key OpenRouter model list (1.2.0,
  [#10353](https://github.com/earendil-works/pi/issues/10353)).** With a key,
  Pi asks OpenRouter's `/models/user` which models *this key* may use, with
  their context sizes and prices, and caches the list for offline use. In
  `sbxpi` the key is a proxy-managed sentinel and the proxy injects the real
  one for `openrouter.ai`, so this should just work. **Verify live.** If the
  key has OpenRouter-side provider restrictions, the model picker now
  reflects them.
- **The pinned models are still live.** OpenRouter's public API on
  2026-10-19: `qwen/qwen3-coder`, `qwen/qwen3-coder-next`,
  `moonshotai/kimi-k2.6`, `z-ai/glm-5.2` and `deepseek/deepseek-v4-pro` all
  exist. The four that `models.json` pins with `only: ["deepinfra"]` (all
  except `qwen3-coder-next`) each have a DeepInfra endpoint, so those pins
  still resolve. `qwen/qwen3-coder-next` is served only by Parasail. That is
  consistent with `models.json`, which *ignores* DeepInfra for that model
  instead of pinning it, so the ignore rule stays as it is. (Several *other*
  Pi providers dropped Kimi K2.6 in 0.99.0; OpenRouter did not.) Endpoint
  availability is live external state, not a property of Pi 1.3.0, which is
  why the live OpenRouter check in §5 stays.
- **Clean model switching (1.3.0,
  [#10995](https://github.com/earendil-works/pi/issues/10995)).** Switching
  models mid-session drops the previous model's hidden reasoning instead of
  replaying it as visible text. This directly benefits the kit's
  multi-model setup, e.g. moving from Qwen to Kimi.
- **Constrained sampling for built-in tools (0.86.0).** Pi asks providers to
  constrain tool-call JSON to the schema ("strict" mode) where supported.
  0.87.0 stopped sending strict schemas to unknown OpenAI-compatible
  endpoints unless they advertise support
  ([#9816](https://github.com/earendil-works/pi/issues/9816)), which covers
  the Ollama provider. **Verify live:** one tool call on each pinned model
  and on one Ollama model.
- **More retries.** More transient errors are now retried: "upstream provider
  returned an error" (1.2.0), "Unable to forward upstream stream" and "service
  is temporarily unavailable" (1.3.0). Useful behind OpenRouter. New setting
  `retry.maxAgentDelayMs` (default 60 s); the kit does not need it.
- **`--model` ambiguity (1.3.0,
  [#10160](https://github.com/earendil-works/pi/issues/10160)).** No effect:
  the kit sets `defaultProvider`.
- **`pi -p` exits 1 on truncated output (1.2.0).** Nothing in the repo runs
  `pi -p`, but a user scripting `sbx exec … pi -p` will see the new exit code.

### C7. Security and project trust

- The trust model is the same as in 0.84.4. One new **protected resource**:
  `.pi/mcp.json`. A trusted project can now add MCP servers, and a stdio
  server is an arbitrary command. That is the same risk class as a project
  extension, which trust already gated. Also new: a project `+builtin:<name>`
  overrides the user's `-builtin:<name>`. **Action:** one sentence in
  [`docs/agents.md`](docs/agents.md)'s Pi paragraph (lines 29-36).
- Pi's 1.3.0 docs gained
  [`security.md`](https://github.com/earendil-works/pi/blob/v1.3.0/packages/coding-agent/docs/security.md)
  and
  [`containerization.md`](https://github.com/earendil-works/pi/blob/v1.3.0/packages/coding-agent/docs/containerization.md).
  Both name running the *whole* Pi process in Docker Sandboxes, with
  credentials substituted by the proxy, as "usually the strongest practical
  option". That is exactly `sbxpi`'s design, which is worth a line in the
  README as external validation.
- Files holding truncated tool output and codemode images are now
  owner-readable only (1.0.3). Fine in a single-user sandbox.

**D8: base `sbxpi` on Docker's own Pi kit?** `containerization.md` points to
`sbx run --kit docker.io/sbx/pi-kit:latest pi`
([docker/sbx-kits-contrib `pi/`](https://github.com/docker/sbx-kits-contrib/tree/main/pi)).
Its spec uses `image: docker.io/sbx/pi-image:latest`, rebuilt nightly with
"rolling updates, no deliberate version bump". It only wires up Anthropic
credentials and installs none of this repo's toolchain. Adopting it would
reverse the repo's pin-everything rule, and `extends:` still accepts only
`claude, codex, copilot, cursor, gemini, kiro, opencode`. **Recommendation:
no.** Keep building on `shell-docker`. The README's "`sbx` ships no Pi agent"
(line 163) stays true for `extends:`, but you may want to say "no built-in Pi
agent" to avoid confusion with the contrib kit.

### C8. Network allowlist

No new host is needed for the recommended path.

- The pi.dev model catalogue and the D3-C installer artifacts use `pi.dev`,
  already listed.
- OpenRouter's `/models/user` uses `openrouter.ai:443`, already listed.
- Codemode's QuickJS runs locally, from WebAssembly bundled in the
  `quickjs-wasi` dependency.
- `radius.pi.dev` (`/bug`, `/share` to Radius, Radius login) stays
  unlisted on purpose.
- D1-B's `github-mcp-server` talks to `api.github.com`, already listed.

Confirm during the live test with `sbx policy log` on the host.

### C9. Context7 Pi package

`@upstash/context7-pi` `0.1.3` (2026-10-13) only updates example text in
tool descriptions to Next.js 16. **D9: bump** `CONTEXT7_PI_VERSION` at
[`kits/sbxpi/spec.yaml:566`](kits/sbxpi/spec.yaml), with
`EXPECTED_CONTEXT7_PI_VERSION` (`tests/toolchain_test.sh:24`) and
`docs/toolchain.md:86`.

### C10. Upstream breaking changes checked and found irrelevant

| Upstream change | Version | Why it does not affect sbxagent |
| --- | --- | --- |
| Custom providers receive `TranscriptContext` | 0.86.0 | No custom provider; `models.json` uses built-in `openrouter` and `openai-completions` |
| `ToolCall.arguments` / `details` must be JSON | 0.86.0 | The guard returns only text content |
| `user_bash` handlers fail closed | 0.86.0 | The guard does not hook `user_bash`: user `!` commands are not agent actions |
| `shouldStopAfterTurn` removed → `finishTurn` | 0.87.0 | Agent-core option, not used |
| `ContextEditEntry`, `TurnEndEvent` fields, `AgentBeforeSettleEvent` | 0.87.0 | Only matters for exhaustive TypeScript switches; the guard has none. The trace skill is covered in C4 |
| `context` handlers no longer see system messages | 0.87.0 | Not used |
| Azure provider renamed `azure` | 1.0.3 | Not used |
| `before_agent_start` union on `messageType`; session busy while starting | 1.2.0 | Not used; `agent_start` semantics fine (C2) |
| Theme schema moved | 1.2.0 | No custom theme |
| `pi mcp list --json` reports `resources: true` | 1.2.0 | Not used |
| `kimi-coding` base URL needs `/v1` | 1.3.0 | Kimi is reached through OpenRouter |
| `--no-extensions` also disables built-ins | 0.99.0 | Not used by the wrapper |

---

## 3. New features worth considering

None of these are needed for the upgrade. They are ordered by value to
sbxagent.

**O1. Codemode for multi-step work.** `pi -t +codemode`, or
`"defaultTools": ["+codemode"]`, lets the model batch tool calls in one script.
Upstream measured about 40% fewer prompt tokens for the codemode description
in 1.0.0 and recommends it for MCP-heavy work. *Trade-offs:* it relies on the
model writing correct JavaScript against Pi's `tools.*` API. That is
well-tested with frontier models, less so with the open-weight models this
kit defaults to (`qwen3-coder-next`). It also gives the guard a second path,
covered in C2. **Suggestion:** leave it off by default; document the per-run
flag in the README so users can try it.

**O2. GitHub MCP parity.** D1-B above. Suggested shape:

- prerequisite: a GitHub credential path for `sbxpi`. Declare the `github`
  service and export `GITHUB_TOKEN` from `GH_TOKEN` in an entrypoint wrapper,
  as the siblings' parent kits and wrappers do. Without it the server has no
  token.
- user-level `~/.pi/agent/mcp.json` with `github-mcp-server` over stdio
- `"exposure": "deferred"`, so its large toolset does not bloat requests,
  with a few read tools such as `get_*` and `search_*` promoted to `direct`
  through `toolExposure`
- `"autoEnableCodemode": false`, so MCP does not switch codemode on behind
  the user's back
- guard extended per D2-C
- a toolchain test asserting `pi mcp list` exits 0. That only proves the
  config parses and the server starts and connects. Add a second test that
  makes one authenticated, read-only GitHub request through the server,
  e.g. fetching this repository's metadata, to prove the credential reaches
  it.

**O3 / D10. Per-model compaction for small local models.** Auto-compaction
triggers at `contextTokens > contextWindow − reserveTokens`, with defaults
`reserveTokens = 16384` and `keepRecentTokens = 20000`
([compaction docs](https://github.com/earendil-works/pi/blob/v1.3.0/packages/coding-agent/docs/compaction.md)).
For `ollama/qwen2.5-coder:7b` (`contextWindow: 32768` in `models.json`) that
means compacting once half the window is used. It also means trying to keep
20 000 recent tokens, more than the 16 384 that trigger compaction, so every
compaction keeps nearly everything. 0.86.0 added `compaction.modelOverrides`
keyed by `provider/modelId`:

```json
"compaction": {
  "modelOverrides": {
    "ollama/qwen2.5-coder:7b": { "reserveTokens": 4096, "keepRecentTokens": 8192 }
  }
}
```

Recommended. The numbers want one live session to tune.

**O4. Sampling parameters per thinking level (1.0.2).**
`samplingParamsByThinkingLevel` in `models.json` sets `temperature`/`top_p`
per level on OpenAI-compatible APIs. Useful if you have model-card
recommendations, e.g. Qwen's suggested `temperature 0.7, top_p 0.8`, that
differ from provider defaults. Low priority; needs evidence that defaults
hurt.

**O5. Kimi K3.** `moonshotai/kimi-k3` is on OpenRouter with a DeepInfra
endpoint and a 1M-token context. It could join `models.json` with the same
`only: ["deepinfra"]` pin as K2.6, if you want it in the picker.

**O6. Session environment variables in shell commands.** Commands the agent
runs now see `PI_SESSION_FILE`, `PI_SESSION_ID`, `PI_PROVIDER`, `PI_MODEL` and
`PI_REASONING_LEVEL`. Git hooks or scripts could tag commits with the model
that wrote them, or point the trace skill at the live session. Nothing to
configure.

**O7. Virtual models and classifiers (0.99.0, experimental).** An extension can
route each request to a different physical model, e.g. a cheap model for easy
turns, using a classifier. It would fit the kit's OpenRouter setup, but it is
marked experimental. Watch, don't adopt.

**O8. `quietStartup: "header"` (1.0.0).** A shorter startup banner. Cosmetic.

---

## 4. Implementation checklist (after decisions)

Recommended options assumed: D1-A, D2-A, D3-C into `/opt/pi` with the
integrity backfill, D4 same change, D5 keep, D6 keep, D7 add, D8 no, D9 bump,
D10 add.

- [ ] `kits/sbxpi/spec.yaml`
  - `PI_VERSION=1.3.0` and the new install step (D3-C). That means SHA-256
    digests for `package.json` and `package-lock.json`, plus pinned `sha512`
    values for the seven Pi packages filled into the lockfile, failing on a
    missing entry or a conflicting existing hash. Then
    `npm ci --ignore-scripts` into `/opt/pi`, and the `pi` symlink. Moving
    from user 1000 to root changes the step's `user:`.
  - `CONTEXT7_PI_VERSION=0.1.3`
  - agent instructions line 88: Pi supports MCP; this kit configures no servers
  - comments at lines 119-122 (what pi.dev is contacted for)
- [ ] `kits/sbxpi/files/home/.pi/agent/settings.json`: `$schema` (D7) and
  `compaction.modelOverrides` (D10). `models.json`: `$schema`.
- [ ] `kits/network-block.ts` and the spec heredoc: a comment explaining
  why the guard does not set `structuredContent` (D2-A). `make lint` keeps the
  two in sync.
- [ ] `tests/toolchain_test.sh`
  - `EXPECTED_PI_VERSION` and `EXPECTED_CONTEXT7_PI_VERSION`
  - reword the comments at 94, 580 and 588
  - assert `pi` resolves to `/opt/pi`, that the install is root-owned, and
    that an unprivileged write into it fails. Describe this as hygiene: with
    passwordless `sudo` the agent can still change it.
  - assert every `packages` entry of the installed lockfile
    (`/opt/pi/package-lock.json`) has an `integrity` field
  - assert no nested `@earendil-works/pi-coding-agent` under `~/.pi/agent/npm`
  - assert `$schema` and the compaction override
- [ ] Docs: `README.md:161-163`, `docs/agents.md` (MCP paragraph line 61,
  trust paragraph 29-36), `docs/toolchain.md:54` and `:85-86`.
- [ ] Trace skill (D4): `SKILL.md`, `references/schema.md`,
  `scripts/pi_trace_projection.py`, `scripts/pi_trace_commands.py`,
  `tests/pi_trace_test.py`.
- [ ] `CHANGELOG.md` under `## [Unreleased]`, in the Changed group. The
  upgrade, the install method, and "Pi now supports MCP; `sbxpi` configures no
  servers" are user-facing.
- [ ] `.cspell.json` for any new words (e.g. `codemode`, `QuickJS`).

## 5. Verification plan for the upgrade

Inside a sandbox (agent-side):

- `sbx kit pack kits/sbxpi --output <scratch>.zip`, the offline schema check
  (AGENTS.md)
- `make lint` (heredoc sync, shellcheck, esbuild over the guard, cspell)
- `make test-unit`
- `python3 .claude/skills/read-pi-session-traces/tests/pi_trace_test.py`

On the host (user-side; it needs the host `sbx` CLI):

```bash
make validate
./scripts/sbxpi rm
./scripts/sbxpi create
make test-toolchain AGENT=pi
```

Manual checks in the new sandbox, once:

1. **Guard, direct path:** ask Pi to `curl https://example.org`. Expect the
   remedy in place of the output, then the run ending at the next call.
2. **Guard, codemode path, uncaught.** Start `pi -t +codemode` and ask Pi to
   run exactly this script, not one it writes itself, so the result does not
   depend on the model's own error handling:
   `await tools.bash({ command: "curl -sS https://example.org" }); return "done";`.
   Expect `Script failed … Script error:` followed by the remedy, and the run
   ending at the model's next tool call.
3. **Guard, codemode path, caught.** In a fresh prompt, again verbatim:
   `try { await tools.bash({ command: "curl -sS https://example.org" }); } catch (e) {} return await tools.bash({ command: "echo still-here" });`.
   Expect the second, harmless `bash` call to be *refused* with the remedy as
   its reason. That is the armed `tool_call` handler at work. Together with
   check 2, this covers both halves of C2's argument: the remedy is visible
   when uncaught, and further tool use is refused when caught. It also shows
   the limit C2 names: a script that caught the exception and made no further
   call would have returned quietly.
4. **OpenRouter:** `/model` lists the pinned models (per-key list), and one
   tool call on each succeeds.
5. **Ollama** (if enabled on the host): one tool call on `qwen3-coder:30b`.
6. **TUI:** attach, scroll, select and copy, detach and re-attach (D5).
7. **Network:** `sbx policy log` on the host shows no new blocked hosts at
   startup.
8. **Traces:** run the trace skill's `inspect` on the session just recorded.
   The `system` messages and any `usage` entries appear and are counted.
9. **Install integrity (D3-C):** corrupt one of the seven backfilled
   `integrity` values in a scratch copy of the lockfile and run `npm ci`
   against it. It must fail with `EINTEGRITY`, which proves the backfilled
   hashes are actually enforced.
10. **GitHub CLI:** `gh auth status` inside the sandbox. A failure confirms C5:
    `/share` to a gist will not work, and `gh` has no credential. That is
    expected today, but it should be a known state rather than a surprise.

## 6. Sources

All checked 2026-10-19.

- Pi changelog, 0.85.0 – 1.3.0:
  [`packages/coding-agent/CHANGELOG.md`](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/CHANGELOG.md)
- Pi 1.3.0 docs (`packages/coding-agent/docs/` at tag `v1.3.0`): `settings.md`,
  `mcp.md`, `codemode.md`, `extensions.md`, `session-format.md`,
  `security.md`, `containerization.md`, `configuration.md`,
  `environment-variables.md`, `packages.md`, `providers.md`, `models.md`,
  `compaction.md`, `quickstart.md`; the same files at `v0.84.4` for
  comparison. Also via Context7, library id `/earendil-works/pi/v1.3.0`.
- Pi source at `v1.3.0` vs `v0.84.4`: `src/core/extensions/types.ts`; at
  `v1.3.0`: `src/core/extensions/runner.ts` (`emitToolResult`),
  `src/extensions/codemode/execute.ts` (`toScriptValue`),
  `src/core/tools/bash.ts` (`bashOutputSchema`).
- Published schemas: `packages/coding-agent/schemas/{settings,models}.schema.json`
  at `v1.3.0`; the kit's JSON files validated with Python `jsonschema`.
- Pi source at `v1.3.0`: `src/modes/interactive/session-share.ts` (the
  `/share` gist path and its `gh auth status` precheck).
- npm registry: `npm view @earendil-works/pi-coding-agent@<v> _hasShrinkwrap engines dependencies`,
  and `npm view @earendil-works/<name>@1.3.0 dist.integrity` for the seven Pi
  packages whose lockfile entries lack `integrity`.
- This repo's credential wiring: `kits/sbxpi/spec.yaml` (`credentials:`, only
  `openrouter`) and the sibling entrypoint wrappers in
  `kits/sbxcodex/spec.yaml` and `kits/sbxcursor/spec.yaml`.
- Managed installer: `https://pi.dev/install.sh`,
  `https://pi.dev/api/installer/releases/1.3.0/package.json` and
  `…/package-lock.json`.
- OpenRouter: `https://openrouter.ai/api/v1/models` and
  `…/models/<id>/endpoints`.
- `@upstash/context7-pi` changelog:
  [`upstash/context7` `packages/pi/CHANGELOG.md`](https://github.com/upstash/context7/blob/master/packages/pi/CHANGELOG.md).
- Docker contrib Pi kit:
  [`docker/sbx-kits-contrib` `pi/spec.yaml`](https://github.com/docker/sbx-kits-contrib/blob/main/pi/spec.yaml).
