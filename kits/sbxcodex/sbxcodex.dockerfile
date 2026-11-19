# Content recipe for this kit's v3 descriptor (the .yaml beside it). The
# result is a mixin: one overlay layer that lands on the agent workload's
# filesystem, so it carries only what this kit adds. Package installs are not
# here — they run as install hooks against the workload's own dpkg database
# (see the descriptor). This file is byte-identical in every kit; `make lint`
# checks it. What differs between kits lives in each kit's files/ tree.

# Pinned binaries, downloaded and checksummed in a throwaway stage so neither
# Debian nor curl ends up in the mixin.
FROM debian:trixie-slim AS fetch
ARG TARGETARCH
RUN apt-get update \
	&& apt-get install -y --no-install-recommends ca-certificates curl \
	&& rm -rf /var/lib/apt/lists/*
RUN <<'FETCH'
set -eu
case "$TARGETARCH" in
amd64)
	sbx_sha256=eded29017121a857c98d4a91cad593f6a9e00f4010e830679bd385f4a5edba4d
	gms_asset=Linux_x86_64
	gms_sha256=95843162759da2c31dde082dd145be35db82164594796c294414b69790c2290e
	tck_sha256=473b72d7bb48b11987250493e9b47fb2c616de601777e139191a86fc5e962f21
	;;
arm64)
	sbx_sha256=40498341fd6b7f67d8f6ff4b1a17c73f516811fc6184a3bd554f9b3442a91115
	gms_asset=Linux_arm64
	gms_sha256=2b30f9fcc061b57456cbe38ddc0f13c88863bad49557508a9196f2d1c4cb17a5
	tck_sha256=1ffbd3a5240e0abe9a930f9fb5549ff515cbda768f7c1190cca85fd0c91c1af3
	;;
*)
	echo "unsupported architecture: $TARGETARCH" >&2
	exit 1
	;;
esac
fetch() {
	curl -fsSL --retry 3 --retry-delay 2 --max-time 600 "$1" -o "$2"
	actual="$(sha256sum "$2" | cut -d' ' -f1)"
	if [ "$actual" != "$3" ]; then
		echo "checksum mismatch for $1: got ${actual}, want $3" >&2
		exit 1
	fi
}
mkdir -p /tmp/dl /out/usr/local/bin
cd /tmp/dl
# sbx CLI v0.54.0, for daemon-free commands inside the sandbox.
fetch "https://github.com/docker/sbx-releases/releases/download/v0.54.0/DockerSandboxes-linux-${TARGETARCH}.tar.gz" \
	sbx.tar.gz "$sbx_sha256"
tar xzf sbx.tar.gz docker-sbx/sbx
install -m 0755 docker-sbx/sbx /out/usr/local/bin/sbx
# GitHub MCP server v1.12.2, run locally over stdio.
fetch "https://github.com/github/github-mcp-server/releases/download/v1.12.2/github-mcp-server_${gms_asset}.tar.gz" \
	gms.tar.gz "$gms_sha256"
tar xzf gms.tar.gz github-mcp-server
install -m 0755 github-mcp-server /out/usr/local/bin/github-mcp-server
# kit-tck v3.0.0-m.12, which checks a built v3 kit without a daemon.
fetch "https://github.com/docker/sandbox-kit-spec/releases/download/v3.0.0-m.12/kit-tck_3.0.0-m.12_linux_${TARGETARCH}.tar.gz" \
	tck.tar.gz "$tck_sha256"
tar xzf tck.tar.gz kit-tck
install -m 0755 kit-tck /out/usr/local/bin/kit-tck
FETCH

# Assemble the overlay here, with explicit owners. A mixin's directory entries
# replace the base's, owner included, so /home must stay root's and
# /home/agent the agent's (SPEC-v3 §10; kit-tck checks it).
COPY files/ /src/
RUN <<'ASSEMBLE'
set -eu
# Root-owned and outside $HOME, so the agent cannot disable a guard with an
# ordinary file edit. Not every kit has system files.
[ ! -d /src/system ] || cp -R /src/system/. /out/
install -d -o 0 -g 0 -m 0755 /out/home
install -d -o 1000 -g 1000 -m 0755 /out/home/agent
cp -R /src/home/. /out/home/agent/
chown -R 1000:1000 /out/home/agent
# Staged, not copied into place: an install hook adds it to the workspace only
# when the project has none of its own.
install -d -m 0755 /out/usr/local/share/sbxagent/workspace
cp -R /src/workspace/. /out/usr/local/share/sbxagent/workspace/
ASSEMBLE

FROM scratch
COPY --from=fetch /out/ /
