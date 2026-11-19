# Host Chrome access

`HOST_CHROME_ACCESS=true` lets the agent in the sandbox drive a Chrome on your
host, for example a browser that is already logged in to a job portal. It is
off by default and takes effect when the sandbox is created.

How it works: Chrome on the host listens on `127.0.0.1:9222` (the Chrome
DevTools Protocol, CDP). A network rule lets the sandbox reach it. Inside the
sandbox, `socat` forwards `localhost:9222` through the sandbox proxy, and the
Playwright MCP server (registered as `playwright`) talks CDP to it. `socat` is
needed because the agent's own `localhost` is the sandbox, not the host.

## Platform status

macOS is the verified case. Linux hosts are **unverified**: whether the
sandbox can reach a loopback-only host port there has not been confirmed yet.

## Enabling

```bash
HOST_CHROME_ACCESS=true ./scripts/sbxclaude create   # or sbxcodex, sbxcursor, sbxpi
```

The wrapper prints two commands. Run them on the host, before you attach:

1. `sbx policy allow network --sandbox <name> localhost:9222`
2. a Chrome launch line (bash/zsh syntax) with
   `--remote-debugging-port=9222` and its own `--user-data-dir`.

If you start with the plain `sbxclaude` (implicit create), run the policy
command from a second terminal. The flag is read at create time only;
re-attaching ignores it.

If Chrome is stopped or the rule is missing, the agent still starts. The
browser tools just fail until both are in place.

## One sandbox at a time

Only one sandbox can use host Chrome at a time, and only one Chrome is open
for it. A create with `HOST_CHROME_ACCESS=true` fails, before it makes
anything, when:

- another sandbox created with host Chrome still exists, running or
  stopped. The error names it:
  `host Chrome is already used by <name>; remove that sandbox first`.
- something already listens on host port 9222, usually the Chrome from an
  earlier sandbox. Quit it first.

To move host Chrome to another sandbox:

1. Quit Chrome.
2. Remove the old sandbox: `sbx<agent> rm` in its project, or `sbx rm <name>`.
3. Create the new one with `HOST_CHROME_ACCESS=true`.
4. Run the two commands it prints.

## Where the profiles live

Each project and agent gets its own Chrome profile, laid out like the
[session traces](traces.md):

```text
~/.local/state/sbxagent/browserprofiles/<project-key>/<agent>/
```

- `<project-key>` is the sandbox name without its `sbx<agent>-` prefix:
  `<slug>-<hash>`, as for traces.
- `<agent>` is the wrapper you ran: `sbxclaude`, `sbxcodex`, `sbxcursor` or
  `sbxpi`.

To find a profile, use the `name` of the **same** wrapper. A long folder name
is cut to fit the sandbox name, and the room left depends on the wrapper, so
`sbxclaude name` and `sbxpi name` can give different keys for one project:

```bash
ls ~/.local/state/sbxagent/browserprofiles/"$(sbxpi name | sed 's/^sbxpi-//')"/sbxpi
```

If you set `XDG_STATE_HOME` to an absolute path, the tree lives under
`$XDG_STATE_HOME/sbxagent/browserprofiles/` instead.

The wrapper creates both folders with mode `0700`. A profile is never mounted
into any sandbox. The wrapper refuses to run if a profile overlaps anything
it mounts, or if either folder is a symlink. Removing a sandbox leaves its
profile on disk; delete the folder by hand when you no longer need it.

## Upgrading from 0.5.0

Version 0.5.0 kept one shared profile in `~/.local/state/sbxagent/browserprofile`.
To move over:

1. Revoke the old rule:
   `sbx policy rm network --sandbox <name> --resource localhost:9222`.
2. Quit the old Chrome.
3. Remove every sandbox you created with host Chrome: `sbx<agent> rm`.
4. Create one again with `HOST_CHROME_ACCESS=true` and run the two commands
   it prints.

The new profile starts empty: no tabs, no logins. The old `browserprofile/`
folder stays until you delete it.

## Disabling

The flag is create-time only. In this order:

1. `sbx policy rm network --sandbox <name> --resource localhost:9222`
2. Stop Chrome. (A WebSocket that is already open may survive step 1.)
3. `./scripts/sbxclaude rm`
4. Create again with the flag off.

The profile folder stays on disk; delete it by hand if you want it gone.

## What you are granting

- Raw CDP, not only the MCP tools. Any process in the sandbox controls the
  whole browser profile: tabs, cookies, logins.
- The browser makes its own requests from the host, so the sandbox network
  allowlist does not limit which pages it opens.
- "Use your own tab" and "read only" are instructions to the agent, not
  enforcement.
- Each project and agent has its own profile, and only one sandbox may use
  host Chrome at a time (see [One sandbox at a time](#one-sandbox-at-a-time)).
- A sandbox created with `NETWORK_ALLOWLIST=false` may reach port 9222 even
  without the rule. The one-at-a-time check only counts sandboxes created
  with host Chrome, so it does not stop such a sandbox.
- Use a dedicated profile and close Chrome when you are done.

## Troubleshooting

- Port 9222 taken inside the sandbox: the startup hook prints
  `port 9222 is taken by something else` and leaves it alone.
- Forwarder did not start: see `~/.cache/sbxagent/host-chrome/socat.log` in the
  sandbox.
- Check from the sandbox: `curl http://localhost:9222/json/version`.
