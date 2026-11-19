# Per-sandbox Chrome profiles, one host-Chrome sandbox at a time

## Context

Today every sandbox shares one Chrome profile
(`~/.local/state/sbxagent/browserprofile`) on host port 9222. The user wants:

1. One profile per project and agent, like traces:

   ```text
   ~/.local/state/sbxagent/browserprofiles/<project-key>/<agent>/
   ```

2. Only **one** host Chrome open, connected to **one** sandbox, at any time.
   Creating a second sandbox with `HOST_CHROME_ACCESS=true` fails while
   another host-Chrome sandbox still exists (running or stopped). The user
   frees it with `sbx<agent> rm` on the old one.

Port stays 9222 everywhere. No per-agent ports, no mixin change.

`<project-key>` is the sandbox name minus its `sbx<agent>-` prefix, same as
traces. For long folder names the slug is cut to fit the sandbox name, so
the key can differ between agents (`scripts/sbxagent:346-372`).

## Step 0: learn the `sbx inspect` JSON shape

The sandbox here is not signed in to `sbx`, so I cannot see the output.
Before coding the check, ask the user to run on the host, against a sandbox
created with `HOST_CHROME_ACCESS=true`:

```bash
sbx ls -q
sbx inspect <that-sandbox> --format json
```

Use the real field that lists the stacked kits. Match the host-chrome
mixin by a fixed string (its kit name / path), with `grep -F`, so the
wrapper needs no `jq` on the host. Mirror that exact shape in the fake
`sbx`.

## Changes

### `scripts/sbxagent`

- `compute_state_mounts()`, `HOST_CHROME_ACCESS=true` branch (`:171-181`):
  `BROWSER_PROFILE_PROJECT=<state>/sbxagent/browserprofiles/${SLUG:+${SLUG}-}${HASH}`
  and `BROWSER_PROFILE=${BROWSER_PROFILE_PROJECT}/${SELF}`. Keep the
  `XDG_STATE_HOME` absolute/fallback `case`.
