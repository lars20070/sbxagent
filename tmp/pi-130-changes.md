# Pi (pi.dev): What Changed from 0.84.4 to 1.3.0, and the Blog Posts That Explain It

Coming from 0.84.4, you will find that the change that matters most happened in the pre-1.0 releases 0.86 to 0.99, not in 1.0 itself.\[1\] Those releases added cache warming, transcript-aware system prompts and tool changes, extension-API breaking changes, and built-in MCP with Codemode in 0.99.0. Pi 1.0.0 (Oct 1, 2026) mostly made fullscreen the default and trimmed Codemode.\[2\] Releases 1.1 to 1.3 are incremental, but 1.0.3, 1.2.0 and 1.3.0 each still contain config- or API-breaking changes. Only the 1.0 milestone has real explanatory blog posts. For 1.1 to 1.3 you have to rely on the official changelog.

**Verified identity:** pi.dev is the "Pi Coding Agent", the terminal agent harness Mario Zechner created and originally developed as badlogic/pi-mono.\[3\] It is now owned and developed by Earendil Inc. at github.com/earendil-works/pi and published on npm as `@earendil-works/pi-coding-agent`.\[3\] The `@mariozechner/*` packages are deprecated.\[4\] The scope moved at 0.74.0, well before 0.84.4, so you are probably already on the `@earendil-works` name.\[4\]\[5\]\[6\]

## TL;DR

- **Biggest shift:** Pi went from "No MCP" to built-in MCP plus Codemode (a QuickJS JavaScript sandbox that calls tools) in 0.99.0 (Sep 29). It also gained a system terminal-palette theme, virtual models, classifier and image models, and prompt-cache warming (0.86.0). Since 1.0.0 the TUI runs fullscreen by default.
- **Blog coverage:** Earendil wrote two official posts for 1.0, "Pi 1.0" and "Pi Durable", plus "You Said No MCP!" for 0.99, and there is good third-party coverage (The Register, heise, Developers Digest and others). I found no dedicated official or substantive third-party blog posts for 1.1.0, 1.2.0 or 1.3.0. The pi.dev changelog is the authoritative source for those.
- **Upgrade risk:** expect breakage in custom extensions (`shouldStopAfterTurn`→`finishTurn`, `turn_end`/`ExtensionEvent` shapes, the `before_agent_start` union, `user_bash` failing closed), in custom providers (`TranscriptContext`), and in config: the Azure provider was renamed to `azure`, theme `$schema` and validation changed, Kimi base URLs need `/v1`, and `tuiMode` must be set if you want scrollback back. Install via the pi.dev installer, or move straight to 1.3.0, which pins internal dependencies exactly.

## (a) Blog posts and write-ups, per release

### Official (Earendil / pi.dev)

| Release | Title | Author / publisher | Date | URL | What it covers |
|---|---|---|---|---|---|
| 0.99.0 (precursor) | "You Said No MCP!" | Earendil Engineering | Sep 29, 2026 | https://earendil.com/posts/you-said-no-mcp/ | Why MCP moved into core, how Codemode works (a JS sandbox running harness-side, with state kept in the session transcript), tool exposure modes, and a Linear MCP + Jev classifier demo.\[7\] |
| 1.0.0 | "Pi 1.0" | Earendil | Oct 1, 2026 | https://earendil.com/posts/pi-1-0/ | The launch post. Lists the 1.0 additions: Codemode (native MCP plus non-LLM models such as Jev and image models), virtual models, deferred tool loading, Anthropic cache warming, mid-conversation system messages, a new TUI theme, and fullscreen by default. Also gives install commands.\[8\]\[9\] |
| 1.0.0 | "Pi Durable" | Earendil Engineering (written by Mario Zechner: the "Pi 1.0" post says "Mario writes in more detail about how we crafted Pi Durable here", linking to this post) | Oct 1, 2026 | https://earendil.com/posts/pi-durable/ | A separate experimental package (`@earendil-works/pi-durable`) for long-running, crash-surviving agents on memory, SQLite or JSONL storage. Explicitly not a replacement for the coding agent. |
| All | Release notes 0.85.0 → 1.3.0 | pi.dev | Sep 4 – Oct 15, 2026 | https://pi.dev/changelog (per-release pages, e.g. https://pi.dev/changelog/releases/1.3.0) | The authoritative per-release New Features, Breaking Changes, Added, Changed, Fixed and Removed lists. Mirrored as GitHub releases at https://github.com/earendil-works/pi/releases |
| Context | "Pi Has a New Home at Earendil" | pi.dev | May 7, 2026 | https://pi.dev/changelog/2026/5/7/pi-has-a-new-home | The package and repo rename (`@mariozechner/*` → `@earendil-works/*`, starting at 0.74.0).\[4\] |

