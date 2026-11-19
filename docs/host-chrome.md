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

The Chrome profile lives in `$XDG_STATE_HOME/sbxagent/browserprofile`
(default `~/.local/state/sbxagent/browserprofile`). The wrapper refuses to run
if that folder overlaps anything it mounts into the sandbox.

If Chrome is stopped or the rule is missing, the agent still starts. The
browser tools just fail until both are in place.

## Disabling

The flag is create-time only. In this order:

1. `sbx policy rm network --sandbox <name> --resource localhost:9222`
2. Stop Chrome. (A WebSocket that is already open may survive step 1.)
3. `./scripts/sbxclaude rm`
4. Create again with the flag off.

## What you are granting

- Raw CDP, not only the MCP tools. Any process in the sandbox controls the
  whole browser profile: tabs, cookies, logins.
- The browser makes its own requests from the host, so the sandbox network
  allowlist does not limit which pages it opens.
- "Use your own tab" and "read only" are instructions to the agent, not
  enforcement.
- The profile and port 9222 are shared by every sandbox that has the rule.
- A sandbox created with `NETWORK_ALLOWLIST=false` may reach port 9222 even
  without the rule.
- Use a dedicated profile and close Chrome when you are done.

## Troubleshooting

- Port 9222 taken inside the sandbox: the startup hook prints
  `port 9222 is taken by something else` and leaves it alone.
- Forwarder did not start: see `~/.cache/sbxagent/host-chrome/socat.log` in the
  sandbox.
- Check from the sandbox: `curl http://localhost:9222/json/version`.
