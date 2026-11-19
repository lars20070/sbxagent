# Published kits

Running a kit straight from the registry, without cloning this repository.

Reach for this when you want the sandbox but not this repo's wrapper: to pin
one kit version across a team, to run a kit on a machine with no checkout, or
to layer your own kit on top of one of these. You get the kit — the toolchain,
network policy, credentials and agent instructions — but not the wrapper, so
you get no per-project sandbox naming and none of the `sbx<agent>` subcommands.

You need the `sbx` CLI installed and signed in. See
[Install sbx](../README.md#install-sbx).

Every release publishes the four kits to GitHub Container Registry as OCI
artifacts, one package per kit, named after the command it corresponds to.
Each is a *mixin*: it does not run on its own, but stacks on Docker's
published kit for its agent (the *workload*), which `sbx` fetches from
`docker.io`:

| Package | Equivalent to | Stacks on |
| --- | --- | --- |
| `ghcr.io/lars20070/sbxclaude` | `sbxclaude` | `claude` |
| `ghcr.io/lars20070/sbxcodex` | `sbxcodex` | `codex` |
| `ghcr.io/lars20070/sbxcursor` | `sbxcursor` | `cursor` |
| `ghcr.io/lars20070/sbxpi` | `sbxpi` | `docker.io/sbx/pi` |

These need `sbx` v0.54.0. On v0.50.0, use the last release built for it,
`0.4.14`, which runs on its own as `sbx run ghcr.io/lars20070/sbxclaude:0.4.14`.

Every command below writes `<version>` for the release you want. The newest is
on the repository's releases page, and the `latest` tag always points at it.

> **Ignore the `docker pull` command on the GitHub package page.** A kit is an
> OCI artifact, not a container image, and `sbx` fetches it itself. The page
> also offers a `sha256-<digest>` tag, which is not the kit at all: GHCR does
> not implement the OCI referrers API, so the signature and provenance are
> parked under that tag instead. Pulling it gets you the attestations and no
> kit. The real tags are the version and `latest`.

## 1. Allow the source, then read the kit

A kit's install commands run as root inside the sandbox, so `sbx` loads kits
only from sources you have allow-listed by prefix. This one is not on the
default list, so allow it first or nothing below will load. Once per host:

```bash
sbx settings set kit.allowedSources '["docker.io/","ghcr.io/lars20070/"]'
```

Then check the kit is readable:

```bash
sbx kit inspect ghcr.io/lars20070/sbxclaude:<version>
```

It should print the kit's descriptor. The packages are public, so no registry
credentials are needed. A **kit-source error** here means the allow-list step
above did not take.

## 2. Check the signature

Allow-listing a source says you trust the publisher. Checking the signature
says the artifact really came from them. Every artifact is signed keyless
through GitHub Actions and carries a SLSA provenance attestation, and both are
worth checking before you run anyone's kit.

```bash
sbx kit provenance  ghcr.io/lars20070/sbxclaude:<version>
sbx kit verify      ghcr.io/lars20070/sbxclaude:<version> \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github.com/lars20070/sbxagent/'
```

The identity is what matters: it proves the artifact was built by this
repository's release workflow, not merely that somebody signed it.

## 3. Run it

`sbx run` takes the agent as its positional operand and this kit as `--kit`:

```bash
sbx run claude --kit ghcr.io/lars20070/sbxclaude:<version>
sbx run docker.io/sbx/pi --kit ghcr.io/lars20070/sbxpi:<version>
```

The kit refuses any other agent. Docker's workloads are not pinned: a new
sandbox gets the latest one, and `--pull always` fetches it even when a copy
is cached.

To try one out, use a scratch directory and name the sandbox, so it is obvious
which is which and easy to remove afterwards:

```bash
mkdir -p /tmp/kit-test && cd /tmp/kit-test
sbx run --name kit-test claude --kit ghcr.io/lars20070/sbxclaude:<version>
sbx rm kit-test
```

Each release publishes two tags: the version, which never moves, and `latest`,
re-pointed at the same digest. `latest` means "newest release" here rather than
"tip of main", because nothing publishes outside a release. Pin the version for
anything repeatable, or pin the digest to be certain:

```bash
sbx run claude --kit ghcr.io/lars20070/sbxclaude@sha256:<digest>
```

Playwright, Chromium, mermaid-cli and XeTeX are opt-in. The wrapper turns
`SBXAGENT_LITE=false` into a kit argument; without the wrapper, pass it
yourself, scoped to the kit by name:

```bash
sbx run claude --kit ghcr.io/lars20070/sbxclaude:<version> \
  --kit-arg sbxclaude.lite=false
```

## Building on a published kit

Your own mixin stacks on top with another `--kit`, which may be given more than
once:

```bash
sbx run claude --kit ghcr.io/lars20070/sbxclaude:<version> --kit ./my-extras
```

Name your mixin's descriptor after its directory (`my-extras/my-extras.yaml`),
not `spec.yaml`. Every stacked kit's descriptor is staged under
`/usr/share/sandbox/kit/<file stem>/`, so two kits with the same file name
collide.