### Third-party

| Release | Title | Author | Date | URL | Notes |
|---|---|---|---|---|---|
| 0.99 | "Pi reverses course, ships MCP support with a Codemode sandbox" | aiagentslisting.com | ~Sep 29–30, 2026 | https://aiagentslisting.com/news/pi-reverses-course-ships-mcp-support-with-a-codemode-sandbox | A news summary of 0.99.0's MCP, Codemode and tool search.\[10\] |
| 0.99 | "Pi Coding Agent Adds MCP: How Codemode Cuts Token Waste" | byteiota | ~Sep 30, 2026 | https://byteiota.com/pi-coding-agent-adds-mcp-how-codemode-cuts-token-waste/ | An analysis piece. Some of its claims (e.g. a "72% context window tax") are the outlet's own framing.\[11\] |
| 1.0 | "Pi coding agent pulls a 180 and adds MCP support" | The Register | Oct 2, 2026 | https://www.theregister.com/ai-and-ml/2026/10/02/pi-coding-agent-pulls-a-180-and-adds-mcp-support/5300678 | Press coverage of the MCP reversal and the 1.0 feature list.\[8\]\[12\] |
| 1.0 | "Pi 1.0 Release Guide: MCP, Codemode and Pi Durable" | Developers Digest | Oct 2, 2026 | https://www.developersdigest.tech/blog/pi-1-0-release-guide-mcp-codemode-pi-durable | **The best upgrade-oriented post.** Its "Where it breaks" checklist covers `tuiMode`, `typeof tools.name`, `--provider` without `--model`, and MCP credential re-keying. It also summarises the Hacker News discussion.\[8\] |
| 1.0 | "Coding Agent Pi: More space in the prompt, less ballast" | heise online | Oct 3, 2026 | https://www.heise.de/en/news/Coding-Agent-Pi-More-space-in-the-prompt-less-ballast-11474748.html | Covers the leaner Codemode (≈5,300→3,300 tokens), image generation and fullscreen.\[13\] |
| 1.0 | "Pi 1.0: A.I. Agent From Austria's Developer Scene Tops Hacker News" | Trending Topics | ~Oct 2, 2026 | https://www.trendingtopics.eu/pi-1-0-earendil-en/ | Launch news and context.\[14\] |
| 1.0 | "What is the Pi coding agent, and how does it work with local models?" | Invide Labs | Oct 2, 2026 | https://blog.invidelabs.com/pi-coding-agent-local-models/ | Gives a timeline of 0.86 → 0.99 → 1.0 and covers local models and Pi Durable.\[1\] |
| 1.0 | "Pi 1.0 Won't Ask Before It Runs a Command…" | Halil Özel (Medium) | early Oct 2026 | https://halilozel1903.medium.com/pi-1-0-wont-ask-before-it-runs-a-command-i-tested-20-risky-tool-calls-against-its-example-guards-64c25e82ed03 | Security angle: no approval prompts, and tests of the example `tool_call` guards.\[15\] |
| 1.0 | "The One Who Said No to MCP Shipped It into Core" | yage.ai | Oct 4, 2026 | https://yage.ai/share/mcp-demotion-survival-en-20261004.html | Opinion piece on the MCP reversal and Pi Durable.\[16\] |
| 1.0 | "Pi coding agent explained: how it works and what Pi 1.0 changed" | eesel.ai | edited Oct 7, 2026 | https://www.eesel.ai/blog/pi-coding-agent | An explainer that covers MCP exposure modes.\[17\] |
| 1.0 / general | "A deep dive into Pi" | Flavio Copes | Oct 2026 | https://flaviocopes.com/pi/ | A usage guide that includes the `@mariozechner` → `@earendil-works` migration commands.\[18\] |
| 1.1 | "Pi 1.1: MCP Ships After a Year of 'Never' — Upgrade Now" | byteiota | ~Oct 7–8, 2026 | https://byteiota.com/pi-1-1-mcp-codemode-upgrade/ | **The only 1.1-specific post found.** It is thin: it mostly restates the changelog (`+name/-name` tools, Haiku 5.5, OSC 7501) and mixes in 1.0 material.\[19\] |
| 1.2 (indirect) | "Pi Coding Agent: Setup, Local Models, MCP and How It Compares (2026)" | Suha Selcuk, VDF.AI | Oct 14, 2026 | https://vdf.ai/blog/pi-coding-agent-local-llm/ | Not a release write-up. It is a setup guide "checked … against Pi 1.2.0, released on 12 October" and shows the new `$schema` URLs.\[3\] |
| 1.3 (news items) | piagent.fyi headlines | Unattributed, unofficial | Oct 15–17, 2026 | https://piagent.fyi/ | Short news items on 1.3.0 and follow-up PRs. It describes itself as "not affiliated with Earendil" and has no named authors, so treat it as low reliability.\[20\] |

