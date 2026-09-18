# Message board

One shared folder per project that every agent's sandbox can read and write,
so sibling agents working the same project have somewhere to leave notes for
each other. See [traces.md](traces.md) for the session traces that live
alongside it, and [toolchain.md](toolchain.md) for the state folder both sit
in.

## Contents

- [Where the message board lives](#where-the-message-board-lives)
- [How it differs from session traces](#how-it-differs-from-session-traces)
- [Turning it off](#turning-it-off)
- [Nothing writes to it yet](#nothing-writes-to-it-yet)

## Where the message board lives

```text
~/.local/state/sbxagent/messageboards/<slug>-<hash>/
```

- `<slug>` is the name of your project folder. Anything that is not a letter,
  digit or dash becomes a dash.
- `<hash>` is the first 8 characters of a SHA-256 of the project's full path.
  Two projects with the same folder name still get different folders.

That is the same `<slug>-<hash>` key the trace folder uses, so the two trees
sit side by side:

```text
~/.local/state/sbxagent
├── traces
│   └── weather-app-3f9a1c2e
│       ├── sbxclaude
│       ├── sbxcodex
│       ├── sbxcursor
│       └── sbxpi
└── messageboards
    └── weather-app-3f9a1c2e      ← one folder, no per-agent subfolders
```

The wrapper mounts that folder **read-write at the same absolute path inside
the sandbox**. So a sandbox created from `~/Code/weather-app` on a machine
where `$HOME` is `/Users/you` reaches the board at
`/Users/you/.local/state/sbxagent/messageboards/weather-app-3f9a1c2e`, and a
file written there is on the host at once.

You do not have to work the path out. In your project, run `sbxclaude name`
(or the matching command for another agent). It prints
`sbxclaude-<slug>-<hash>`; drop the `sbxclaude-` prefix and you have the
folder:

```bash
cd ~/.local/state/sbxagent/messageboards/"$(sbxclaude name | sed 's/^sbxclaude-//')"
```

If you set `XDG_STATE_HOME` to an absolute path, the tree lives under
`$XDG_STATE_HOME/sbxagent/messageboards/` instead.

## How it differs from session traces

Both are wrapper-managed host folders keyed by the project, but they are
mounted for different reasons:

| | Session traces | Message board |
| --- | --- | --- |
| Layout | A subfolder per agent (`sbxclaude/`, `sbxcodex/`, …) | One folder, no subfolders |
| Who can write | Only the agent that owns the subfolder | Every agent's sandbox for the project |
| Who can read siblings | Yes, read-only | Yes, the same folder |
| How it is mounted | Bind-mounted over the agent's own session directory by `mount-state.sh` inside the kit | Mounted directly by the wrapper; no kit-side script |
| Written by | The agent, automatically | Nobody yet — see below |

The message board needs no `mount-state.sh` equivalent because there is no
pre-existing agent-native directory to relocate: the folder is new, so the
wrapper simply passes it to `sbx` as another mount operand.

## Turning it off

The board is gated by the same create-time `CROSS_SANDBOX_VISIBILITY` setting
that controls sibling trace visibility (see
[traces.md](traces.md#cross-sandbox-visibility)). With the default
`CROSS_SANDBOX_VISIBILITY=true` the folder is created and mounted. Set
`CROSS_SANDBOX_VISIBILITY=false` before creating a sandbox and that sandbox
gets neither — no sibling traces, and no message board.

That only holds back a **new** sandbox. It does not delete a message board an
earlier sandbox already created on the host; the folder stays where it is and
comes back the next time a sandbox is created with visibility on. Like the
other create-time settings, changing it means removing and rebuilding the
sandbox before it takes effect.

Everything on the board is plain, unencrypted files that any sandbox for this
project can read and overwrite. Do not put anything there you would not want a
sibling agent to see.

## Nothing writes to it yet

This is the mount only. No agent, skill or script posts to the board today —
the `/read-message-board` and `/write-message-board` skills in
[README.md](../README.md)'s architecture diagram are still to be built. Until
then the folder is yours to use by hand.
