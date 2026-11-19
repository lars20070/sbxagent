# Plan: optional host Chrome access (`HOST_CHROME_ACCESS`)

## Context

An agent in the sandbox should be able to drive a Chrome on the host (logged-in
job portals etc.) over CDP. `tmp/playwright.md` is the working outline: Chrome
on the host with `--remote-debugging-port=9222` and its own profile -> sbx proxy
rule `localhost:9222` -> `socat` forwarder inside the sandbox on
`127.0.0.1:9222` -> Playwright MCP in CDP mode.

It must be **opt-in, minimal, stable**. Decisions made with the user:

- All four kits (claude, codex, cursor, pi).
- New mixin `mixins/host-chrome`, stacked with a second `--kit` (same pattern as
  `NETWORK_ALLOWLIST` / `mixins/open-network`). The kits stay untouched.
- The wrapper **prints** the host-side `sbx policy allow` command. It never
  changes host policy itself, so `exec` on the create paths stays.
- Sandbox gets the socat forwarder **and** a Playwright MCP entry.
- Chrome profile lives in `$XDG_STATE_HOME/sbxagent/browserprofile`
  (default `~/.local/state/sbxagent/browserprofile`), not `~/chrome-playwright`.

Decisions taken from the two reviews (`review-plan.md`):

- Profile and host port are **shared** by every sandbox granted the rule.
  Accepted for a dedicated job-portal profile, documented as such.
- **Ordering is solved structurally**: the mixin's *startup* hook (runs on every
  start, after all install hooks and workload seeding) registers the MCP entry
  and starts the forwarder. The install hook only installs packages. No
  dependence on install-hook order, and Codex's fresh config write can no
  longer clobber the entry.
- Loopback-only routing is **not assumed** on either OS. macOS is the proven
  case (the outline). Linux hosts are "unverified" until the host check passes;
  docs and changelog say so until then. Chrome stays on `127.0.0.1`.
- An ungranted sandbox with open networking may reach the host port. That is
  the existing meaning of `NETWORK_ALLOWLIST=false`, so v1 adds no restriction,
  only a documented warning (see 4) and a test (see 5).

## Changes

### 1. `.env.example`
Add after `NETWORK_ALLOWLIST`:

```bash
# true also lets the agent drive a Chrome on the host through the Chrome
# DevTools Protocol: installs socat and the Playwright MCP server, starts a
# forwarder to localhost:9222. You start Chrome and add one network rule
# yourself; the wrapper prints both commands on create. Chrome uses its own
# profile in $XDG_STATE_HOME/sbxagent/browserprofile (see XDG_STATE_HOME below).
# The agent gets full control of that browser profile. See docs/host-chrome.md.
# Takes effect when the sandbox is created. Default: false
#HOST_CHROME_ACCESS=false
```

Extend the `XDG_STATE_HOME` comment: it also holds the Chrome profile.

### 2. `scripts/sbxagent`
- Default near line ~70: `HOST_CHROME_ACCESS="${HOST_CHROME_ACCESS:-false}"`.
- In `compute_state_mounts()` (~156-164, before the `mkdir`s): `case true|false`,
  else `die`. For `true`, set `HOST_CHROME_KIT="${REPO}/mixins/host-chrome"` and
  `BROWSER_PROFILE`, built like `STATE_HOME` (~135-141): absolute
  `$XDG_STATE_HOME` gives `${XDG_STATE_HOME}/sbxagent/browserprofile`, else
  `${HOME}/.local/state/sbxagent/browserprofile`. Chrome creates the dir.
- **Keep the profile out of every mount.** The wrapper must not rely on a
  textual `$PWD` check. Add two small helpers:
  - `physical_path P`: reject any `..` component; resolve the nearest existing
    ancestor with `cd -P ... && pwd -P` (as the wrapper already does for the
    workspace, line ~228) and re-append the not-yet-created tail.
  - `path_overlaps A B`: true if either path equals or contains the other, on
    path-component boundaries (not a string prefix).
  `die` if the resolved profile overlaps the resolved source of **every** host
  mount the wrapper builds: the workspace, the trace mount, `PROJECT_MOUNT` and
  `MESSAGEBOARD_DIR`. Portable (no `readlink -f`, no `realpath`).