- New `require_no_other_host_chrome()`, called inside
  `compute_state_mounts()` when `HOST_CHROME_KIT` is set, right after the
  toggle `case` blocks and **before the first `mkdir`** (`:182`). So a
  refused second create leaves no trace, message-board or profile folder
  behind (review 2 #3). `compute_state_mounts` only runs on the two create
  paths (`:380`, `:422`), after `require_sbx`, so `sbx` is there.
  - `sbx ls -q`, then `sbx inspect <name> --format json` for each name other
    than `${SANDBOX}`. If one has the host-chrome mixin, `die` naming it:
    `host Chrome is already used by <name>; remove it first (sbx rm <name>)`.
  - Fail closed: if `sbx ls` or an `inspect` fails, `die` too.
  - Also `die` if something already answers on host `127.0.0.1:9222`
    (bash `/dev/tcp` probe, no `curl` needed): a Chrome from an earlier
    session is still open. Message: quit that Chrome first. The probe port
    is read from an internal, undocumented `SBXAGENT_CHROME_PROBE_PORT`
    (default 9222) so the unit tests never touch the real 9222.
  - Reattach is not checked. The flag is create-time only, and the create
    check keeps at most one host-Chrome sandbox in existence.
- Profile guard (`:196-198`, `check_profile_outside_mounts` `:237-246`), in
  this order (review #2):
  1. Reject if `BROWSER_PROFILE_PROJECT` or `BROWSER_PROFILE` is a symlink
     (`[[ -L ]]`), dangling or not.
  2. Existing physical-path overlap check on the leaf.
  3. Only then `mkdir -p` + `chmod 700` on both folders. A path the guard
     rejects leaves no profile folder behind. (Trace and message-board
     folders are still made before this guard, as today: the guard needs
     them to exist to resolve symlinks into them. The promise is scoped to
     the profile folders.)
- `print_host_chrome_steps` (`:251-278`): unchanged except it now prints the
  per-sandbox `BROWSER_PROFILE`.
- Update the header comment (`:122-139`) and the toggle comment (`:72-76`).

### Tests

`tests/sbxagent_test.sh` (`:656-789`, fake `sbx` near `:196-203`):

- Test setup: `unset HOST_CHROME_ACCESS` next to where the suite already
  isolates its environment, so a run inside a host-Chrome sandbox (like
  this one, where it is `true`) does not leak in (review 2 #2).
- Export `SBXAGENT_CHROME_PROBE_PORT` once for the whole suite, set to a
  free high port nobody listens on. Every Chrome-enabled case uses it, so
  the in-sandbox forwarder on 9222 can never fail them. Start a listener
  on it only inside the occupied-port test, and stop it after.
- Fake `sbx`: add `ls -q` (names from an env var) and `inspect --format
  json` (per-name JSON in the Step 0 shape, or a failure).
- Exclusivity:
  - Another sandbox with the host-chrome mixin exists → create fails, no
    `sbx create`/`run` logged. Explicit and implicit create.
  - Other sandboxes exist without the mixin → create succeeds.
  - `sbx ls` or `inspect` fails → create fails (fail closed).
  - Listener on the probe port → create fails, no `sbx` call.
  - Each refused create (other sandbox, busy port, failed `sbx ls`) leaves
    no new folder under `traces/`, `messageboards/` or `browserprofiles/`
    (snapshot with `find … -ls` before and after).
  - `HOST_CHROME_ACCESS=false` create never runs the check.
- Profiles:
  - Full printed `--user-data-dir` per agent:
    `.../browserprofiles/<key>/sbx<agent>`.
  - Two projects with the **same basename** in different parents, same
    agent: different profile paths (exercises the hash).
  - Mode 0700 on both the `<project-key>` and `<agent>` folders.
- Guard: symlinked `<project-key>` folder; `<agent>` folder aliased to a
  sibling profile; the existing dangling-link case moved to the new path.
  For each rejection, snapshot the `browserprofiles` tree (`find … -ls`)
  before and after and assert it is unchanged, plus no `sbx` call. Widen
  `guard_rejects`' accepted error text for the new symlink message.
- Fix old-path assertions at `:723`, `:731`, `:737`, `:783`.

`tests/toolchain_test.sh`: no change (port and forwarder are unchanged).

### `README.md`

- Mermaid `STATE` node (`:23`), `CHROME` node (`:38`), caption (`:68`):
  profiles live in `~/.local/state/sbxagent/browserprofiles`, one per
  project and agent; one host-Chrome sandbox at a time.

### Docs

- `docs/host-chrome.md`:
  - New profile path with the `<project-key>/<agent>/` breakdown. Find it
    with the **matching** wrapper's `name` (`sbxpi name` for Pi, …), not
    `sbxclaude name` (review #4).
  - One at a time: what fails, the error, and how to switch: quit Chrome,
    `sbx<agent> rm` the old sandbox, create the new one, run its printed
    lines.
  - What you are granting (`:50-61`): replace "profile and port shared by
    every sandbox" with the one-at-a-time rule. Keep the caveat that a
    sandbox created with `NETWORK_ALLOWLIST=false` may reach 9222 without
    the rule, and that the check does not cover such sandboxes (review #1).
  - Disabling (`:41-48`): `rm` leaves the profile folder; delete it by hand.
  - Upgrading from 0.5.0 (review #3): revoke the old `localhost:9222` rule,
    quit the old Chrome, `rm` every old host-Chrome sandbox, re-create one
    with `HOST_CHROME_ACCESS=true`, run the newly printed lines. The new
    profile starts with no tabs or logins. The old `browserprofile/` folder
    stays until you delete it.
- `SECURITY.md` (`:36-41`): per-project, per-agent profiles; one host-Chrome
  sandbox at a time; the `NETWORK_ALLOWLIST=false` caveat.
- `docs/toolchain.md` (`:24-38`): add the sibling
  `browserprofiles/<project-key>/<agent>/`, never mounted.
- `docs/setup.md`: `XDG_STATE_HOME` row (`:56`) → "per-project, per-agent
  Chrome profiles"; `HOST_CHROME_ACCESS` row (`:60`) → one sandbox at a time.
- `.env.example` (`:38-47`): same wording changes.

### Agent instructions

- `AGENTS.md` Repository Map:
  - `mixins/` bullet says "There is one: `mixins/open-network`". Add
    `mixins/host-chrome`, stacked when `HOST_CHROME_ACCESS=true`, with its
    `agent` kit arg.
  - `args:` bullet says "`SBXAGENT_LITE` → `lite` is the only toggle
    today". Add `host-chrome.agent`.
  - Note: the profile lives in `browserprofiles/<project-key>/<agent>/` and
    must never be mounted (`check_profile_outside_mounts`); only one
    host-Chrome sandbox may exist (`require_no_other_host_chrome`).
- In-sandbox instructions (`kits/*/` descriptors, the mixin) never mention
  the profile or exclusivity. No change. Checked with grep.

### Other

- `CHANGELOG.md` `## [Unreleased]` → `### Changed`: profile path, one per
  project and agent; create fails while another host-Chrome sandbox exists
  or a Chrome already listens on 9222; upgrade steps link to
  `docs/host-chrome.md`.
- `.cspell.json`: replace `browserprofile` with `browserprofiles` if the old
  word is gone everywhere, else add it.

## Verification

In the sandbox:

```bash
unset SBXAGENT_LITE NETWORK_ALLOWLIST
make lint
make test-unit
```

Nothing under `kits/` or `mixins/` changes, so `make validate` is not needed.

On the host (the user runs these; needs `sbx`):

```bash
./scripts/sbxclaude rm
HOST_CHROME_ACCESS=true ./scripts/sbxclaude create     # works, prints new profile path
HOST_CHROME_ACCESS=true ./scripts/sbxcodex create      # must fail, names sbxclaude-…
./scripts/sbxclaude rm
HOST_CHROME_ACCESS=true ./scripts/sbxcodex create      # works now
```

Run the printed rule and Chrome line, then:

```bash
EXPECTED_HOST_CHROME_ACCESS=live make test-toolchain AGENT=codex
```

Then test the port probe **on its own** (review 2 #1). Leave Chrome open,
but remove the Codex sandbox and its rule, so the sandbox check cannot be
what fails:

```bash
sbx policy rm network --sandbox <codex-sandbox> --resource localhost:9222
./scripts/sbxcodex rm
HOST_CHROME_ACCESS=true ./scripts/sbxclaude create     # must fail: port 9222 busy
# quit Chrome
HOST_CHROME_ACCESS=true ./scripts/sbxclaude create     # works now
```

Stage changes and draft a commit message. Do not commit.
