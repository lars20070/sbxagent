# Session traces

Where each agent's session trace ends up, and who else can read it. See
[toolchain.md](toolchain.md) for the state folder these paths sit in.

## Contents

- [How traces reach the host](#how-traces-reach-the-host)
- [Where the traces live](#where-the-traces-live)
- [Trace formats](#trace-formats)
- [Cross-sandbox visibility](#cross-sandbox-visibility)
- [Retention and exceptions](#retention-and-exceptions)
- [Under the hood](#under-the-hood)

## How traces reach the host

Each agent saves its sessions where it always does, inside the sandbox. The
wrapper makes that folder and a folder on your machine the same folder. The
host folder is `~/.local/state/sbxagent/traces/<slug>-<hash>/<agent>/`, for example
`…/sbxclaude/`.

So when the agent saves a session, the file is on your machine at once. Nothing
copies or syncs it later.

It works in two steps:

1. The wrapper mounts the host folder into the sandbox.
2. Inside, a small script mounts that folder over the agent's own session
   folder. Whatever the agent writes there lands on the host.

Step 2 is a bind mount. Think of it as one folder with two doors. It does not
survive a restart, so the sandbox redoes it every time it starts. It is safe to
redo: if the two folders are already the same, the script does nothing.

```mermaid
flowchart LR
  subgraph HOST["your machine"]
    direction TB
    WRAP["sbxclaude / sbxcodex<br/>sbxcursor / sbxpi"]
    STATE["~/.local/state/sbxagent/traces<br/>&lt;slug&gt;-&lt;hash&gt;/&lt;agent&gt;/"]
  end

  subgraph VM["sbx sandbox"]
    direction TB
    MOUNT["mount-state.sh<br/>runs at every start"]
    STOCK["usual session folder<br/>e.g. ~/.claude/projects"]
    AGENT["coding agent"]
  end

  WRAP -->|"creates / attaches"| VM
  STATE -.->|"1. wrapper mounts it in"| MOUNT
  MOUNT -->|"2. bind-mounts it over"| STOCK
  STATE <-.->|"same files"| STOCK
  AGENT -->|"writes sessions"| STOCK

  classDef data    fill:aliceblue,stroke:steelblue,stroke-width:2px,color:#10314F
  classDef host    fill:#FDF3E0,stroke:#B8860B,stroke-width:2px,color:#4A3405
  classDef agent   fill:#FCE7E7,stroke:#B23A48,stroke-width:2px,color:#5A1015
  classDef step    fill:#E8F3EC,stroke:#2E7D4F,stroke-width:2px,color:#0F3D22
  class STATE data
  class WRAP host
  class AGENT agent
  class MOUNT step
  style VM fill:#F6F6F5,stroke:#7A8482,stroke-width:1.5px
  style HOST fill:#FFFDF7,stroke:#B8860B,stroke-width:1.5px,stroke-dasharray:4 3
```

<br>*The wrapper (amber) creates the sandbox and mounts the host state folder
(blue) into it. At every start, a script (green) mounts that folder over the
agent's usual session path. The agent (red) keeps writing there, and the files
show up on the host. See [Under the hood](#under-the-hood) for the details.*

## Where the traces live

Everything sits under one folder in your home directory:

```text
~/.local/state/sbxagent/traces/<slug>-<hash>/<agent>/
```

- `<slug>` is the name of your project folder. Anything that is not a letter,
  digit or dash becomes a dash.
- `<hash>` is the first 8 characters of a SHA-256 of the project's full path.
  Two projects with the same folder name still get different state folders.
- `<agent>` is the wrapper you ran: `sbxclaude`, `sbxcodex`, `sbxcursor` or
  `sbxpi`.

Say your project is `~/Code/weather-app` and you have used all four agents on
it. Your home folder then looks like this:

```text
~
├── Code
│   └── weather-app                      ← your project
└── .local
    └── state
        └── sbxagent
            └── traces
                └── weather-app-3f9a1c2e     ← <slug>-<hash>
                    ├── sbxclaude
                    │   └── projects
                    │       └── -Users-you-Code-weather-app
                    │           └── 8c1d2e7a-….jsonl
                    ├── sbxcodex
                    │   └── sessions
                    │       └── 2026
                    │           └── 09
                    │               └── 13
                    │                   └── rollout-2026-09-13T10-42-07-….jsonl
                    ├── sbxcursor
                    │   └── projects
                    │       └── Users-you-Code-weather-app
                    │           └── agent-transcripts
                    │               └── 5b7e…
                    │                   └── 5b7e….jsonl
                    └── sbxpi
                        └── sessions
                            └── --Users-you-Code-weather-app--
                                └── 2026-09-13T10-42-07_….jsonl
```

You do not have to work any of that out. In your project, run `sbxclaude name`
(or the matching command for the other agents). It prints
`sbxclaude-<slug>-<hash>`. Drop the `sbxclaude-` prefix and you have the folder:

```bash
cd ~/.local/state/sbxagent/traces/"$(sbxclaude name | sed 's/^sbxclaude-//')"/sbxclaude
```

If you set `XDG_STATE_HOME`, the tree lives under `$XDG_STATE_HOME/sbxagent/traces/`
instead of `~/.local/state/sbxagent/traces/`.

The wrapper keeps each agent's native session format and relocates its trace
tree into that agent's state subfolder:

| Agent | Stock path in the sandbox | Path below the agent state folder |
| --- | --- | --- |
| Claude Code | `~/.claude/projects` | `projects/` |
| Codex | `~/.codex/sessions` | `sessions/` |
| Cursor | `~/.cursor/projects` | `projects/` |
| Pi | `~/.pi/agent/sessions` | `sessions/` |

## Trace formats

Each agent owns its own on-disk format; the wrapper only keeps those files on
the host. Layouts can change with agent releases. Roughly, under each agent's
state subfolder:

| Agent | Typical path under the agent state folder | What you find |
| --- | --- | --- |
| Claude Code | `projects/-<escaped-cwd>/<session-uuid>.jsonl` | One JSONL file per session; each line is a typed event (`user`, `assistant`, and similar) |
| Codex | `sessions/<YYYY>/<MM>/<DD>/rollout-<timestamp>-<id>.jsonl` | Date-bucketed “rollout” JSONL files |
| Cursor | `projects/<escaped-cwd>/agent-transcripts/<id>/<id>.jsonl` | Per-chat transcript JSONL (`role` user/assistant). Other project files (for example `mcp-approvals.json`) may sit alongside |
| Pi | `sessions/--<escaped-cwd>--/<timestamp>_<id>.jsonl` | One JSONL per session; a `session` header line, then messages and events |

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

## Under the hood

For readers who want the details. The rest of this page does not depend on
them.

### The wrapper's side

`scripts/sbxagent` works out the per-agent state folder (`AGENT_DIR`), creates
it with mode `0700`, and hands it to `sbx` twice:

```bash
sbx run --name "${SANDBOX}" -e "SBXAGENT_STATE_DIR=${AGENT_DIR}" "${KIT}" . "${AGENT_DIR}"
```

The last operand mounts the folder read-write at the same absolute path inside
the sandbox. The `-e` flag tells the kit where it is. Without
`SBXAGENT_STATE_DIR`, as with a kit started by plain `sbx run`, nothing below
runs and the agent keeps its stock trace location.

### The kit's side

Inside the sandbox, `~/.local/lib/sbxagent/mount-state.sh LINK SUBDIR` mounts
`${SBXAGENT_STATE_DIR}/SUBDIR` (call it `TARGET`) over the agent's stock trace
folder (`LINK`, for example `~/.claude/projects`). It runs as the `agent`
user, and:

1. Exits `0` at once if `SBXAGENT_STATE_DIR` is unset.
2. Runs `mkdir -p` on both `TARGET` and `LINK`. `mount --bind` needs an
   existing destination and will not create one, and the pi kit never creates
   `~/.pi/agent/sessions` itself.
3. Compares the `stat` device and inode of `LINK` and `TARGET`. If they match,
   the mount is already in place and the script exits `0`. This is the only
   "already done" check. A marker file under `SBXAGENT_STATE_DIR` would live on
   the host, outlive `sbx rm`, and make a rebuilt sandbox skip the next step.
4. Seeds `TARGET` from `LINK`: every entry in `LINK` whose name is missing from
   `TARGET` is copied over with `cp -R`. Host files win; the script never
   overwrites one. It skips `lost+found`. This single loop handles both the
   first migration and the files a rebuilt sandbox's parent kit has just
   seeded.
5. Runs `sudo -n mount --bind TARGET LINK`. From now on, writing to `LINK`
   writes to `TARGET`, which is the host folder.

Any failure after step 1 exits `1`. The entrypoint then refuses to start the
agent: traces written to an unbound `LINK` live only inside the sandbox and die
with it.

```mermaid
flowchart LR
  START(["mount-state.sh<br/>LINK SUBDIR"])
  ENV{"SBXAGENT_STATE_DIR<br/>set?"}
  MK["mkdir -p<br/>TARGET and LINK"]
  SAME{"LINK already<br/>bound to TARGET?"}
  COPY["copy entries of LINK<br/>missing from TARGET<br/>(host files win)"]
  BIND["sudo mount --bind<br/>TARGET LINK"]
  OK0(["exit 0<br/>stock location kept"])
  OK1(["exit 0<br/>nothing to do"])
  OK2(["exit 0<br/>LINK now writes<br/>to the host"])
  ERR1(["exit 1<br/>entrypoint refuses<br/>to start the agent"])

  START --> ENV
  ENV -->|"no"| OK0
  ENV -->|"yes"| MK
  MK --> SAME
  SAME -->|"yes"| OK1
  SAME -->|"no"| COPY
  COPY --> BIND
  BIND --> OK2
  MK -.->|"failed"| ERR1
  COPY -.->|"failed"| ERR1
  BIND -.->|"failed"| ERR1

  classDef step  fill:#E8F3EC,stroke:#2E7D4F,stroke-width:2px,color:#0F3D22
  classDef ask   fill:#F6F6F5,stroke:#7A8482,stroke-width:1.5px,color:#2B2F2E
  classDef ok    fill:aliceblue,stroke:steelblue,stroke-width:2px,color:#10314F
  classDef fail  fill:#FCE7E7,stroke:#B23A48,stroke-width:2px,color:#5A1015
  class START,MK,COPY,BIND step
  class ENV,SAME ask
  class OK0,OK1,OK2 ok
  class ERR1 fail
```

<br>*The same five steps as a flow. Grey diamonds are the two checks; green
boxes are the work. Blue ends are the good exits: `0` because there is no state
folder, because the mount is already in place, or because it has just been
made. Red is the one bad exit: `1` for anything that failed, after which the
entrypoint will not start the agent.*

### Two call sites

A bind mount lives in the kernel's mount table, not on disk, so every stop
drops it. Each kit calls `mount-state.sh` from two places, and needs both:

- A `setup.startup` step, which the runtime runs at every start. It covers
  sessions that never launch the agent, such as `sbxclaude exec bash`.
- The `sandbox.entrypoint` wrapper, which runs the script just before
  `exec claude "$@"` (or `codex`, `cursor-agent`, `pi`). It covers the starts
  where a startup step is known not to run: after a daemon restart
  (docker/sbx-releases #420) and when `sbx exec` wakes a stopped sandbox
  (#479).

Whichever runs first does the work. The other hits the match in step 3 and
exits `0`.

Once docker/sbx-releases #420 and #479 are fixed, the startup step alone
reaches every start, and the entrypoint call goes. The script then runs
exactly once per boot, so step 3 goes with it — nothing can be bound already —
and the flow shrinks to this:

```mermaid
flowchart LR
  START(["mount-state.sh<br/>LINK SUBDIR"])
  ENV{"SBXAGENT_STATE_DIR<br/>set?"}
  MK["mkdir -p<br/>TARGET and LINK"]
  COPY["copy entries of LINK<br/>missing from TARGET<br/>(host files win)"]
  BIND["sudo mount --bind<br/>TARGET LINK"]
  OK0(["exit 0<br/>stock location kept"])
  OK2(["exit 0<br/>LINK now writes<br/>to the host"])
  ERR1(["exit 1<br/>startup step fails"])

  START --> ENV
  ENV -->|"no"| OK0
  ENV -->|"yes"| MK
  MK --> COPY
  COPY --> BIND
  BIND --> OK2
  MK -.->|"failed"| ERR1
  COPY -.->|"failed"| ERR1
  BIND -.->|"failed"| ERR1

  classDef step  fill:#E8F3EC,stroke:#2E7D4F,stroke-width:2px,color:#0F3D22
  classDef ask   fill:#F6F6F5,stroke:#7A8482,stroke-width:1.5px,color:#2B2F2E
  classDef ok    fill:aliceblue,stroke:steelblue,stroke-width:2px,color:#10314F
  classDef fail  fill:#FCE7E7,stroke:#B23A48,stroke-width:2px,color:#5A1015
  class START,MK,COPY,BIND step
  class ENV ask
  class OK0,OK2 ok
  class ERR1 fail
```

<br>*The same script with one caller. One check, three steps, two good exits.
The "already bound" diamond and its `stat` probe are gone. So is the
entrypoint's refusal: with no entrypoint call, a failure surfaces as a failed
startup step rather than an agent that will not launch.*

### Why a bind mount, not a symlink

The parent kit mounts its own volume at `LINK`, and the runtime recreates that
mount destination at every start. It cannot do so through a symlink, so `LINK`
stays a real directory and the bind is re-made each boot.
