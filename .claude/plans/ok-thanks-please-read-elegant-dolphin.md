# Upgrade sbx v0.50.0 → v0.54.0 (move all kits to schema v3 mixins)

## Context

CI `validate` fails on every PR (e.g. #24). It always installs the newest sbx,
which is now v0.54.0, and that version rejects our kits:

```
extends: "claude" is no longer a built-in agent; run the published kit instead: sbx run claude --kit <your mixin>
```

The cause is in v0.51.0 (v0.52.0 was skipped): built-in agents became
published **schema v3** kits (`docker.io/sbx/<agent>:latest`, Docker Hardened
Images, Debian 13). `extends:` is gone, and v1/v2 kits cannot be combined with
v3 kits. The release workflow is still pinned to v0.50.0, so releases work for
now, but nothing on `main` can pass CI.

**Decisions (user):**

- Move to v3. All four kits become v3 **mixins** on Docker's published
  workloads, and the open-network mixin moves to v3 too.
- Traces reach the host through a **direct workspace mount** onto the agent's
  trace path. The `mount-state.sh` startup hook goes away.
- The Pi workload **floats** like the other three (no digest pin).
- Every descriptor gets a **unique file name** (`sbxclaude.yaml`,
  `open-network.yaml`, …). The frontend writes each kit's descriptor to
  `/usr/share/sandbox/kit/<stem>/kit.yaml`, so two stacked kits that are both
  named `spec.yaml` collide. That includes a user's own `spec.yaml` mixin
  stacked on our published kit.
- Pilot **Claude and Pi first**. Port Codex and Cursor only after the host
  experiment passes.

| Our kit | Runs as | Workload provides |
|---|---|---|
| sbxclaude | `sbx run claude --kit kits/sbxclaude` | `claude@…` |
| sbxcodex | `sbx run codex --kit kits/sbxcodex` | `codex@…` |
| sbxcursor | `sbx run cursor --kit kits/sbxcursor` | `cursor@…` |
| sbxpi | `sbx run docker.io/sbx/pi --kit kits/sbxpi` | `pi@…` (replaces the digest-pinned `sbx/pi-image`) |

Checked in this session with the SHA-256-checked v0.54.0 binary
(`/tmp/claude-1000/-Users-lars-Code-sbxagent/c28a9eca-be73-4386-9ced-a0e02715cd78/scratchpad/sbx054/docker-sbx/sbx`)
and the published workload descriptors:

- `kit validate --offline`: sbxclaude, sbxcodex and sbxcursor fail (above).
  sbxpi and open-network (v2, no `extends`) still pass.
- `extends: docker.io/sbx/claude:latest` (OCI ref) is also refused.
- A v3 source kit **cannot be validated offline**:
  `is a v3 source kit and this load path has no kit builder configured`.
  v3 source kits are built by BuildKit (`# syntax=docker/sandbox-kit:3`),
  either by sbx's `sbx-kit-builder` sandbox (needs the daemon) or by
  `docker buildx build`. **This ends the daemon-free `make validate` design.**
- `sbx kit inspect` takes **one** reference. `--resolved` merges only an
  `extends` parent, so it cannot show a workload + mixin composition.
- The new workloads ship **no Node/npm** (except `pi`). None of them declares
  a `github` credential; the old built-in parents gave us `GH_TOKEN`.
- Workloads already ship jq, ripgrep, tree, git, gh, uv, Python 3.14, Docker.
- Entrypoints: claude `claude --dangerously-skip-permissions`,
  cursor `cursor-agent --yolo`, pi `pi`.
- The Pi workload's install hook **writes a fresh `~/.pi/agent/settings.json`**
  (project trust, model, thinking level) and registers the MCP gateway. The
  Cursor workload pre-trusts the workspace under `~/.cursor/projects/<slug>`.
  The Claude workload overwrites `~/.claude.json` at install.
- The Pi workload also requests an optional `anthropic` credential and allows
  Anthropic endpoints. That changes sbxpi's effective policy.

v3 references (sbx v0.54.0 bundles kit-spec `v3.0.0-m.12`):
`docker/sandbox-kit-spec` → `docs/spec/SPEC-v3.md` and
`docs/spec/capabilities/com.docker.sandbox/*.md`; Docker docs
"Build a tool mixin".

## Release-note items and what each means for this repo

| Release | Change | Action here |
|---|---|---|
| 0.51 | Built-in agents → published v3 kits; `extends` dead; v2 can't mix with v3 | The whole migration below |
| 0.51 | Old sandboxes must be recreated before `kit add` / `run --model` / `move`. Reattach keeps the recorded setup | Rebuilding is how users adopt the new mixins. Handoff notes in step 7 |
| 0.51 | v3 kits load with a descriptor named `spec.yaml` | Not used: unique stems avoid composition collisions (step 1) |
| 0.51 | Additional workspaces accept `PATH:TARGET[:ro]` | Basis for the new trace mount (step 3) |
| 0.51 | `docker/sandbox-templates` codex/cursor/shell images retired | Drop the shell-docker template wording in `docs/toolchain.md` and the sbxpi comments |
| 0.51 | Failed startup commands now only warn; `sbx run` continues | The trace mount no longer depends on a startup hook (step 3). Other startup hooks are convenience only |
| 0.51 | Kit install logs in `/var/log/sbx-kits/<kit>/install-<n>.log` | Mention in `docs/setup.md` troubleshooting |
| 0.51 | Custom secrets without destination hosts no longer substitute | None: we use only `sbx secret set` services |
| 0.53 | Hooks given as argv lists are passed literally | Our `[sh, -c, …]` hooks are fine |
| 0.53 | `sbx run <agent> -- <args>` keeps entrypoint args | None: the wrapper passes no agent args |
| 0.53 | `exec --detach/--privileged` removed | None: wrapper uses `exec -it`/`-i` only |
| 0.53 | `sbx logout` needs `--yes`; `DOCKER_SANDBOXES_USE_DHI` gone; Gemini retired; HTTP policy case-insensitive; clipboard opt-in | None |
| 0.53 | Validation warns on unsupported static-file paths | Re-check output after the rewrite |
| 0.54 | `sbx ports` deprecated → `sbx port …` | None in this repo |
| 0.54 | Clone-mode git remote via daemon socket | None: the wrapper does not use `--clone` |
| 0.54 | Kit permissions may need re-approval | CHANGELOG note |
| 0.54 | Validation checks inherited config | Covered by step 0 |

Upstream issues referenced in the repo (#388, #231) were closed before
v0.50.0. #231 is a design note, so it stays. `tests/lifecycle_test.sh`'s #388
probe goes away with the startup bind (step 3). No other workaround to remove.

## Step 0 — Host experiment (user runs, before porting all four)

Port **sbxclaude and sbxpi** first (steps 1–5), then the user runs, in a
**disposable project** with its own wrapper-generated name and state dir:

1. Inspect the workload and the mixin **one at a time**
   (`sbx kit inspect docker.io/sbx/claude`, `sbx kit inspect ./kits/sbxclaude`).
   Then create a named sandbox with both and read `sbx inspect NAME --json`.
   Check effective files, mounts, credentials and network inside it.
2. `--kit-arg`: CLI help gives `kit.name=value`. Find which kit name matches
   a **local** reference. Prove it by the value seen inside (`$SBXAGENT_LITE`)
   and the tools actually installed, for both `lite=true` and `lite=false`.
   (The registry form is checked in the release rehearsal, where the probe
   package first exists.)
3. Our install hooks run **after** the workload's (`requires: [claude]` /
   `[pi]`). Claude: first launch sees context7, github **and** the workload's
   `mcp-gateway`. Pi: our settings survive (trust `ask`, OpenRouter, the
   network-block extension), the merged `mcp.json` keeps both the workload's
   `mcp-gateway` and our `github`, and Context7 works through Pi (it is a Pi
   package).
4. `agent-context@2` with `delivery: inline` appears in the agent's profile.
5. `--pull always` refreshes the workload; `-e` works alongside `--kit`.
6. Trace mount (step 3), proven **from the host**:
   - a marker written at the agent's native path appears in the expected
     host dir; a host-side write is readable after stop + `exec`;
   - a marker that existed on the host **before** create is still there
     (old traces survive the upgrade);
   - shared mode: sibling traces are read-only; private mode
     (`CROSS_SANDBOX_VISIBILITY=false`): siblings and the message board are
     absent;
   - remove the host source **after create and stop**, then start again
     (a fresh create always recreates it), and record what sbx does.
   These go into `tests/lifecycle_test.sh`, run explicitly on the host.
7. The Pi guard: a blocked request through the loaded extension returns a
   verdict (the extension shells out to the jq filter).
8. Builds: cold `docker buildx build` **inside a default sandbox with the
   allowlist on** (Docker engine answering, not just the CLI), and on an
   ubuntu runner.

Already settled by the review: sbx v0.54.0 **cannot** validate a built kit
offline (it rejects the OCI tar and looks for a source `spec.yaml`). Docker's
`kit-tck` **3.0.0-m.12** can: `kit-tck validate --layout <dir> <tag>` on an
extracted Buildx OCI layout, no daemon. CI uses that (step 6).

How to run it: use a **disposable checkout of this repo** (it has both
`./scripts` and `./tests`), so the wrapper derives a fresh sandbox name and
`make test-toolchain` finds its script. For the "ordinary project" MCP check,
call the wrapper by absolute path from that project. Set `NETWORK_ALLOWLIST`
and `SBXAGENT_LITE` explicitly on every command, so a real export or the
repo `.env` cannot change the case.

If any check fails, stop and decide with the user before continuing.

## Step 1 — New kit layout (pattern; same for all four)

Per kit, replace `spec.yaml` with a v3 **companion pair** named after the
directory (SPEC-v3 §3.1): `kits/<kit>/<kit>.yaml` + `kits/<kit>/<kit>.dockerfile`.
The directory name stays the single source of identity (command, sandbox
prefix, descriptor stem, published package).

```
kits/sbxclaude/
├── sbxclaude.yaml        # # syntax=docker/sandbox-kit:3@sha256:8561468d…, schemaVersion "3", kind: mixin
├── sbxclaude.dockerfile  # build stages → FROM scratch, COPY --from=… /out/ /
└── files/                # COPY'd by the recipe, into a mixin-owned staging path
```

Everything that finds a kit by `spec.yaml` switches to `<dir>/<dir>.yaml`:
`publish-kit.sh` (lines 92, 126, 137–140), the release probe lookup
(`release.yml:127`), Makefile lint loops (lines 52, 76, 93, 116), and the
network-block guard's `self_reference` regex, which becomes
`sbx(claude|codex|cursor|pi)\.(yaml|dockerfile)|open-network\.yaml` (keep
`spec\.yaml` too, so reading old docs or history does not trip it). Update the
guard tests in `tests/toolchain_test.sh` that use `spec.yaml` as their sample
filename.

Pin the frontend by digest on the `# syntax=` line:
`docker/sandbox-kit:3@sha256:8561468d43a0466e24dd048e3c6c2115d878ee36d71c4571195f1de2a63c2b5b`
(m.12, the spec version bundled in sbx v0.54.0; the floating `:3` tag already
moved to m.13). It produces the published bytes, independent of the pinned
sbx CLI. Record it in `docs/toolchain.md` with the other pins.

Mapping from v2 to v3:

| v2 field | v3 home |
|---|---|
| `name`, `extends` | gone. `requires: ["claude"]` (codex/cursor/pi likewise) refuses the wrong workload and orders our hooks after it |
| `version:` | keep (fallback version). Lint and `publish-kit.sh` read it |
| `args.lite` | `args.lite` with `enum` and `env: SBXAGENT_LITE` |
| pi `PI_TELEMETRY`, `PI_SKIP_VERSION_CHECK` | args with a fixed default and `env:` |
| `sandbox.entrypoint` wrapper | **deleted**: a mixin cannot change the entrypoint. See step 2 |
| `sandbox.image` (pi) | deleted. The `sbx/pi` workload provides it |
| `agentInstructions` | `com.docker.sandbox/agent-context@2`, `delivery: inline` |
| `permissions.network.allow` | `network-policy@1`: `runtime.allow` as today, plus an explicit **`install.allow`** (below) |
| `credentials` | `credential@1` entries, `phase: runtime`, **`optional: true`** (step 2) |
| `setup.install` | `lifecycle@1.install` |
| `setup.startup` | Claude's `~/.claude.json` MCP merge moves to an **install** hook ordered after the workload's seed (first launch depends on it; keep a startup copy only if the step-0 check shows the workload rewrites the file later). Cursor MCP approval stays a startup hook. The trace bind is **removed** (step 3) |
| `files/home/…` | recipe copies to a staging dir (`/usr/local/share/sbxagent/home/`). An install hook merges or copies into `$HOME` **after** the workload's own seeds |
| `files/workspace/.editorconfig` | `lifecycle@1.files` at `${{ kit.env.WORKSPACE_DIR }}/.editorconfig`, `overwrite: false` |

**Recipe (build time, `FROM scratch` output only):** self-contained files.
The sbx v0.54.0 binary and `github-mcp-server` v1.12.2 (download + SHA-256
check in a `debian:trixie-slim` stage, keyed on `TARGETARCH`). Guard files:
Claude's jq filter + `/etc/claude-code/managed-settings.json`, Codex's jq
filter + `/etc/codex/requirements.toml`, Pi's `network-block.ts` **and** the
jq filter it calls (`/usr/local/lib/sbxagent/network-block.jq`; without it the
extension silently gives no verdict). The staged home tree. No `apt` in the recipe: overlaying a build-time
`/var/lib/dpkg/status` onto a newer floating workload would corrupt dpkg.

**Install hooks (create time, as today):** apt (pandoc, shellcheck,
build-essential, python3-dev, python3-yaml), **`nodejs-24` and `npm`** from
the DHI repo (separate packages; Pi already has them), `uv tool` and `npm -g`
installs, and the lite-gated XeTeX, Playwright and mermaid-cli steps gated on
`"$SBXAGENT_LITE"`. Each hook lists every variable it reads in `env:`
(deny-by-default): `SBXAGENT_LITE`, `HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY`
(and lowercase forms), `NPM_CONFIG_PREFIX` for agent-owned global installs.
Keep the existing retry/timeout wrappers.

**`install.allow`** lists every host the install hooks reach, by tool,
since workload `runtime` grants do not cover the install phase:
apt (`deb.debian.org:80`, `dhi.io:80` and any https variant), npm
(`registry.npmjs.org:443`), uv/pip (`pypi.org:443`,
`files.pythonhosted.org:443`), Playwright (`cdn.playwright.dev:443`,
`playwright.download.prss.microsoft.com:443`), plus any Debian mirror apt
redirects to. Confirm the list in the step-0 full-install run.

**Pi specifics:** the staging merge must run after the workload's settings
seed, keep `defaultProjectTrust: "ask"`, OpenRouter, and the network-block
extension, then install the Context7 Pi package that edits settings. Merge
`mcp.json` (don't overwrite): keep the workload's `mcp-gateway` and add our
`github`.

**Cursor specifics:** the MCP-approval startup hook calls the binary the
workload actually ships (entrypoint is `cursor-agent`; check whether `agent`
exists) and declares `env: [WORKSPACE_DIR]`. Check approvals survive reattach.

sbx pin bump in each recipe's sbx stage: `v0.54.0`, amd64
`eded29017121a857c98d4a91cad593f6a9e00f4010e830679bd385f4a5edba4d`, arm64
`40498341fd6b7f67d8f6ff4b1a17c73f516811fc6184a3bd554f9b3442a91115`
(GitHub release API digests; arm64 matched locally).

## Step 2 — GitHub and other credentials without the entrypoint wrapper

The wrappers only existed to export `GITHUB_TOKEN`/`GITHUB_PERSONAL_ACCESS_TOKEN`
from `GH_TOKEN`. Each mixin now declares its own `credential@1`:
`service: github`, `phase: runtime`, **`optional: true`**, `proxyManaged: true`,
and **both** inject rules from today's sbxpi block: `api.github.com` Bearer, and
`github.com` Basic (`username: x-access-token`) for private git over HTTPS.
One entry per (service, phase), so one variable name per kit:

| Kit | `apiKey.name` | Why |
|---|---|---|
| sbxclaude | `GITHUB_TOKEN` | `~/.claude.json` expands `${GITHUB_TOKEN}`; `gh` reads it |
| sbxcursor | `GITHUB_TOKEN` | `~/.cursor/mcp.json` expands `${env:GITHUB_TOKEN}` |
| sbxpi | `GITHUB_TOKEN` | Pi's `mcp.json` already maps it to the server's variable; no launcher |
| sbxcodex | `GITHUB_PERSONAL_ACCESS_TOKEN` | Codex forwards env by name, and both the user config and this repo's trusted `.codex/config.toml` forward that name to `github-mcp-server` |

For sbxcodex, check `gh` still authenticates (it does not read that name). If
it does not, decide with the user.

sbxpi's `openrouter` credential also becomes `optional: true` (Pi works with
local Ollama and no key). Record in CHANGELOG/docs that the Pi workload now
adds an optional Anthropic credential and Anthropic endpoints.

Side effect: tokens are now present in `sbx exec` sessions too. Remove the
"does not inherit it" caveats (`docs/agents.md:115`, kit comments) and the
manual export in `tests/toolchain_test.sh:786`.

## Step 3 — Traces via a direct workspace mount

Replace the startup bind with a wrapper-managed mount, so no failed hook can
leave traces unbound. In `scripts/sbxagent`, per agent:

| Agent | Host source | Target |
|---|---|---|
| claude | `${AGENT_DIR}/projects` | `/home/agent/.claude/projects` |
| codex | `${AGENT_DIR}/sessions` | `/home/agent/.codex/sessions` |
| cursor | `${AGENT_DIR}/projects` | `/home/agent/.cursor/projects` |
| pi | `${AGENT_DIR}/sessions` | `/home/agent/.pi/agent/sessions` |

- Pass it as `"${AGENT_DIR}/<sub>:<target>"`. Create the host dir first.
  Keep the existing `PROJECT_MOUNT` (`:ro`) and messageboard mounts, so
  sibling visibility and private mode behave as today.
- Drop the `-e SBXAGENT_STATE_DIR` pass-through if nothing else reads it.
- Delete `mount-state.sh` from all four kits and everything that only exists
  for it: `tests/mount_state_test.sh`, its Makefile invocation (line 153),
  its entry in the shared-file lint list (Makefile line 56), and the
  `SBXAGENT_REQUIRE_BIND` flag in `ci.yml` (lines 84–91). Rewrite
  `tests/lifecycle_test.sh` around the host-side checks in step 0.6 (the
  #388 startup-bind probe goes).
- `tests/toolchain_test.sh` lines ~199–203 require `SBXAGENT_STATE_DIR` and
  compare two guest paths by inode. In private mode there may be only one
  guest path, so that check would fail a working mount. Replace it with a
  marker write at the native path; the host side is proven by the lifecycle
  test.
- Plain `sbx run claude --kit ghcr.io/…` users get no host traces, as today.
- Risks for step 0: the Cursor workload's pre-trust writes into
  `~/.cursor/projects/<slug>`, which now lands on the host; the target
  sits under paths the workload `chown`s; nesting with the `:ro` project
  mount. Check seeded files, Cursor trust, and writes from both sides.
- Rewrite `docs/traces.md` for the new mechanism.

## Step 4 — `mixins/open-network` → v3

`mixins/open-network/open-network.yaml` (replaces `spec.yaml`): v3
`kind: mixin`, declaration-only. The wrapper's `NETWORK_KIT` and
`make validate` point at the new file.
`network-policy@1` with `runtime.allow: ["**"]` and `install.allow: ["**"]`.
Arg `network_allowlist` (default/enum `"false"`, `env: NETWORK_ALLOWLIST`).

## Step 5 — Wrapper `scripts/sbxagent`

- Per-command workload: sbxclaude→`claude`, sbxcodex→`codex`,
  sbxcursor→`cursor`, sbxpi→`docker.io/sbx/pi` (a `case` on `SELF`).
- `run`/`create` (lines ~256, ~292): positional becomes the workload, our kit
  becomes `--kit "${KIT}"`, open-network a second `--kit`, plus the trace
  mount from step 3. `--kit-arg` uses the form found in step 0.
- Remove the pre-run `sbx kit validate --offline` (line ~251): `sbx run`
  builds the source kit anyway. `sbx<agent> kit validate` calls the same
  buildx helper as `make validate`.
- Bash 3.2 rules apply (AGENTS.md "Portability").

## Step 6 — Build, CI, release, lint

- **`make validate`:** `docker buildx build -f <dir>/<name>.yaml <dir>` for
  each `kits/*/` and `mixins/*/`, exported as an OCI layout, then
  `kit-tck validate --layout <layout> <tag>` on each. Needs Docker + network.
  Pin `kit-tck` to **3.0.0-m.12** (matches the frontend and sbx v0.54.0),
  SHA-256 checked like the other binaries. Neither check sees composition
  conflicts, so also assert in lint that no two kits share a descriptor stem.
- **CI:** lint and unit tests stay on ubuntu **and** macOS. `validate` runs
  on ubuntu only (buildx + QEMU + kit-tck; macOS runners have no Docker).
  The newest-sbx install goes from CI: sbx v0.54.0 cannot check a built v3
  kit offline. Say so in `docs/toolchain.md`: workload + mixin behavior is a
  host check (step 0 / AGENTS.md), since CI creates no live sandbox.
- **`release.yml`:** `SBX_VERSION` v0.54.0, `SBX_SHA256` `eded2901…`
  (generic linux tarball = amd64). Add buildx + QEMU + kit-tck. Probe lookup
  (line 127) checks `kits/${PROBE_KIT}/${PROBE_KIT}.yaml`.
- **`scripts/publish-kit.sh`:** stage from `git archive HEAD` as now. Replace
  `sbx kit validate/inspect --offline` + `sbx kit push` with a kit-tck check
  and `docker buildx build --platform linux/amd64,linux/arm64 -f "${staged}/${kit}.yaml" "${staged}" --push -t "${version_ref}"`
  (staged dir as context, staged descriptor as `-f`, provenance attestation
  on). The staged dir has no `.git`, so pass the commit explicitly (a
  build arg / `org.opencontainers.image.revision` annotation from
  `git rev-parse HEAD`) and check provenance names that commit. The oras
  exist-probe, `latest` retag, and `sbx kit sign` + `sbx kit verify` stay.
- **`make lint`:** drop the `name:` check (v3 has no name). Update the
  jq-filter and Pi TypeScript sync checks for the new file locations. Add a
  check that each kit's guard files are shipped by its recipe (Pi: both the
  `.ts` and the `.jq`). Version agreement reads `version:` from
  `kits/*/<dir>.yaml`. yamllint covers the descriptors.
- Per-agent guard behavior stays as documented: Claude managed settings,
  Codex `/etc/codex/requirements.toml` hook, Pi settings extension, Cursor
  instructions only.

## Step 7 — Docs, tests, metadata, handoff

- `tests/toolchain_test.sh`: `EXPECTED_SBX_VERSION="v0.54.0"`.
  `EXPECTED_PI_VERSION` becomes "`pi --version` runs" (Pi floats). Drop
  entrypoint-wrapper checks. Add: the requested toggle values are what the
  sandbox sees (`SBXAGENT_LITE`, `NETWORK_ALLOWLIST`), so a lost override
  can't silently test the default; `node`, `npm`, `npx`, a writable global
  prefix; `python3 -c 'import yaml'` with the interpreter on `PATH`; the
  github credential (unbound → sandbox still created; bound → one read-only
  authenticated call, not just a non-empty placeholder). Keep `gh api user`
  and a GitHub MCP read as **separate** checks: for Codex they read
  different variable names. The trace check becomes a marker write (step 3).
- `tests/sbxagent_test.sh`: update every `assert_log` for the new argv. Run
  as `env -u SBXAGENT_LITE -u NETWORK_ALLOWLIST make test-unit` in-sandbox.
- `AGENTS.md`: repo map (descriptor + recipe, no `name:`; directory name is
  still the command and sandbox prefix), `make validate` now needs Docker +
  network, args/`--kit-arg`, the host check matrix below.
- `README.md:116` → v0.54.0, usage, the sbxpi "odd one out" paragraph.
- `docs/published-kits.md`: per agent,
  `sbx run claude --kit ghcr.io/lars20070/sbxclaude:<version>`. Point users
  on sbx v0.50.0 at the last v2 tag (`0.4.14`). Remove the "`mixins:` is
  ignored" section. Document the provenance command that is proven to work.
- `docs/assets/quickstart.tape`: new commands.
- `docs/toolchain.md`: sbx v0.54.0, frontend digest; workloads
  `claude`/`codex`/`cursor`/`sbx/pi` float (Pi's exact pin goes); remove
  shell-docker template text.
- `docs/agents.md`, `docs/setup.md`: tokens in `exec`, optional credentials,
  install logs, Pi's added Anthropic policy.
- **Upgrade notes** (README + CHANGELOG): reattach keeps the old setup;
  rebuilding adopts the mixins. Before `sbx<agent> rm`, check your traces are
  on the host and copy out anything that lives only inside the old sandbox.
- `.cspell.json`: new words.
- `CHANGELOG.md` `[Unreleased]` while testing: **Changed** (v3 mixins on
  Docker's agents, new published-kit usage, sbx v0.54.0 required, traces via
  workspace mount, Pi floats, Pi gains optional Anthropic access, rebuild to
  upgrade). **Fixed** (tokens in `exec`). **Removed** (offline
  `kit validate`). At the cut: dated **0.5.0** heading, bump `VERSION` and
  all four `version:` together.
- Memory: update `sbx-047-kit-validate-needs-login` (offline validate is gone
  for v3) once done.

Commits/pushes: none by me (AGENTS.md). I stage and draft the message.

## Verification

1. In-sandbox: `make lint`, `env -u SBXAGENT_LITE -u NETWORK_ALLOWLIST make test-unit`,
   `make test-unit BASH=/bin/bash` if available, `make validate` cold with the
   allowlist on.
2. Host (user), in a disposable checkout, **each agent** (Claude and Pi
   first; Codex and Cursor after those pass), three clean builds, every
   toggle set explicitly:
   ```bash
   ./scripts/sbxclaude rm
   NETWORK_ALLOWLIST=true  SBXAGENT_LITE=false ./scripts/sbxclaude create   # full install, allowlist ON
   NETWORK_ALLOWLIST=true  SBXAGENT_LITE=false make test-toolchain AGENT=claude
   ./scripts/sbxclaude rm
   NETWORK_ALLOWLIST=false SBXAGENT_LITE=false ./scripts/sbxclaude create
   NETWORK_ALLOWLIST=false SBXAGENT_LITE=false make test-toolchain AGENT=claude
   ./scripts/sbxclaude rm
   NETWORK_ALLOWLIST=true  SBXAGENT_LITE=true  ./scripts/sbxclaude create   # defaults
   NETWORK_ALLOWLIST=true  SBXAGENT_LITE=true  make test-toolchain AGENT=claude
   make test-lifecycle AGENT=claude                                        # host-side trace checks (step 0.6)
   ```
   Once with `CROSS_SANDBOX_VISIBILITY=false`. Credentials bound and unbound,
   as separate runs. Also: the guard fires on a blocked host as each agent
   documents; GitHub and Context7 MCP answer from this checkout and from an
   ordinary project (wrapper by absolute path). Record the workload digests
   used.
3. Push branch → CI green.
4. Release rehearsal: `make publish-dry-run` after commit, then
   `workflow_dispatch` with `probe_repo`/`probe_kit` to a throwaway GHCR
   package. Check: version tag and `latest` resolve to the same index; both
   linux architectures carry a kit descriptor; `sbx kit verify` accepts the
   workflow identity; `sbx kit provenance` returns the source revision (if
   not, fix the producer or document what works) and names the real checkout
   commit; `sbx run claude --kit ghcr.io/…probe…` works on the host, and the
   **registry form** of the scoped `--kit-arg` (renamed probe package)
   changes the value inside. Re-run the probe to prove an existing tag is
   reused, not overwritten.
5. Only then cut 0.5.0 (`./scripts/release-notes.sh 0.5.0`, tag on the user's confirm).
