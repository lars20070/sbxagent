# Plan: tool inventory + gap recommendations for the four sandbox kits

## Context

The user wants to know, across all four sandbox kits (`sbxclaude`, `sbxcodex`,
`sbxcursor`, `sbxpi`), what tools are installed today, and whether any
**general-purpose** tools useful to a coding agent are missing. Kit-specific
asks are already covered by `docs/published-kits.md`'s stacking mechanism, so
this is about the shared baseline every kit gets. The deliverable is a
markdown file at the repo root with the inventory and weighed recommendations
— no code or spec changes in this pass.

## What I found (already gathered, no more research needed)

All four `kits/*/spec.yaml` plus `docs/toolchain.md` and `docs/agents.md` were
read directly. Summary:

**Shared across all four kits:**
`ca-certificates`, `curl`, `jq`, `python3`, `ripgrep` (`rg`), `shellcheck`,
`sbx` CLI (pinned, checksum-verified), `github-mcp-server` (pinned,
checksum-verified), `ruff` 0.16.2, `yamllint` 1.38.0, `markdownlint-cli2`
0.23.2, `cspell` 10.0.1, Playwright 1.62.1 + headless Chromium, `mmdc`
(mermaid-cli) 11.16.0, plus `git`/`docker`/`node`/`npm` from each kit's base
image. Context7 + GitHub MCP servers wired in (except `sbxpi`, which has no
MCP support at all).

**Per-kit deltas:**
- `sbxpi` only: `fd-find` (as `fdfind`), `gh` CLI (via base `shell-docker`
  template — Pi has no MCP, so it does GitHub work with `git`/`gh`), the Pi
  agent itself, Context7 as a native Pi package.
- `sbxcodex`: network-block guard registered as a Codex hook (soft
  enforcement, documented in `docs/agents.md`).
- `sbxcursor`: no network-block guard at all (Cursor exposes no hook
  equivalent — documented gap, not a bug).
- Network allowlist is the same ~14-host set on `sbxclaude`/`sbxcodex`/
  `sbxcursor` (each inherits the rest from its parent kit); `sbxpi` repeats it
  explicitly plus apt-source hosts, since it has no parent kit to inherit
  from.

## Brainstormed gaps, weighed

**Recommend adding (cheap, broadly useful, no network-policy change needed —
apt sources already allowlisted in all four kits):**
1. **`make`** — not currently installed anywhere. Extremely common as the
   entry point for build/lint/test across many languages (this very repo
   uses it). Worth flagging even though the parent base images *might*
   already carry it — recommend an explicit pin so all four kits guarantee it
   rather than relying on an unverified base-image assumption.
2. **`yq`** — no YAML/TOML equivalent of `jq` today, despite YAML/TOML being
   pervasive in this repo's own domain (kit specs, GitHub Actions,
   `~/.codex/config.toml`). Pairs naturally with the existing `jq` +
   `yamllint`.
3. **`fd-find`** on `sbxclaude`/`sbxcodex`/`sbxcursor` — currently `sbxpi`-only
   because Pi's own search tool needs it, but `fd` is the natural filename-search
   complement to the `rg` content-search already installed everywhere else.
   Trivial apt add, closes an inconsistency between kits.

**Considered, not recommended (explicitly call out why, to show the weighing
rather than silence):**
- `bat`, `httpie`, `tree`, `git-delta`, GNU `parallel`, `sqlite3`, `ncdu` —
  each a real quality-of-life tool, but each already has a working
  substitute in the current toolchain (`cat`, `curl`, `find`/`fd`, raw
  `git diff`, sequential loops, etc.), so adding them is polish, not a gap.
- Per-language runtimes (Go, Rust, Java, …) — deliberately out of scope for
  the *shared* baseline: each would need its own registry added to the
  network allowlist (crates.io, Go proxy, Maven Central, …), and which
  languages matter is project-specific. The existing "stack your own kit"
  mechanism in `docs/published-kits.md` is the right lever for this, not a
  baseline addition.
- Language/version managers (`mise`, `asdf`) — same reasoning; passwordless
  `sudo` + apt already lets an agent install what a specific project needs,
  at the cost of expected network-policy friction the guard already explains.
- `docker compose` plugin — plausibly already present via the base image;
  flag as "worth verifying" rather than a firm recommendation, since I have
  no direct evidence either way.

## Deliverable

Write `TOOL_RECOMMENDATIONS.md` at the repo root containing:
1. A short intro (what this covers, why root-level).
2. A table of the shared toolchain (mirrors what's now in `docs/toolchain.md`,
   but framed as "installed" rather than "pinned versions").
2. A per-kit delta table (Pi's extras, MCP-vs-`gh` split, guard-enforcement
   differences).
3. The recommendations section, split into "add" (make, yq, fd-find parity)
   and "considered, skipped" (with one-line reasons each), plus the
   docker-compose "verify" note.
4. A closing pointer to `docs/published-kits.md`'s kit-stacking mechanism for
   anything project-specific rather than baseline.

No `kits/*/spec.yaml` or `kits/*/files/` changes in this pass — this is a
recommendations document only, so `make validate` is not required. Since it's
a new root-level markdown file, run `make lint` afterward (covers
`markdownlint-cli2` and `cspell`) and add any flagged-but-correct words to
`.cspell.json`, matching this repo's existing convention.
