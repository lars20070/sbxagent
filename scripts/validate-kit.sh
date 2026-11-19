#!/usr/bin/env bash
# Build one schema v3 kit directory and check the result.
#
#   usage: scripts/validate-kit.sh KIT_DIR [PLATFORMS]
#
# KIT_DIR holds <name>.yaml (the descriptor, named after the directory) and,
# optionally, <name>.dockerfile. sbx v0.54.0 cannot check a v3 source kit
# without its daemon, so this builds the kit with Docker Buildx into a
# throwaway OCI layout and checks that with kit-tck, which needs no daemon.
# Neither step sees how kits compose; that is a host check (AGENTS.md).
#
# PLATFORMS is a Buildx platform list, default the builder's own. Building
# both linux/amd64 and linux/arm64 needs QEMU (or a multi-node builder).
set -euo pipefail

SELF="$(basename "$0")"

die() {
	echo "${SELF}: $*" >&2
	exit 1
}

[[ "$#" -ge 1 && "$#" -le 2 ]] || die "usage: ${SELF} KIT_DIR [PLATFORMS]"
kit_dir="${1%/}"
platforms="${2:-}"
name="$(basename "${kit_dir}")"
descriptor="${kit_dir}/${name}.yaml"
[[ -f "${descriptor}" ]] || die "no kit descriptor at ${descriptor}"

command -v docker >/dev/null 2>&1 || die "docker is required (with Buildx)"
command -v kit-tck >/dev/null 2>&1 ||
	die "kit-tck is required: https://github.com/docker/sandbox-kit-spec/releases/tag/v3.0.0-m.12"

layout="$(mktemp -d)"
trap 'rm -rf "${layout}"' EXIT

# tar=false writes an OCI layout directory; name= tags its one entry
# "latest", which is what kit-tck resolves.
docker buildx build --quiet \
	${platforms:+--platform "${platforms}"} \
	-f "${descriptor}" \
	--output "type=oci,dest=${layout},tar=false,name=${name}" \
	"${kit_dir}" >/dev/null
kit-tck validate --layout "${layout}" latest
