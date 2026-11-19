#!/usr/bin/env bash
# Build one schema v3 kit directory and check the result.
#
#   usage: scripts/validate-kit.sh KIT_DIR [PLATFORMS] [LAYOUT_DIR]
#
# KIT_DIR holds <name>.yaml (the descriptor, named after the directory) and,
# optionally, <name>.dockerfile. sbx v0.54.0 cannot check a v3 source kit
# without its daemon, so this builds the kit with Docker Buildx into a
# throwaway OCI layout and checks that with kit-tck, which needs no daemon.
# Neither step sees how kits compose; that is a host check (AGENTS.md).
#
# PLATFORMS is a Buildx platform list, default the builder's own. Building
# both linux/amd64 and linux/arm64 needs QEMU (or a multi-node builder).
#
# LAYOUT_DIR, when given, keeps the checked build there instead of throwing it
# away; it must not exist yet. scripts/publish-kit.sh uploads exactly that
# layout, so the bytes it publishes are the bytes kit-tck accepted. That is
# also why every build option lives here and nowhere else: a publish that
# rebuilt with different options would ship something this never checked.
set -euo pipefail

SELF="$(basename "$0")"

die() {
	echo "${SELF}: $*" >&2
	exit 1
}

[[ "$#" -ge 1 && "$#" -le 3 ]] || die "usage: ${SELF} KIT_DIR [PLATFORMS] [LAYOUT_DIR]"
kit_dir="${1%/}"
platforms="${2:-}"
keep="${3:-}"
name="$(basename "${kit_dir}")"
descriptor="${kit_dir}/${name}.yaml"
[[ -f "${descriptor}" ]] || die "no kit descriptor at ${descriptor}"

command -v docker >/dev/null 2>&1 || die "docker is required (with Buildx)"
command -v kit-tck >/dev/null 2>&1 ||
	die "kit-tck is required: https://github.com/docker/sandbox-kit-spec/releases/tag/v3.0.0-m.12"

if [[ -n "${keep}" ]]; then
	[[ ! -e "${keep}" ]] || die "${keep} already exists"
	layout="${keep}"
else
	layout="$(mktemp -d)"
	trap 'rm -rf "${layout}"' EXIT
fi

# tar=false writes an OCI layout directory; name= tags its one entry
# "latest", which is what kit-tck resolves. Provenance is requested
# explicitly: SPEC-v3 §9.3 promotes the kit annotations onto the index only
# then, and the published kit carries it. No --annotation of our own: the
# frontend derives the org.opencontainers.image.* keys from the descriptor,
# and adding one it deliberately omits, such as revision, fails §9.3.
docker buildx build --quiet \
	${platforms:+--platform "${platforms}"} \
	--provenance=mode=max \
	-f "${descriptor}" \
	--output "type=oci,dest=${layout},tar=false,name=${name}" \
	"${kit_dir}" >/dev/null
kit-tck validate --layout "${layout}" latest
