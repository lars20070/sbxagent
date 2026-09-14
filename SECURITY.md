# Security

## Supported versions

Only the latest release (the version in [`VERSION`](VERSION)) receives fixes.
Older tags are not patched; update instead.

## Reporting a vulnerability

Report privately through GitHub's
[private vulnerability reporting](https://github.com/lars20070/sbxagent/security/advisories/new).
Please do not open a public issue for a security bug.

## What the sandbox protects, and what it does not

`sbxagent` exists to contain a coding agent while it works on a repository
you may not fully trust. The boundary is the sandbox; the agent inside it is
treated as hostile.

Inside that boundary the agent can still:

- **Read, rewrite or destroy the mounted project.** The working tree is
  mounted read-write. Keep it under version control and pushed somewhere the
  agent cannot reach.
- **Act with every credential the proxy injects.** The GitHub token never
  enters the sandbox — the agent sees a proxy-managed sentinel — but its
  *powers* do: a compromised agent can push, open pull requests and read
  private repositories exactly as that token allows. Scope the token narrowly.
  See [docs/setup.md](docs/setup.md).
- **Reach every host on the network allowlist.** Each kit's
  `permissions.network.allow` in `kits/<name>/spec.yaml` is the complete list.

The network-block guard is a courtesy, not a wall, and it lands with
different force in each agent: Claude Code is a hard stop, Codex is soft
(nothing enforces the stop), Cursor has no guard, and Pi's guard can be
unregistered by the agent. [docs/agents.md](docs/agents.md) has the detail.

## Why the wrapper is a plain shell script

Many CLI tools install via `curl | sh`, a package manager postinstall hook,
or a bootstrapper that downloads further code at install or run time. Each
of those steps is an opportunity to inject malicious code outside of what a
user can easily review, and is a common vector for supply-chain attacks.

`scripts/sbxagent` avoids this entirely. It is a single, self-contained bash
script with no install step, no build step, and no external dependencies of
its own. `git clone` and run — the full behaviour is the ~250 lines in that
file, readable end to end by a user or a coding agent before it is trusted.

The trade-off is convenience: there is no package manager entry and no
auto-update mechanism. Updating means pulling the repository again. In
exchange, there is no install-time code path that could hide something the
static source does not show. After cloning, the best way to verify
`sbxagent` is to have your coding agent check the repository for malicious
code.

This is a different guarantee from kit verification (below). The kits need
signing and provenance because they bundle setup commands, run inside the
sandbox, and get network access — properties that cannot be fully checked by
reading source alone. The wrapper carries none of that risk; it is auditable
by inspection.

## Verifying the sandbox kits

The published kits are the artifacts to verify. Each is signed keyless through
this repository's GitHub Actions release workflow and carries a SLSA
provenance attestation, so you can check that a kit was built here and not
merely that somebody signed it. The commands are in
[docs/published-kits.md](docs/published-kits.md).

Git tags and commits are not signed.
