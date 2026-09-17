# Plan: `.env` flag that switches the network allow list off (open internet)

## Context

Every kit bakes a static `permissions.network.allow` list into its spec, so a
sandbox can only reach npm, PyPI, GitHub, context7, etc. The user wants one
`.env` flag that turns that restriction off entirely — **off = open internet**
(confirmed with the user), on = today's behaviour. No backward compatibility
needed.

### Why not a kit arg like `lite`

`${{ kit.args.x }}` is plain text substitution of a string; there is no
conditional, so an arg cannot add or drop a YAML list entry. Every workaround
(a `**` entry gated by a sentinel value, a flow-style list stored in the arg
default, YAML anchors) is a hack.

### Why not `sbx policy allow network "**" --sandbox NAME` from the wrapper

Works today, but the rule is host-side state that outlives the sandbox: the
wrapper would have to add it on create, reconcile it on attach, and remove it
on `rm`. The wrapper becomes stateful for one toggle.

### Chosen design: a mixin kit, stacked by the wrapper

`sbx run`/`sbx create` accept `--kit <dir>` for *mixin* kits (`kind: mixin`),
and "deny rules take precedence over allow rules, including across composed
kits" — i.e. network rules compose. `**` is the documented allow-all pattern.
So:

- A tiny mixin `mixins/open-network/spec.yaml` whose only job is
  `permissions.network.allow: ["**"]`.
- The wrapper passes `--kit "${REPO}/mixins/open-network"` when the flag is
  `false`, nothing when `true`. Same "takes effect at create time; `rm` then
  recreate to change it" semantics as `SBXAGENT_LITE`.
- Lives outside `kits/` on purpose: every `kits/*/` loop in `Makefile` and
  `.github/workflows/release.yml` assumes a publishable *sandbox* kit named
  after a command (shared files check, version check, release matrix). A
  mixin is none of those. Wrapper-less users of the published kits already
  have the Docker-documented `sbx policy allow network "**"`.

Flag name: `NETWORK_ALLOWLIST` (`true` default, `false` = open), matching the
user's own wording ("switch the entire network allow list on or off"). Unlike
`SBXAGENT_LITE`, it has no `SBXAGENT_` prefix, per the user's rename request.

## Changes

### 1. New `mixins/open-network/spec.yaml`

```yaml
schemaVersion: "2"
kind: mixin
name: open-network
description: Turn the network allow list off — outbound egress is open

# Stacked by scripts/sbxagent with --kit when NETWORK_ALLOWLIST=false.
# Deny rules (org policy, local `sbx policy` denies) still win over this.
permissions:
  network:
    allow:
      - "**"

environment:
  variables:
    NETWORK_ALLOWLIST: "false"

agentInstructions:
  content: |
    ## Network
    This sandbox was created with NETWORK_ALLOWLIST=false: the
    allow list is off and outbound egress is open. A request can still be
    blocked by an organisation policy or a local deny rule — report those
    exactly as described above.
```

First implementation step is to **verify the mechanism** before touching
anything else: `sbx kit validate mixins/open-network` and
`sbx kit inspect --json mixins/open-network` must accept `kind: mixin`,
`"**"`, and (ideally) `agentInstructions`. Add `version:` only if the
validator demands it. If `"**"` is rejected in a kit allow list, stop and
report — the fallback is the wrapper-side `sbx policy` approach above.
If `agentInstructions` is not allowed in a mixin, drop that block.

### 2. `scripts/sbxagent`

- Next to `SBXAGENT_LITE` (`scripts/sbxagent:69-71`): comment + default
  `NETWORK_ALLOWLIST="${NETWORK_ALLOWLIST:-true}"`.
- In `compute_state_mounts()` (`scripts/sbxagent:127-147`), follow the
  `CROSS_SANDBOX_VISIBILITY` → `PROJECT_MOUNT` pattern: validate and derive
  an operand:

  ```bash
  case "${NETWORK_ALLOWLIST}" in
  true) NETWORK_KIT="" ;;
  false) NETWORK_KIT="${REPO}/mixins/open-network" ;;
  *) die "NETWORK_ALLOWLIST must be true or false, not '${NETWORK_ALLOWLIST}'" ;;
  esac
  ```