- Both argv lines (`sbx run` ~283, `sbx create` ~319) gain
  `${HOST_CHROME_KIT:+--kit "${HOST_CHROME_KIT}"} ${HOST_CHROME_KIT:+--kit-arg "host-chrome.agent=${KIT_NAME#sbx}"}`.
  `KIT_NAME` is `sbxclaude|sbxcodex|sbxcursor|sbxpi` (line 227), so
  `${KIT_NAME#sbx}` gives `claude|codex|cursor|pi`, which the mixin enum
  accepts (`WORKLOAD` would be wrong for Pi).
- Before `exec` on the create paths, when the flag is `true`, print to stderr:
  1. the exact `sbx policy allow network --sandbox "${SANDBOX}" localhost:9222`
  2. a Chrome launch line labelled **"bash/zsh syntax"**, every path quoted with
     `printf '%q'`. The wrapper runs on the host, so find the binary by
     **capability probe**, no OS-name branch: first `[ -x ]` on the macOS app
     path `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`, then
     `command -v google-chrome google-chrome-stable chromium chromium-browser`,
     else the placeholder `<path-to-chrome>`. Flags:
     `--remote-debugging-port=9222 --user-data-dir=<profile> --no-first-run
     --no-default-browser-check`.
  Wording: "run these on the host; with `create`, run them before attaching".
- The flag is create-time only: the no-arg attach path calls `sbx run --name`
  and ignores it (docs say so, plus how to switch off, see 4).

### 3. `mixins/host-chrome/host-chrome.yaml` (new, schema v3, `kind: mixin`)
Model on `mixins/open-network/open-network.yaml`, unique file stem.
- `args:`
  - `agent`: enum `claude|codex|cursor|pi`, passed by the wrapper.
  - `hostChromeAccess`: `default: "true"`, `enum: ["true"]`,
    `env: HOST_CHROME_ACCESS` (marker for the tests, like `networkAllowlist`).