**Discussions:** Hacker News "Pi 1.0" (https://news.ycombinator.com/item?id=49926069). Reported point and comment counts vary by snapshot (~937–1,618 points), so I have not stated a single figure.\[16\]\[21\]\[22\] There is also an r/LocalLLaMA thread titled "Pi 1.0 released, MCP support now included by default".\[8\]

**Gaps:** I found no Earendil blog post for 1.1.0, 1.2.0 or 1.3.0. Earendil's posts index stops at the two Oct 1 posts.\[23\] I did not find posts on mariozechner.at about these releases either. Zechner's most recent relevant posts are the original Nov 2025 Pi post and the Apr 2026 "I've sold out" post announcing the move to Earendil.\[5\]\[24\]

## (b) Release-by-release summary, 0.84.4 → 1.3.0

The changelog lists no releases between 0.87.1 (Sep 22) and 0.99.0 (Sep 29); the version number jumped straight from 0.87 to 0.99.\[25\]

### 0.85.0 (Sep 4) / 0.85.1 (Sep 5)
- Anthropic thinking effort now persists across turns, with recovery from signed-thinking mismatches.
- Fullscreen transcript gains a "Jump to latest message" control, and the working indicator moved into the editor border.
- SDK: `SessionManager.inMemory()` can restore externally stored session entries.
- Models: GPT-6 Astra; vLLM `vllmPriority` and `supportsMaxOutputTokens`; Meta (Muse) login.
- Alt + mouse wheel scrolls 5× faster in fullscreen.\[25\]

### 0.86.0 (Sep 19) / 0.86.1 (Sep 20): cache warming and transcript-aware prompts
- **Prompt-cache warming.** Configured with the `cacheWarming` setting: `off`, `streaming` (the default) or `idle`. Includes the `cache_warming_decision` extension event and `/session` diagnostics.\[25\]\[26\]\[27\] Third-party extension authors report it interacting with stall watchdogs, so check retry or timeout extensions.\[28\]
- **Transcript-backed mid-conversation system prompt and tool changes**, which survive resume and branching without breaking the prompt cache.
- **`/bug`** produces redacted bug reports (uploaded to Radius or exported as a zip). Crashes are logged to `~/.pi/agent/crashes.json`.\[29\]
- Other additions: per-model compaction budgets (`compaction.modelOverrides`), the offline Radius model catalog, `ctx.modelRegistry.stream()`/`streamSimple()`, `pi.on()` returning an unsubscribe function, and strict JSON-schema sampling on by default for built-in tools.\[25\]\[26\]
- **Breaking:**
  - pi-ai custom providers now receive `TranscriptContext` and must read the system prompt and tools via `getCurrentSystemPrompt()`/`getCurrentTools()`.
  - `ToolCall.arguments` and `ToolResultMessage.details` must be JSON-compatible.
  - `user_bash` handlers now fail closed.
- Removed GPT-5.4 and GPT-5.4 mini from OpenAI Codex.
- 0.86.1 adds Meta Muse login and the Node compile cache.\[25\]

### 0.87.0 (Sep 21) / 0.87.1 (Sep 22): extension boundaries
- Adds `ContextEditEntry` (append-only context edits), actionable `turn_end` and `agent_before_settle` hooks, the `context_with_system` event, and per-model image resize limits (`inputLimits.images.resize`).\[25\]\[26\]
- **Breaking:**
  - `shouldStopAfterTurn` is removed; use `finishTurn` returning `{ action: "end" }`.\[26\]
  - `SessionEntry` gains `context_edit`.
  - `SessionManager` is now canonical, so assigning `session.agent.state.messages` no longer changes future context.\[30\]
  - `TurnEndEvent` and the `ExtensionEvent` union changed, and `ExtensionRunner.emit()` no longer accepts `turn_end`.\[31\]
  - Runs requested from `agent_settled` handlers are deferred.
- 0.87.1 adds Claude Opus 5.5, GPT-6 Sol and GPT-6 Luna, and makes Grok 4.7 the default xAI model.\[25\]

### 0.99.0 (Sep 29) / 0.99.1 (Sep 29) / 0.99.2 (Sep 30): MCP and Codemode
- **Built-in MCP, Codemode and tool search** are shipped as built-in extensions.\[32\]
  - Servers can be stdio or streamable HTTP and support OAuth.\[32\]
  - They are configured in `mcp.json` (global, or per project once trusted) or via `pi.registerMcpServer()`.\[32\]
  - Manage them with `/mcp` and `pi mcp add|remove|list|login|logout`.\[32\]
  - Codemode is enabled with `defaultTools`/`--tools`; `"defaultTools": ["+codemode"]` adds it without repeating the defaults.\[32\]
- **System theme** becomes the default; it derives colours from the terminal palette. Themes gain `oklch()`/`okhsl()`, and the built-in dark and light themes were revised.\[33\]
- **Sign in with ChatGPT** on the OpenAI provider. The old Codex provider is now labelled "OpenAI Codex (legacy)".\[34\]
- **Virtual models** (experimental, via `pi.registerVirtualModel()`), plus **classifier models** (Jev, llama.cpp) and image generation in `ModelRuntime`.\[33\]
- New extension tool APIs: `exposure` (`direct`, `model-only`, `codemode`, `deferred`, `hidden`), `namespace`, `outputSchema`, `ctx.executeTool()` and `prepareLoadout()`.\[25\]\[33\]
- **Behaviour changes:**
  - `--no-extensions` now also disables built-ins (re-enable one with `-e builtin:mcp`).\[26\]
  - Built-ins are named `builtin:<name>` and can be disabled with `-builtin:<name>` in `extensions`.\[32\]
  - The `[Themes]` section was removed from the startup banner.
  - bash and powershell structured results now return up to 1 MiB.
  - The build moved to TypeScript 7.0 and Node type-stripping.
- 0.99.1 adds GPT-6.1 Sol, which becomes the default Codex model.\[25\]\[35\]
- 0.99.2 changes:
  - MCP servers with `codemode` exposure no longer block the first prompt and are listed in an `mcp_servers` system-prompt section; `codemode-deferred` is now an alias.
  - New MCP options: `oauth.clientName` and `"auth": {"provider": …}`.
  - Anthropic workload identity federation.
  - `/reload` now picks up new `defaultTools`.\[25\]

### 1.0.0 (Oct 1): the milestone
- **Fullscreen TUI by default.** Use `tuiMode: "regular"` or `--tui-mode regular` to keep native scrollback.\[8\]
- **Leaner Codemode:** about 40% fewer prompt tokens. The pi.dev 1.0.0 changelog states: "with the default tools and codemode active, a GPT-5.6 request shrinks from about 5,300 to 3,300 tokens." Errors now include recovery hints.\[26\]
- Image generation in Codemode via `models.generateImages()` and `ctx.modelRegistry.generateImages()`.
- Radius sign-in is available in `/login`, and Anthropic gains a copy-code login for headless machines.
- MCP OAuth hardening: `oauth.authServerMetadataUrl`, RFC 9207 `iss` checks, credentials stored per server name and URL, and step-up sign-in that keeps granted scopes.\[8\]
- New option `quietStartup: "header"`.
- **Breaking-ish changes:**
  - Codemode scripts must use `"name" in tools` instead of `typeof tools.name`.\[8\]
  - `--provider` without `--model` now errors.\[8\]
  - MCP credentials stored by URL alone move to the first server that uses them.\[2\]\[8\]
- **What 1.0 signals:** Earendil's "Pi 1.0" post calls it "a hardened, minimal, extensible agent harness that you can make your own" and says the team has "used that feedback to improve, harden and evolve Pi into a stable piece of software that people and businesses can depend on." I found **no formal semver or stability policy** (see Caveats).

### 1.0.1 – 1.0.4 (Oct 3–5)
- **1.0.1:**
  - A Nix flake: `nix run github:earendil-works/pi/stable`.
  - Project-level overrides of user MCP servers in `.pi/mcp.json`, and `oauth.clientRegistration: "cimd"`.
  - `pi.registerToolRenderer()` and Cloudflare Clef classifiers.
  - **`npm-shrinkwrap.json` removed from the npm package.** npm installs no longer pin transitive dependencies, and `pi update` recommends switching to the pi.dev installer.
- **1.0.2:** adds `samplingParamsByThinkingLevel` in `models.json`.\[25\]
- **1.0.3:**
  - **Breaking:** the Azure provider `azure-openai-responses` is renamed to `azure`. Rename it in `auth.json`, `models.json` and `settings.json` (`defaultProvider`, `enabledModels`, `modelThinkingLevels`). The `AZURE_OPENAI_*` environment variables are unchanged.
  - Azure Foundry Chat Completions support.
  - `Home`/`End` now act on the editor line, and transcript top/bottom moved to `Ctrl+Home`/`Ctrl+End`.
  - Codemode images are saved to temp files.\[25\]
- **1.0.4:**
  - `--tools` and `--exclude-tools` accept `*` patterns, e.g. `'mcp__radius__*'`.\[36\]
  - `--tools` now keeps MCP tools unless an entry starts with `mcp__`.\[36\]
  - New `--no-mcp` flag.\[36\]
  - Codemode `tools.read()` returns image blocks.\[25\]\[36\]

### 1.1.0 (Oct 7)
- Program status reporting via OSC 7501; override with `PI_PROGRAM_STATUS`.\[37\]
- `--tools +name/-name` (e.g. `pi -t +codemode,-write`).
- Claude Haiku 5.5.
- GPT-6 Luna as a classifier through the Decisions API, and `models.classify()` accepts images.
- Native llama.cpp decision models (Julia-1, Laya, Kev, lev, OpenJev).
- Extension and API additions: `durationMs`/`outputPad` in the tool render context, and `aborted` on `agent_settled`.
- `pi mcp login --timeout` now covers the whole sign-in.\[25\]

### 1.2.0 (Oct 12)
- **New:**
  - Published JSON schemas for `settings.json`, `models.json`, keybindings and themes at `https://pi.dev/schemas/*.schema.json`. \[38\]
  - Per-key OpenRouter model lists.\[38\]
  - `PI_CLIPBOARD_OSC52=1`.\[38\]
  - Codemode shows input constraints and timing.\[38\]
  - Tools get `reachesTools`, and namespaces get `aliases`.\[25\]\[38\]
- **Breaking:**
  - The theme schema moved to `https://pi.dev/schemas/theme.schema.json`, and themes are validated at startup. Fix `$schema`, put reusable colours under `vars`, and drop unsupported metadata.\[38\]
  - `before_agent_start` now also fires for `pi.sendMessage(..., { triggerTurn: true })`. `BeforeAgentStartEvent` is a union on `messageType`, so check `event.messageType === "user"`.\[38\]
  - The session counts as busy while a run starts, and `pi.sendUserMessage()` requires `deliverAs`.\[38\]
  - `pi mcp list --json` reports `resources: true` instead of counts.\[25\]\[38\]
- **pi-tui:** `Editor`/`Input.render()` emit APC cursor markers (per the 1.2.0 package changelog quoted in downstream PRs).\[39\]
- **Removed:** the unreleased experimental server, client and plugin stack (the `pi-client`, `pi-protocol` and `pi-server` packages are no longer released) and the `@earendil-works/chord` dependency.\[25\]\[38\]
- `showHardwareCursor` now uses only the terminal cursor.\[37\]\[38\]
- **Fix:** print mode (`-p`) now exits 1 with a warning when output is truncated at the token limit.\[38\] This matters for scripts.

### 1.3.0 (Oct 15): current
- `sessionShareDestination` (`auto`, `gist` or `radius`) controls where `/share` uploads.
- The GPT-6 prompt cache is kept when the thinking level changes.
- **`kimi-coding` now uses Chat Completions** at `https://api.kimi.com/coding/v1`, which the 1.3.0 changelog (#10720) describes as "the protocol used by the official Kimi Code client. K3, K3-256K, and Kimi For Coding now accept tools added mid-conversation without invalidating the prompt cache." `models.json` base-URL overrides must include `/v1`.
- Thinking blocks from a previous model are dropped on model switch.\[25\]
- Resumed sessions keep their active tools.\[25\]
- NVIDIA's default model changed to Nemotron 3.5 Super VL.
- **Internal Pi dependencies are now pinned to exact versions.** The 1.3.0 changelog reads: "Pinned internal Pi dependencies to exact release versions to prevent fresh installs from mixing incompatible packages (#10865)."
- `--model` prefers the provider that has credentials.
- A fix for the Nix package putting its own Node first on PATH.
- Provider fixes listed in the 1.3.0 changelog:
  - OpenCode Go Gemini 404s, fixed by moving to the `opencode.ai/inference` endpoints.
  - OpenCode Go MiniMax M2.7, which now uses Anthropic Messages.
  - Gemini 4 Argon "Thinking budget is not supported" errors on Vertex (#10890).
  - Xiaomi MiMo 400 errors at `minimal` thinking (#10818).
  - `off` thinking support for Claude Haiku 5.5 and Opus 5 (#10753).
  - Anthropic and Bedrock 400 errors on error tool results that contain images (#10794).
  - `openai-codex/gpt-6.1-sol` context raised from 272K to 500K (#10840).

## (c) Upgrading from 0.84.4: migration checklist

1. **Install method.** Prefer `curl -fsSL https://pi.dev/install.sh | sh` (Windows: `irm https://pi.dev/install.ps1 | iex`). The installer pins all dependencies, and `pi update` handles upgrades.\[40\] If you use npm, use `npm install -g --ignore-scripts @earendil-works/pi-coding-agent@1.3.0`.\[41\] **Do not install 1.0.x or 1.1.0 fresh via npm:** their caret ranges pull in `pi-codemode@1.2.0`, which removed an export they import. That fails at startup (issues #10865 and gh-aw #68172).\[42\] The fix is to upgrade to ≥1.2.0 or override codemode to 1.1.0.\[43\] Requires Node ≥ 22.19.\[41\] If you are somehow still on `@mariozechner/pi-coding-agent`, uninstall it first; `~/.pi/agent` is kept.\[18\]
2. **Terminal behaviour.** Fullscreen is now the default. Set `"tuiMode": "regular"` if you want native scrollback.\[8\] The default theme is now `system`, so pick `dark` or `light` in `/settings` if colours look wrong. Retrain `Home`/`End` versus `Ctrl+Home`/`Ctrl+End`.\[25\]
3. **MCP.** If you used `pi-mcp-adapter` or another MCP extension, note that an extension registering `/mcp` replaces the built-in support. Choose one. To turn the built-in off, use `"extensions": ["-builtin:mcp"]` or `--no-mcp`. To use Codemode without MCP, set `"defaultTools": ["+codemode"]`.\[25\]\[44\]
4. **Config files:**
   - Rename `azure-openai-responses` → `azure` everywhere.
   - Add `/v1` to any `kimi-coding` `baseUrl` override.\[25\]
   - Update theme `$schema` to `https://pi.dev/schemas/theme.schema.json` and validate your custom themes.\[38\]
   - Optionally add `$schema` to `settings.json` and `models.json`.\[25\]
   - Review `cacheWarming` (default `streaming`) if cost or latency matters.\[45\]
5. **CLI and scripts:**
   - `--provider` now requires `--model`.\[8\]
   - `--no-extensions` also disables built-ins.\[26\]
   - `--tools` semantics changed: patterns, `+/-` entries, and MCP tools are kept.\[25\]\[46\]
   - `pi -p` exits 1 on truncation.\[38\]
   - `pi mcp list --json` output shape changed.\[25\]\[38\]
6. **Extensions and SDK (most work is here):**
   - `shouldStopAfterTurn` → `finishTurn`.\[26\]
   - Handle the new `TurnEndEvent`/`AgentBeforeSettleEvent`/`context_edit` shapes.\[47\]
   - Don't mutate `session.agent.state.messages`; use `SessionManager`/`refreshContext()`.
   - `user_bash` must return `undefined` to propagate.
   - Custom providers must read from `TranscriptContext`.
   - Gate `before_agent_start` logic on `messageType`.\[38\]
   - Pass `deliverAs` to `pi.sendUserMessage()` during run start.\[25\]\[38\]
   - Strip APC cursor markers if you render pi-tui `Editor`/`Input` outside a TUI.\[39\]
7. **Pin all `@earendil-works/*` packages together** at the same exact version in SDK projects. Treat the whole set as one unit.\[42\]

## Caveats

- **Versioning policy is undocumented.** I found no written semver commitment. Minor releases (1.2.0) and even a patch release (1.0.3) carried breaking changes.\[42\] The only official statement is a maintainer comment on #10865, which the comment itself flags as AI-generated: "Internal Pi dependencies are now pinned to exact versions, with release tooling and checks enforcing this for future releases."\[43\] When a downstream reporter asked whether a removed export violated semver (#10869), the issue was closed as a duplicate without addressing the question.\[48\] Read "1.0" as a maturity statement, not an API-stability guarantee.
- 1.3.x patch releases after Oct 15 may exist or be in progress (piagent.fyi mentions follow-up PRs).\[20\] This report stops at 1.3.0.
- Third-party posts vary in quality. Several (byteiota, tech-insider, explainx) are SEO-style rewrites. Vendor claims, such as the "Pi 1.0" post's statement that "Hundreds of thousands of people around the world use Pi every week", and benchmark comparisons come from Earendil and have not been independently verified.
- Some details, such as the pi-tui APC markers and the pi-codemode export removal, come from package-level changelogs quoted in downstream GitHub issues and PRs rather than from pi.dev pages I read directly.\[39\]\[42\]\[43\]\[48\]

## Sources

1. [Pi coding agent 1.0 with local models and Pi Durable](https://blog.invidelabs.com/pi-coding-agent-local-models/)
2. [Pi Coding Agent](https://pi.dev/changelog/releases/1.0.0)
3. [Pi Coding Agent: Setup, Local Models and Comparison (2026)](https://vdf.ai/blog/pi-coding-agent-local-llm/)
4. [Pi Has a New Home at Earendil · Changelog · Pi](https://pi.dev/changelog/2026/5/7/pi-has-a-new-home)
5. [pi joins Earendil: Mario Zechner moves the project to a company home — Pi Map](https://www.pi-map.org/news/pi-joins-earendil/)
6. [Pi (AI agent)](<https://en.wikipedia.org/wiki/Pi_(AI_agent)>)
7. [“You Said No MCP!” | Earendil](https://earendil.com/posts/you-said-no-mcp/)
8. [Pi 1.0 Release Guide: MCP, Codemode and Pi Durable](https://www.developersdigest.tech/blog/pi-1-0-release-guide-mcp-codemode-pi-durable)
9. [Pi 1.0 | Earendil](https://earendil.com/posts/pi-1-0/)
10. [Pi reverses course, ships MCP support with a Codemode sandbox](https://aiagentslisting.com/news/pi-reverses-course-ships-mcp-support-with-a-codemode-sandbox)
11. [Pi Coding Agent Adds MCP: How Codemode Cuts Token Waste](https://byteiota.com/pi-coding-agent-adds-mcp-how-codemode-cuts-token-waste/)
12. [Pi coding agent pulls a 180 and adds MCP support](https://www.theregister.com/ai-and-ml/2026/10/02/pi-coding-agent-pulls-a-180-and-adds-mcp-support/5300678)
13. [Coding Agent Pi: More space in the prompt, less ballast](https://www.heise.de/en/news/Coding-Agent-Pi-More-space-in-the-prompt-less-ballast-11474748.html)
14. [Pi 1.0: A.I. Agent From Austria's Developer Scene Tops Hacker News](https://www.trendingtopics.eu/pi-1-0-earendil-en/)
15. [Pi 1.0 Won’t Ask Before It Runs a Command. I Tested 20 Risky Tool Calls Against Its Example Guards](https://halilozel1903.medium.com/pi-1-0-wont-ask-before-it-runs-a-command-i-tested-20-risky-tool-calls-against-its-example-guards-64c25e82ed03)
16. [The One Who Said No to MCP Shipped It into Core: Protocols Survive by Demotion](https://yage.ai/share/mcp-demotion-survival-en-20261004.html)
17. [Pi coding agent explained: how it works and what Pi 1.0 changed](https://www.eesel.ai/blog/pi-coding-agent)
18. [A deep dive into Pi - Flavio Copes](https://flaviocopes.com/pi/)
19. [Pi 1.1: MCP Ships After a Year of “Never” — Upgrade Now](https://byteiota.com/pi-1-1-mcp-codemode-upgrade/)
20. [Piagent — The resource map & news hub for the Pi coding agent](https://piagent.fyi/)
21. [Hacker News Daily Top 30 @2026-10-02 · Issue #1481 · meixger/hackernews-daily · GitHub](https://github.com/meixger/hackernews-daily/issues/1481)
22. [Daily Hacker News 02-10-2026 · Issue #815 · Foxhunt/daily-hackernews · GitHub](https://github.com/Foxhunt/daily-hackernews/issues/815)
23. [Posts](https://earendil.com/posts/)
24. [What I learned building an opinionated and minimal coding agent](https://mariozechner.at/posts/2025-11-30-pi-coding-agent/)
25. [Pi Coding Agent](https://pi.dev/changelog)
26. [Pi Coding Agent](https://pi.dev/news/releases)
27. [Port upstream pi's cache-warming strategy: user-facing modes, per-model cache lifetimes, cost-aware scheduling · Issue #12691 · can1357/oh-my-pi · GitHub](https://github.com/can1357/oh-my-pi/issues/12691)
28. [stall watchdog aborts long tool runs on pi \>= 0.86 when cache warming pings arm it without a disarming assistant turn · Issue #1370 · narumiruna/pi-extensions · GitHub](https://github.com/narumiruna/pi-extensions/issues/1370)
29. [Release v0.86.0 · earendil-works/pi · GitHub](https://github.com/earendil-works/pi/releases/tag/v0.86.0)
30. [Release v0.87.0 · earendil-works/pi · GitHub](https://github.com/earendil-works/pi/releases/tag/v0.87.0)
31. [chore(deps-dev): bump @earendil-works/pi-coding-agent from 0.85.1 to 0.87.0 in /extensions/sol-pi by dependabot\[bot\] · Pull Request #621 · tibrezus/harmostes · GitHub](https://github.com/tibrezus/harmostes/pull/621)
32. [Release: Pi 0.99.0 · Changelog · Pi](https://pi.dev/changelog/releases/0.99.0)
33. [Pi Changelog on X: "Pi v0.99.0 is out! Highlights: - Codemode runs model-written JavaScript in a QuickJS sandbox that calls pi's tools in parallel; MCP servers are now built-in via mcp.json or pi.registerMcpServer(). - System theme is now the default, deriving pi's colors from the terminal's own p… / X](https://x.com/PiChangelog/status/2104986274730029265)
34. [Upgrade Pi dependencies to 0.99.1 · Issue #499 · ladislas/mypac · GitHub](https://github.com/ladislas/mypac/issues/499)
35. [feat(pi): upgrade to 0.99.1 and choose MCP client · Issue #11 · peloyeje/dotfiles · GitHub](https://github.com/peloyeje/dotfiles/issues/11)
36. [Release: Pi 1.0.4 · Changelog · Pi](https://pi.dev/changelog/releases/1.0.4)
37. [Releases · earendil-works/pi · GitHub](https://github.com/earendil-works/pi/releases)
38. [Pi Coding Agent](https://pi.dev/changelog/releases/1.2.0)
39. [chore(deps-dev): update pi-agent ( 1.1.0 ➜ 1.2.0 ) by renovate\[bot\] · Pull Request #159 · antoine-bouteiller/pi-extensions · GitHub](https://github.com/antoine-bouteiller/pi-extensions/pull/159)
40. [GitHub - earendil-works/pi: AI agent toolkit: unified LLM API, agent loop, TUI, coding agent CLI · GitHub](https://github.com/earendil-works/pi)
41. [earendil-works/pi-coding-agent](https://www.npmjs.com/package/@earendil-works/pi-coding-agent)
42. [Pi engine fails at startup: pi-coding-agent@1.1.0 resolves pi-codemode@1.2.0, which removed MCP\_TYPESCRIPT\_PREAMBLE · Issue #68172 · github/gh-aw](https://github.com/github/gh-aw/issues/68172)
43. [fix: keep Pi 1.0.x/1.1.x compatible with Pi Codemode 1.2 · Issue #10865 · earendil-works/pi](https://github.com/earendil-works/pi/issues/10865)
44. [MCP Servers · Documentation · Pi](https://pi.dev/docs/latest/mcp)
45. [Cache-warm requests are invisible to run usage and uncontrollable per run · Issue #314 · arasovic/pi-worker · GitHub](https://github.com/arasovic/pi-worker/issues/314)
46. [Command Line · Documentation · Pi](https://pi.dev/docs/latest/cli)
47. [chore(deps-dev): bump @earendil-works/pi-ai from 0.84.2 to 0.87.1 by dependabot\[bot\] · Pull Request #69 · ribbons-digital/pi-warm-cache · GitHub](https://github.com/ribbons-digital/pi-warm-cache/pull/69)
48. [\`@earendil-works/pi-codemode\` 1.2.0 introduced a breaking change · Issue #10869 · earendil-works/pi](https://github.com/earendil-works/pi/issues/10869)