- Both exec lines (`scripts/sbxagent:227` run, `:263` create) gain
  `${NETWORK_KIT:+--kit "${NETWORK_KIT}"}` right after `--kit-arg
  "lite=${SBXAGENT_LITE}"`. (bash 3.2-safe: no arrays; the inner quotes are
  honoured inside `${:+}`.)
- Update the `compute_state_mounts` doc comment to mention `NETWORK_KIT`.

### 3. `Makefile`

- `validate:` gains `sbx kit validate mixins/open-network`.
- `lint:` needs no new loop — yamllint already covers tracked `*.yaml`, and
  the `kits/*/` loops must *not* see the mixin. Add any new word to
  `.cspell.json` if cspell complains.

### 4. `tests/sbxagent_test.sh`

Follow the `SBXAGENT_LITE` block (`tests/sbxagent_test.sh:538-549`) and the
`.env` block (`:556-581`):

- Default (`true`): existing `assert_log` argv strings stay valid (no
  `--kit` operand) — confirms "on" changes nothing.
- `NETWORK_ALLOWLIST=false run_claude "${WORK_B}" create` →
  `assert_log` with `\t--kit-arg\tlite=true\t--kit\t${ROOT}/mixins/open-network\t...`.
- Same for the attach/create path (`run` with `SBX_INSPECT_STATUS` = missing).
- `NETWORK_ALLOWLIST=bogus reject_without_call ... create`, and
  `name` still works with a bogus value (matches the LITE test).
- Add `NETWORK_ALLOWLIST=false` to the `.env` heredoc and assert the
  `--kit` operand appears; assert a real env var (`=true`) beats `.env`.

### 5. `tests/toolchain_test.sh`

Add a check that branches on `"${NETWORK_ALLOWLIST:-true}"` the way
`:106-156` branches on `SBXAGENT_LITE`: when `false`, `curl -sfI
https://example.com` must succeed; when `true`, it must fail with the
proxy's 403 block. (The in-sandbox `network-block.jq` guard tests are
unaffected — org-policy and local-deny blocks are still possible.)

### 6. Docs and changelog

- `.env.example`: new commented block under `SBXAGENT_LITE`:
  "false turns the network allow list off — the sandbox can reach any host
  (org-policy and local deny rules still apply). Takes effect when the
  sandbox is created. Default: true".
- `docs/setup.md` environment-variable table (`:28-49`): new row.
- `docs/toolchain.md:35`: "Network access is an allowlist, not the open
  internet" → add "unless the sandbox was created with
  `NETWORK_ALLOWLIST=false`", and note it under "Rebuild after kit
  changes" (`:110-119`) as another create-time setting.
- `SECURITY.md:30-36`: one sentence that the flag opts a sandbox out of the
  allow list.
- `AGENTS.md` repository map: add `mixins/<name>/spec.yaml` — mixin kits the
  wrapper stacks with `--kit`; not published, not commands, deliberately
  outside `kits/`.
- `CHANGELOG.md` `## [Unreleased]` → `### Added`: the flag.
- No `kits/*/spec.yaml` change is needed.

## Verification

1. `sbx kit validate mixins/open-network` and `sbx kit inspect --json
   mixins/open-network | jq '.. | objects | select(has("network")) | .network'`
   shows `{"allow":["**"]}`.
2. `make lint`, `make validate`, `make test-unit` (also
   `make test-unit BASH=/bin/bash` if a macOS bash 3.2 is at hand).
3. On the host (user runs; needs sandboxd): in a scratch project,
   `NETWORK_ALLOWLIST=false sbxclaude create`, then
   `sbxclaude policy check example.com` should report allowed and
   `sbxclaude exec curl -sI https://example.com` should return 200. Repeat
   with the default and expect a 403 / blocked verdict. `make test-toolchain`
   inside that sandbox exercises step 5.
