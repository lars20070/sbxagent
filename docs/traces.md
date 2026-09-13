# Session traces

Where each agent's session trace ends up, and who else can read it. See
[toolchain.md](toolchain.md) for the state folder these paths sit in.

## Where the traces live

The wrapper keeps each agent's native session format and relocates its trace
tree into that agent's state subfolder:

| Agent | Stock path in the sandbox | Path below the agent state folder |
| --- | --- | --- |
| Claude Code | `~/.claude/projects` | `projects/` |
| Codex | `~/.codex/sessions` | `sessions/` |
| Cursor | `~/.cursor/projects` | `projects/` |
| Pi | `~/.pi/agent/sessions` | `sessions/` |

Each stock path stays a real directory at all times, and the wrapper bind-mounts
the matching state subfolder over it. It is deliberately not replaced by a
symlink: the agent's own persistent volume is mounted at that path, the sandbox
runtime recreates that mount destination on every start, and it cannot do so
through a symlink — a sandbox that had one there failed every restart after its
first.

A bind mount is not stored on disk the way a symlink is, so it has to be re-made
on every sandbox start. Two things do it, and both are needed: a startup step
that the sandbox runs at each start, and the entrypoint that launches the agent.
The startup step covers sessions that never launch the agent, such as
`sbxclaude exec bash`; the entrypoint covers the starts where a startup step is
known not to re-run, after a daemon restart or when a stopped sandbox is woken by
a command rather than by an agent session. Whichever runs first does the work and
the other finds the folder already relocated.

## Cross-sandbox visibility

With the default `CROSS_SANDBOX_VISIBILITY=true`, sibling agents for the same
project can read these complete traces, including prompts, tool output, file
excerpts, and any secrets recorded in them. Set
`CROSS_SANDBOX_VISIBILITY=false` before creating a sandbox to hide sibling
state. This setting, and whether traces are relocated at all, are fixed at
sandbox creation time; remove and rebuild existing sandboxes after changing the
setting or upgrading to a kit that supports traces.

## Retention and exceptions

Claude Code applies its normal `cleanupPeriodDays` retention setting (30 days
by default) to these host-backed transcripts. Cursor's SQLite resume store
remains inside its sandbox to avoid database locking on the shared mount. A kit
started directly with `sbx run`, without the wrapper-provided
`SBXAGENT_STATE_DIR`, keeps its stock trace location.
