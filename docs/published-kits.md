# Published kits

Running a kit straight from the registry, without cloning this repository.

Reach for this when you want the sandbox but not this repo's wrapper: to pin
one kit version across a team, to run a kit on a machine with no checkout, or
to layer your own kit on top of one of these. You get the kit — the toolchain,
network policy, credentials and agent instructions — but not the wrapper, so
you get no per-project sandbox naming and none of the `sbx<agent>` subcommands.

You need the `sbx` CLI installed and signed in. See
[Install](../README.md#install).

Every release publishes the four kits to GitHub Container Registry as OCI
artifacts, one package per kit, named after the command it corresponds to:

| Package | Equivalent to |
| --- | --- |
| `ghcr.io/lars20070/sbxclaude` | `sbxclaude` |
| `ghcr.io/lars20070/sbxcodex` | `sbxcodex` |
| `ghcr.io/lars20070/sbxcursor` | `sbxcursor` |
| `ghcr.io/lars20070/sbxpi` | `sbxpi` |

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

It should report `Name: sbxclaude`, `Schema: v2`, and the policy counts. The
packages are public, so no registry credentials are needed. A **kit-source
error** here means the allow-list step above did not take.

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

`sbx run` takes the kit reference as its first positional operand, and reads
the agent to launch from the kit's own spec.

```bash
sbx run ghcr.io/lars20070/sbxclaude:<version>
```

To try one out, use a scratch directory and name the sandbox, so it is obvious
which is which and easy to remove afterwards:

```bash
mkdir -p /tmp/kit-test && cd /tmp/kit-test
sbx run --name kit-test ghcr.io/lars20070/sbxclaude:<version>
sbx rm kit-test
```

Each release publishes two tags: the version, which never moves, and `latest`,
re-pointed at the same digest. `latest` means "newest release" here rather than
"tip of main", because nothing publishes outside a release. Pin the version for
anything repeatable, or pin the digest to be certain:

```bash
sbx run ghcr.io/lars20070/sbxclaude@sha256:<digest>
```

## Building on a published kit

You can **stack** kits — `--kit` is now the mixin flag, and may be given more
than once, so your own kit layers onto one of these at run time:

```bash
sbx run ghcr.io/lars20070/sbxclaude:<version> --kit ./my-extras
```

You cannot yet **derive** a kit from one. The spec has a `mixins:` field for
exactly that, but as of `sbx` v0.42.0 it is accepted and then ignored —
`sbx kit validate` says so out loud:

```text
WARN: field "mixins" is accepted but not yet implemented: mixin composition is
accepted in the schema but not yet applied by the runtime
```

So a spec that lists a mixin looks right and does nothing. Until that lands,
copy the `spec.yaml` you want to change.