- `lifecycle@1` **install** hooks (packages only, so order cannot matter):
  1. `apt-get update && apt-get install -y socat`, using the retrying
     `apt_get` helper from `kits/sbxclaude/sbxclaude.yaml` (~102-129), so the
     package index exists. `deb.debian.org` is already allowed.
  2. As user 1000, install the pinned MCP package into the user prefix, the way
     the kit installs Playwright (`sbxclaude.yaml` ~186-193, `NPM_CONFIG_PREFIX`,
     proxy env): `npm install --global @playwright/mcp@0.0.85`. This avoids a
     cold `npx` download at first agent start (it fetches its own
     `playwright`/`playwright-core` alpha builds, which could exceed an MCP
     client's startup timeout). `registry.npmjs.org` is already allowed. No
     browser download is needed in CDP mode. Hook asserts `jq` and the
     `playwright-mcp` binary exist, so a missing tool fails the create loudly.
- `lifecycle@1` **startup** hook (user 1000, `env: [WORKSPACE_DIR]`, run with
  **bash** explicitly, because `/dev/tcp` is a Bash feature). It always exits 0:
  a stopped Chrome, a missing policy rule or a port conflict must never block
  the agent. Two parts:
  - **Register MCP** server `playwright`:
    `playwright-mcp --cdp-endpoint http://localhost:9222` (the outline's proven
    endpoint; host check proves `localhost` reaches the IPv4 listener in the
    shipped runtime, else switch both sides to `127.0.0.1`). Per
    `${{ kit.args.agent }}`; one consistent rule everywhere: **an existing
    `playwright` entry that is not ours is kept and a warning is printed; ours
    is rewritten only if it differs.** Build the full candidate config in a temp
    file, **validate it before touching the live file** (`jq -e` / `python3
    -c 'import tomllib...'`), then `cat tmp > live` to keep owner and mode:
    - claude: `jq` merge into `~/.claude.json` (the `+` merge, ~221-244).
    - codex: a marked block `# BEGIN sbxagent host-chrome` ...
      `[mcp_servers.playwright]` ... `# END` in `~/.codex/config.toml`;
      the block is stripped and re-added on each start (no duplicate tables);
      an unmarked `[mcp_servers.playwright]` is "not ours".
    - cursor: `jq` merge into `~/.cursor/mcp.json`; then, as the kit does for
      its own servers (`sbxcursor.yaml` ~203-228): `cd "$WORKSPACE_DIR"`,
      `cursor-agent` with the `agent` fallback, `mcp enable playwright`,
      soft-failing.
    - pi: `jq` merge into `~/.pi/agent/mcp.json`, `exposure: deferred`.
  - **Start the forwarder**, with ownership checked, not just a TCP accept:
    - Private runtime dir `$HOME/.cache/sbxagent/host-chrome/` (mode 700, owned
      by the agent user), holding the log and a lock. Not `/tmp`.
    - Serialize with an atomic `mkdir` lock so concurrent starts cannot both
      launch or truncate the log; stale lock is removed after a short timeout.
    - Our listener = a process of this uid whose argv is exactly our socat
      command (`pgrep -u "$(id -u) -f` on the full string). If present, do
      nothing. If port 9222 answers but it is **not** ours, do not kill it and
      do not claim readiness: print "port 9222 is taken by something else; host
      Chrome access unavailable" and exit 0.
    - Otherwise launch, fully detached, so the hook returns at once:
      `nohup setsid socat TCP-LISTEN:9222,bind=127.0.0.1,fork,reuseaddr
      PROXY:gateway.docker.internal:host.docker.internal:9222,proxyport=3128
      >"$dir/socat.log" 2>&1 </dev/null &`. Then a bounded readiness wait
      (about 3 s) for our process to be listening. On timeout print a warning
      with the log path. No `$!` or PID file (the outline records a PID
      mismatch).
- No `network-policy` entry: a kit cannot express `localhost:9222`. Precedent is
  the Ollama rule in `docs/setup.md` ~105-127.
- Agent-context: a short note (browser is the user's; own tab, read only, never
  click apply/send, do not work around network blocks) **only if** a mixin
  `agent-context@2` composes with the kit's. If not, drop it. Docs say clearly
  these are instructions, not enforcement.

### 4. Docs, changelog, security
- New `docs/host-chrome.md`, trimmed from `tmp/playwright.md`: why socat; host
  steps (use the printed commands); troubleshooting; cleanup. Generic wording
  (`macOS`/`Linux`, `$(sbxclaude name)`), not the personal sandbox name. Profile
  path only as "the path the wrapper prints". Sections:
  - **Platform status:** macOS verified; Linux host marked unverified until the
    host check passes.
  - **Enabling:** `HOST_CHROME_ACCESS=true <wrapper> create`, run the two
    printed commands, attach. On the implicit first `run`, run the policy
    command from a second terminal.
  - **Disabling:** flag is create-time only. Order matters: on the host
    `sbx policy rm network --sandbox <name> --resource localhost:9222`, then stop
    Chrome (an already-open WebSocket may survive revocation), then
    `<wrapper> rm`, then create with the flag off. Record the observed rule
    lifetime across remove/recreate under the same name.
  - **What you are granting:** raw CDP, not only the MCP tools. Any process in
    the sandbox controls the whole profile (tabs, cookies, logins). The
    browser's own requests come from the host, so the sandbox network allowlist
    does not limit what pages it opens. "Read only" and "own tab" are
    instructions, not enforcement. Profile and port are shared by every
    sandbox granted the rule. A sandbox with `NETWORK_ALLOWLIST=false` may reach
    the port even without the rule (confirm in the host check). Use a dedicated
    profile, close Chrome when done.
- `SECURITY.md` (~30-34): same consequences, short.
- `docs/setup.md` env table (~54-59), `docs/toolchain.md` (~10-12, ~43, ~136).
- `CHANGELOG.md` `## [Unreleased]` -> `### Added`.
- `tmp/` stays untracked.

### 5. Tests
- `tests/sbxagent_test.sh` (fake `sbx`):
  - `create_argv` (~89-109) gets the mixin kit and agent kit-arg parameters;
    update existing assertions.
  - After the `NETWORK_ALLOWLIST` block (~633-649): exact argv for **each** of
    the four wrappers (`claude|codex|cursor|pi`), for `run` (implicit create)
    and `create`; both mixins stacked (`NETWORK_ALLOWLIST=false` +
    `HOST_CHROME_ACCESS=true`); bogus value rejected; `name` works with a bogus
    value; reattach ignores the flag.
  - Printed policy line is exact. Chrome line uses the XDG path, falls back to
    `$HOME/.local/state` when `XDG_STATE_HOME` is unset or relative, and
    re-parses to the right argv with spaces, `$`, backtick, quote and backslash
    in the path. Browser-binary probe: macOS app path, a fake `google-chrome` on
    PATH, and the placeholder.
  - Path guard: reject a profile in the workspace, inside the trace, project and
    messageboard mount sources, containing `..`, and via a symlink into the
    workspace and into a state mount; allow a sibling directory.
  - `.env` precedence block (~651-690): add `HOST_CHROME_ACCESS=true` and a
    real-env-wins assertion.
- `tests/toolchain_test.sh` + `Makefile` `test-toolchain`: new
  `EXPECTED_HOST_CHROME_ACCESS` with three values, so ordinary runs (unset or
  `false`) need no Chrome:
  - `false`: marker env unset, nothing listening on 9222, no `playwright` entry
    in any agent config, no `playwright-mcp` binary. (Not "socat absent": a
    workload may ship it later.)
  - `true` (setup only, Chrome not needed): marker is `true`, our forwarder is
    listening, config entry present and parses, owner is the agent user, the
    kit's own entries (gateway, context7, github) still present, startup is
    idempotent (run it twice: one listener, one entry, one TOML block), Cursor
    approval asserted, Pi finds it via `tool_search`.
  - `live` (Chrome up, rule added; **fails hard**, never skips, if Chrome, the
    grant, `/json/version`, its `ws://localhost:9222/...` WebSocket or MCP is
    missing): a real MCP operation on a controlled page in each agent; a
    pre-existing harmless cookie and an existing tab are visible before and
    after; ending the MCP session leaves Chrome running.
- Also time a first MCP start from an empty npm cache against the clients'
  startup limits (should be fast, because the package is pre-installed).
- `Makefile` `validate` needs no change: it already loops over
  `kits/*/ mixins/*/`. `publish-dry-run` correctly covers only kits.
- `.cspell.json`: add unknown words (e.g. `socat`) if lint flags them.

## Risks to check on the host (cannot be seen from here)
1. **Loopback routing on each OS**: with Chrome bound to `127.0.0.1` only,
   prove the route before the grant (blocked), after the grant (works), and
   after revoking it with Chrome still up (fresh connections fail; note whether
   an open WebSocket survives). Do this on macOS and on a Linux host.
2. **Ungranted sandbox with open networking**, Chrome running, in two cases:
   feature on and feature **off**. If CDP is reachable, it is documented, not
   blocked, in v1.
3. **Startup hook in a mixin** runs on every start for all four agents; no
   duplicate listeners on repeated or concurrent starts; a foreign listener on
   9222 is reported, not killed; forwarder survives an agent restart; the agent
   stays usable with Chrome stopped, started late, or the rule missing.
4. `agent-context@2` from a mixin composes with the kit's.
5. `localhost` falls back to the IPv4 listener in the shipped Node runtime;
   `playwright-mcp` is the right binary name and is on `PATH`.
6. Policy rule lifetime: can it be added before the sandbox exists, and does it
   survive `rm` + recreate under the same name?
7. Pi and Cursor accept the `playwright` entry and discover its tools.

## Verification
1. `make lint`, `make test-unit` (unset `SBXAGENT_LITE`/`NETWORK_ALLOWLIST`
   first, per memory note), `make validate`.
2. Host check (`AGENTS.md`), for each of claude, codex, cursor, pi:
   ```bash
   ./scripts/sbxclaude rm
   HOST_CHROME_ACCESS=true NETWORK_ALLOWLIST=true SBXAGENT_LITE=true ./scripts/sbxclaude create
   # run the two printed commands, then:
   HOST_CHROME_ACCESS=true NETWORK_ALLOWLIST=true SBXAGENT_LITE=true \
     make test-toolchain AGENT=claude EXPECTED_HOST_CHROME_ACCESS=live
   ```
   Repeat with `SBXAGENT_LITE=false`, and with `HOST_CHROME_ACCESS=false`
   (expect `EXPECTED_HOST_CHROME_ACCESS=false` to pass with no Chrome running).
3. Repo-required open-network check for the wrapper change, Claude:
   ```bash
   ./scripts/sbxclaude rm
   NETWORK_ALLOWLIST=false ./scripts/sbxclaude create
   NETWORK_ALLOWLIST=false make test-toolchain AGENT=claude
   ```
   and once more with `HOST_CHROME_ACCESS=true` stacked on top.
4. Cover risks 1-7 by hand once. Existing installs keep using the ordinary
   toolchain suite, which never needs Chrome.
5. Do not run `git commit`/`git push`. Hand over a drafted commit message.
