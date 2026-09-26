# sbx issues worth watching

This page tracks issues in
[docker/sbx-releases](https://github.com/docker/sbx-releases/issues) whose
fixes would simplify or improve sbxagent.

Only the **top 10** in section 1 need active watching. Everything else is
research, sorted by when it is worth looking at again.

**An issue being closed is never enough reason to delete a workaround on its
own.** Every active row says what still has to be proven first.

## Baseline

| | |
| --- | --- |
| Date | 2026-09-26 |
| Repo revision | `04e1908` |
| Pinned sbx | `v0.45.0` (some findings below come from `v0.45.1` reports) |
| Open issues scanned | 342 at 06:09 UTC (every open issue, pull requests excluded). A later fetch the same day had 343. |

**How the list was built:**

1. Every workaround in the repo was listed: the wrapper, kit specs,
   `mount-state.sh`, `publish-kit.sh`, CI, tests and docs.
2. The titles and bodies of all open issues were searched for terms that match
   those workarounds.
3. The candidates were read. Key issues also had their comments read.
4. A review then added #629, which the first search terms had missed. It also
   narrowed several mappings and brought in points from the issue comments.

**Rule for the active list:** an issue is active only if both are true:

- It is linked to a current failure, a real maintenance burden, or a credible
  current exposure.
- An upstream change would trigger a specific decision here.

Related issues are listed under their main issue rather than watched on their
own.

**Cadence:** check the active list whenever sbx is upgraded, and lightly once a
month. Don't re-scan all open issues for every release unless a new symptom
calls for it.

## 1. Active watch list: top 10

Ranked by current impact, how directly the repo depends on the issue, and the
decision a fix would enable. Nine are open. #553 is closed and marked
`awaiting-release`.

| Rank | Issue | Why watch it | Trigger for action |
| --- | --- | --- | --- |
| 1 | [#526](https://github.com/docker/sbx-releases/issues/526) virtiofs reports workspace files as sparse, so `cp` writes NUL bytes | Silent data corruption. The wrapper turns the virtiofs cache off because of it (`scripts/sbxagent:56-61`), and a unit test uses `cat` instead of `cp` (`tests/sbxagent_test.sh:681-687`). | A [v0.45.1 comment](https://github.com/docker/sbx-releases/issues/526#issuecomment-5827673975) says the `cp` failure no longer reproduces, but only in synthetic tests. [Another comment](https://github.com/docker/sbx-releases/issues/526#issuecomment-5504774424) shows `lseek(SEEK_DATA)` still misreports holes **even with the cache off**, so the test's `cat` may need to stay. Remove the export only when #629 also passes. |
| 2 | [#629](https://github.com/docker/sbx-releases/issues/629) virtiofs cache: a name made with `link()` is missing from directory listings, and `fsync()` returns `ENOTEMPTY` | Breaks `git clone` into the workspace on v0.45.1 (macOS host). The workaround is the **same** cache switch as #526. | Handle together with #526. On a freshly created sandbox with the cache **on**, test: repeated in-place rewrites followed by copies; that a hard-linked name shows up in the directory listing; and repeated local `git clone --no-local` runs with a large pack. One successful copy is not enough. |
| 3 | [#420](https://github.com/docker/sbx-releases/issues/420) kit startup commands do not replay after `sbx daemon restart` | All four kits call `mount-state.sh` twice because of it: once from the entrypoint (e.g. `kits/sbxclaude/spec.yaml:45-57`) and once from a startup step (`:458-483`). `tests/mount_state_test.sh:292-337` asserts both callers. | Check that startup steps replay after a daemon restart and on a direct `sbx exec`. Keep the entrypoint fallback until #299's guarantees also hold. |
| 4 | [#299](https://github.com/docker/sbx-releases/issues/299) allow declaring startup scripts as blocking | The other half of dropping that fallback. Today the entrypoint refuses to start the agent if the mount fails, so transcripts never land on a path that dies with the sandbox. | Check that the mount finishes before the agent launches, and that a mount failure stops the launch. Only the **mount fallback** can go. The entrypoint wrappers stay, because they also export `GITHUB_TOKEN` (`kits/sbxclaude/spec.yaml:34-44`, `kits/sbxcodex/spec.yaml:35-49`, `kits/sbxcursor/spec.yaml:39-51`). The "one caller" sketch in `docs/traces.md:276-315` is an assumption to re-test. |
| 5 | [#42](https://github.com/docker/sbx-releases/issues/42) allow remapping extra mount paths inside the microVM | Could remove most of the trace-mount machinery: the bind mount (`mount-state.sh:79`) and the `SBXAGENT_STATE_DIR` plumbing (`scripts/sbxagent:260`, `:296`). | Prove three things: a remapped mount can sit where the parent kit already mounts its own volume (`mount-state.sh:7-11`); existing traces still migrate (`:58-76`); and the mount survives stop/start and daemon restart. |
| 6 | [#581](https://github.com/docker/sbx-releases/issues/581) let `setup.files` take a `source:` file and a `user:` | Would remove the heredoc copies of `network-block.jq`/`.ts`, `managed-settings.json` and `requirements.toml` (e.g. `kits/sbxclaude/spec.yaml:249-377`, `kits/sbxcodex/spec.yaml:259-401`, `kits/sbxpi/spec.yaml:267-486`), plus the heredoc sync check in `Makefile:68-97`. | Confirm the files land root-owned, outside `$HOME`, packaged from source files. Keep the self-tests that follow each copy. |
| 7 | [#553](https://github.com/docker/sbx-releases/issues/553) `sbx kit sign` fails on GHCR with 405 on the referrers-index DELETE | **Closed, `awaiting-release`.** [Maintainer comment](https://github.com/docker/sbx-releases/issues/553#issuecomment-5810564178): sign and `push --sign` will warn and exit 0. Provenance had the same defect and is fixed too. Every release runs this workaround (`scripts/publish-kit.sh:259-292`). | See section 2. |
| 8 | [#612](https://github.com/docker/sbx-releases/issues/612) the MCP gateway exposes all host MCP servers | A reported exposure in current sbx. `sbxclaude` deliberately keeps the parent's gateway registration (`kits/sbxclaude/spec.yaml:484-490`). | **Investigate now.** Check what the gateway actually exposes in `sbxclaude`, `sbxcodex` and `sbxcursor`. Pi has no MCP support (`README.md:163`), so don't assume `sbxpi` is affected. If exposure is confirmed, adopt a supported filter or off switch. Related: [#455](https://github.com/docker/sbx-releases/issues/455) (the claude kit re-registers the gateway after a user removes it). |
| 9 | [#611](https://github.com/docker/sbx-releases/issues/611) a blocked domain fails three different ways | Decides whether the network-block guards (`kits/network-block.jq` and the Pi extension) detect a block, or mistake it for an ordinary connection error. | A [Docker contributor says](https://github.com/docker/sbx-releases/issues/611#issuecomment-5765061040) DNS denial is **intentional** (it stops data leaking out through DNS). So one uniform HTTP 403 is not promised; a "local sink address" is only an idea. Test any new block signal on the proxy, DNS and direct-IP paths before changing the parser. Don't expect the text parser to go away. Related: [#424](https://github.com/docker/sbx-releases/issues/424) (machine-readable policy audit stream). |
| 10 | [#617](https://github.com/docker/sbx-releases/issues/617) v3 kits can be used but not written locally, and the schema is undocumented | All four kits depend on a supported format for writing and publishing kits. They stay on `schemaVersion: "2"` (`CHANGELOG.md:36-38`). `mixins:` is accepted and then ignored in v0.45.0 (`docs/published-kits.md:115-120`). | Once v3 can be written and validated locally, prototype one kit and check composition and publishing. This is a milestone, not a promise that the four kits can be deduplicated. |

## 2. Release follow-up

### #553: signing exit code

Once a release containing the fix is out:

1. Confirm from the release notes that it contains the fix.
2. Bump the version **and** SHA-256 pins together:
   - `.github/workflows/release.yml:208-209`
   - all four `kits/*/spec.yaml` (e.g. `kits/sbxclaude/spec.yaml:185-199`)
   - `tests/toolchain_test.sh:14`
   - `README.md:108`
   - `docs/toolchain.md:75`
3. Run a GHCR probe (`workflow_dispatch` with `probe_repo`/`probe_kit`).
   `sbx kit sign` must exit 0 on a digest that already has provenance.
4. Then make a real sign failure fatal. Today it only prints a NOTICE
   (`scripts/publish-kit.sh:259-280`). Shrink `AGENTS.md:150-179` to match.
5. **Keep** two things:
   - the separate sign step on the digest-reuse path
   - the issuer/identity `sbx kit verify` gate (`scripts/publish-kit.sh:15-20`, `:282-292`), which checks *who* signed; exit code 0 does not
6. `docs/published-kits.md:25-32` stays as it is. The `sha256-<digest>` tag
   still exists.
7. Then retire this row.

### Closed issues that still carry risk

| Issue | Why it matters | What to do |
| --- | --- | --- |
| [#409](https://github.com/docker/sbx-releases/issues/409) "0.38.0 breaks the ability to copy agent configs through kits" | Closed after Docker documented agent config paths as "sandbox-managed". sbxagent still edits two of them: the `jq` merge into `~/.claude.json` (`kits/sbxclaude/spec.yaml:484-517`) and the TOML prepend and append in `~/.codex/config.toml` (`kits/sbxcodex/spec.yaml:457-502`). | Expect those steps to break when sbx changes. `tests/toolchain_test.sh` is the tripwire. Check at every upgrade (section 3). |

## 3. Check during sbx upgrades

Not watched continuously. Check these while validating an upgrade, or
immediately if the failure shows up. A failure you can reproduce in sbxagent
moves the issue into section 1.

| Issue(s) | What to check | Where in sbxagent |
| --- | --- | --- |
| [#152](https://github.com/docker/sbx-releases/issues/152), [#412](https://github.com/docker/sbx-releases/issues/412), #409 agent config handling | Does the parent kit still leave room for our edits to `config.toml` and `~/.claude.json`? | `kits/sbxcodex/spec.yaml:457-502`, `kits/sbxclaude/spec.yaml:484-517` |
| [#25](https://github.com/docker/sbx-releases/issues/25), [#477](https://github.com/docker/sbx-releases/issues/477) secrets lifecycle | A [Docker team member says](https://github.com/docker/sbx-releases/issues/25#issuecomment-4313732396) `sbx secret set` stores the secret and allows injection, but does **not** set env vars. So check two things **separately**. **GitHub:** is `GITHUB_TOKEN` set in an `exec bash` session, not only in the agent? Only then can the alias exports go. Codex still needs `GITHUB_PERSONAL_ACCESS_TOKEN`. **OpenRouter:** can Pi authenticate with only `sbx secret set openrouter`, both on first create and on later starts? Only then can the second `set-custom` step go. Neither result follows from #25 being closed. | Entrypoint exports (section 1, #299); `docs/setup.md:52-65`; `docs/agents.md:144` |
| [#196](https://github.com/docker/sbx-releases/issues/196) kit credential injection lost after a host reboot | Does `sbxpi`'s `proxyManaged` OpenRouter credential still work after a host reboot? | `kits/sbxpi/spec.yaml` credentials |
| [#229](https://github.com/docker/sbx-releases/issues/229) `set-custom` upsert is keyed on the placeholder | Could a second custom secret silently replace the OpenRouter one? | `docs/setup.md:61-64` |
| [#388](https://github.com/docker/sbx-releases/issues/388) a mount silently detaches after a host-side change | Upstream is about a **nested read-only** mount. The write bypass is [reported mitigated](https://github.com/docker/sbx-releases/issues/388#issuecomment-5155840874), while the detach remains. The local test probes a **trace bind mount**, a different layout. Treat it as a related canary: a pass does not prove the upstream bug is gone, and a fail does not prove this is that bug. | `tests/lifecycle_test.sh:187-203` |
| [#580](https://github.com/docker/sbx-releases/issues/580) a kit's rules apply on top of a global deny-all | [A commenter points out](https://github.com/docker/sbx-releases/issues/580#issuecomment-5631203105) that the global policy is only the *initial* policy. Kit allow rules apply on top per sandbox, and an explicit per-sandbox `deny "**"` should still win. So the sbxagent kits **do** widen a global deny-all, which is expected behaviour. Nothing shows that explicit deny rules are bypassed. Check the precedence at upgrades; act only on a real enforcement failure. | `permissions.network.allow` in every kit |
| [#442](https://github.com/docker/sbx-releases/issues/442) kit install fails under a "Locked Down" global policy | Can a user on Locked Down still build the kits? | apt steps in every kit |
| [#202](https://github.com/docker/sbx-releases/issues/202) bundled agents lag upstream releases | Which agent version does each parent template ship? | `extends:` in the three parent-based kits |

## 4. Revisit when planning the feature

Useful, but none needs continuous tracking. Read them when that area changes.

| Feature area | Issues | Where in sbxagent |
| --- | --- | --- |
| Pi on a parent kit | [#34](https://github.com/docker/sbx-releases/issues/34) Pi coding agent sandbox | `sbxpi` cannot use `extends:` (`kits/sbxpi/spec.yaml:18-23`), so it builds on `shell-docker` and re-lists hosts and apt sources |
| Tighter network permissions | [#99](https://github.com/docker/sbx-releases/issues/99) separate permissions for the install step | Build-only hosts stay allowed for the agent's whole life |
| SSH git remotes | [#46](https://github.com/docker/sbx-releases/issues/46) proxy drops outbound SSH (port 22) | `insteadOf` rewrites in every `kits/*/files/home/.gitconfig:6-7` |
| Ollama for `sbxpi` | [#546](https://github.com/docker/sbx-releases/issues/546) `policy check` and enforcement disagree for `host.docker.internal` | Related evidence only; see section 7 |
| Kit diagnostics | [#606](https://github.com/docker/sbx-releases/issues/606) show the resolved, merged YAML; [#575](https://github.com/docker/sbx-releases/issues/575) easier debugging of failing kits; [#570](https://github.com/docker/sbx-releases/issues/570) `WORKDIR` vs `WORKSPACE_DIR` | `kits/sbxcodex/spec.yaml:150-152` relies on `policy check` to see inherited hosts |
| Sandbox metadata and drift | [#427](https://github.com/docker/sbx-releases/issues/427) show the creating sbx version; [#457](https://github.com/docker/sbx-releases/issues/457) sandbox metadata (related: [#551](https://github.com/docker/sbx-releases/issues/551), [#503](https://github.com/docker/sbx-releases/issues/503)) | `REBUILD_HINT` (`tests/toolchain_test.sh:104`); args echoed as env vars (`kits/sbxclaude/spec.yaml:21`, `mixins/open-network/spec.yaml:15`); kit name taken from the hostname (`tests/toolchain_test.sh:9`) |
| Wrapper state checks | [#422](https://github.com/docker/sbx-releases/issues/422) `--format json` and stable exit codes (related: [#504](https://github.com/docker/sbx-releases/issues/504), which covers `sbx exec` only while the wrapper uses `sbx inspect`; [#201](https://github.com/docker/sbx-releases/issues/201) invalid JSON when the daemon is stopped; [#398](https://github.com/docker/sbx-releases/issues/398) no client timeout; [#283](https://github.com/docker/sbx-releases/issues/283) `daemon status` exits 0) | Existence check `scripts/sbxagent:255` |
| Wrapper naming and attach | [#624](https://github.com/docker/sbx-releases/issues/624) start the sandbox for the current directory; [#352](https://github.com/docker/sbx-releases/issues/352) slow re-attach; [#602](https://github.com/docker/sbx-releases/issues/602) fails for a dot-named workspace | `scripts/sbxagent:215-256` |
| Agent instructions | [#204](https://github.com/docker/sbx-releases/issues/204), [#122](https://github.com/docker/sbx-releases/issues/122), [#446](https://github.com/docker/sbx-releases/issues/446), [#567](https://github.com/docker/sbx-releases/issues/567) generated `CLAUDE.md`/`AGENTS.md` | Sits next to each kit's `agentInstructions` |
| Test cleanup | [#26](https://github.com/docker/sbx-releases/issues/26) `--rm` for throwaway sandboxes | `tests/lifecycle_test.sh:60-72` |

## 5. Supporting links

Read these when their main issue changes.

| Main issue | Supporting links |
| --- | --- |
| #42 mounts | [#357](https://github.com/docker/sbx-releases/issues/357) startup commands in templates; [#136](https://github.com/docker/sbx-releases/issues/136) add workspaces after creation (no destination override); [#137](https://github.com/docker/sbx-releases/issues/137) main workspace path only |
| #581 kit files | [#499](https://github.com/docker/sbx-releases/issues/499) mode bits. Keeping mode bits alone does not give root ownership outside `$HOME`. |
| #617 composition | [#187](https://github.com/docker/sbx-releases/issues/187) merge changes to the **same file** from several kits (narrower than shared kit dependencies); [#594](https://github.com/docker/sbx-releases/issues/594) built-in agent mixins; [#120](https://github.com/docker/sbx-releases/issues/120) `memory` in mixins; [#474](https://github.com/docker/sbx-releases/issues/474) extended kit behaves differently; [#475](https://github.com/docker/sbx-releases/issues/475) override with an empty list |
| Hosted GitHub MCP (`docs/agents.md:97-104`) | [#231](https://github.com/docker/sbx-releases/issues/231) `gho_`-prefixed sentinel; [#595](https://github.com/docker/sbx-releases/issues/595) Copilot CLI 401. The hosted endpoint also needs the **Copilot Requests** PAT permission, which neither issue touches. Keep the local `github-mcp-server` until the hosted endpoint is tested with the credentials sbxagent supports. |
| #612 MCP gateway | [#455](https://github.com/docker/sbx-releases/issues/455) |
| #611 block signal | [#424](https://github.com/docker/sbx-releases/issues/424) |

## 6. Archived unless requirements change

The current code does not use the affected feature, or the link is too
indirect to need attention.

| Issue | Why archived |
| --- | --- |
| [#116](https://github.com/docker/sbx-releases/issues/116) GitHub Packages auth | The kits don't pull from `*.pkg.github.com`. |
| [#213](https://github.com/docker/sbx-releases/issues/213) identical `proxyManaged` sentinels | No per-repo tokens today. |
| [#269](https://github.com/docker/sbx-releases/issues/269) duplicate kit names in a composition | No third-party kits are stacked. |
| [#318](https://github.com/docker/sbx-releases/issues/318) `sbx kit add` ignores network rules | The wrapper applies kits at create time, not with `kit add`. |
| [#436](https://github.com/docker/sbx-releases/issues/436) reapplying kit changes | It is about relative paths when `sbx kit add` is repeated. The wrapper doesn't use `kit add`, so a fix would not replace rm-and-recreate. |
| [#501](https://github.com/docker/sbx-releases/issues/501) execution bound to a fixed policy revision | A different feature from reading the policy or replacing the block parser. |
| [#485](https://github.com/docker/sbx-releases/issues/485) `exec` and ssh start in different directories | sbxagent doesn't use ssh. |
| [#505](https://github.com/docker/sbx-releases/issues/505) `sbx exec -d` hangs | `-d` isn't used. |
| [#541](https://github.com/docker/sbx-releases/issues/541) `docker-sbx` plugin binary; [#174](https://github.com/docker/sbx-releases/issues/174) Linux Homebrew formula | Install convenience only. |
| [#566](https://github.com/docker/sbx-releases/issues/566) `sbx kit pack` includes its own output | Publishing uses `sbx kit push`, not `pack -o`. |

## 7. Workarounds with no matching open issue found

Searched on 2026-09-26: the local copy of all open issues (titles and bodies),
plus GitHub issue search over open **and** closed issues for the first five
rows. "Not found" means no match turned up. It does not prove no issue exists.

These are possible investigations, not things to monitor. Look into one only
if it starts to hurt.

| Workaround | Where | Notes |
| --- | --- | --- |
| `sbx kit push` packs untracked files (for example `.DS_Store`) | `scripts/publish-kit.sh:117-124` (`git archive` staging) | Closest are #566 and [#627](https://github.com/docker/sbx-releases/issues/627) (global git ignores). Neither covers it. |
| No way to check whether a kit tag exists, and no `sbx kit tag` | `scripts/publish-kit.sh:194` (`oras manifest fetch`), `:252` (`oras tag`) | Nothing matched. |
| `sbx kit push` is not reproducible (`created` timestamp) | `scripts/publish-kit.sh:241-252` | [#423](https://github.com/docker/sbx-releases/issues/423) asks for content-addressed **templates**, not kits. |
| `sbx exec` does not detect a TTY | `scripts/sbxagent:279-282` (`-it` vs `-i`) | Nothing matched. |
| Startup steps run with a minimal `HOME`/`PATH` | `kits/sbxcursor/spec.yaml:351-354, 365-367`; `HOME=` in every kit's startup step | Nothing found, open or closed. |
| npm through the proxy is flaky on `shell-docker` | `kits/sbxpi/spec.yaml:499` (`npm config set proxy`), `:556-573` (retry loop) | Nothing matched. |
| No minimum-sbx-version field in a kit spec | `README.md:108` | Nothing matched. |
| Ollama: a kit cannot allow the host's model server | `kits/sbxpi/spec.yaml:125-134`; `docs/setup.md:111-123` | Two separate failures. A kit allow for `localhost:11434` is **rejected** ("failed to apply kit"). An allow for `host.docker.internal:11434` is **accepted but never matches**, because the proxy rewrites it to `localhost`. #546 shows the same rewrite, but for a **deny** rule. Drop the manual host-side `sbx policy allow` only once a kit allow rule is shown to let the request through. |

## 8. Local backlog (not upstream)

Ordinary repo maintenance. Nothing was changed.

- **Re-test [#284](https://github.com/docker/sbx-releases/issues/284).** It is
  closed as completed, with no details. The Cursor kit pre-approves MCP servers
  in a **startup** step only because `install` runs before `files/home/` is
  copied (`kits/sbxcursor/spec.yaml:347-349`). Test on v0.45.0 whether
  `~/.cursor/mcp.json` exists during `install`. If it does, the step could move
  to `install` and drop its `HOME`/`PATH` fix-up.
- **The fd-3 output split in `scripts/publish-kit.sh:73-82` is not an sbx
  workaround.** It keeps every tool's output, including `oras`, out of
  `$GITHUB_OUTPUT`. `--json` on `kit validate`/`inspect` (available in v0.45.0)
  would not replace it.
- **Wrong issue number in a commit.** Commit `4156b5d` says "Revert after
  **#425** fix in sbx 0.42.0". The fix was
  [#415](https://github.com/docker/sbx-releases/issues/415), which is closed,
  as is its regression [#540](https://github.com/docker/sbx-releases/issues/540).
  #425 is an unrelated request for nested virtual machines. `CHANGELOG.md:274`
  has the right number.
- **Stale `.claude.json` references.**
  `kits/sbxclaude/files/home/.claude.json` no longer exists, but it is still
  referenced in `docs/agents.md:74` (a dead link) and
  `tests/toolchain_test.sh:400-402` (a comment).
- **Wrong binary name.** `docs/traces.md:269` says `cursor-agent`, but the
  Cursor entrypoint runs `agent` (`kits/sbxcursor/spec.yaml:63`).
