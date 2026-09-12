#!/bin/sh
# Point an agent's trace folder at this sandbox's state mount.
# Usage: sh link-state.sh LINK SUBDIR
#   LINK    the agent's stock trace folder, e.g. ~/.codex/sessions
#   SUBDIR  the folder under $SBXAGENT_STATE_DIR to link it to
# No-op without SBXAGENT_STATE_DIR, so a sandbox created by plain `sbx run`
# keeps the agent's default location. Idempotent. The only migration it
# knows is a real directory at LINK (the cursor parent kit seeds files
# there): its contents are copied into the target, the sandbox's copy
# winning on a name clash, and the directory is renamed aside until the
# symlink exists, so a failure leaves the stock location intact.
set -eu
[ -n "${SBXAGENT_STATE_DIR:-}" ] || exit 0
link="$1"
target="${SBXAGENT_STATE_DIR}/$2"

if [ -L "${link}" ]; then
	current="$(readlink "${link}")"
	if [ "${current}" = "${target}" ]; then
		exit 0
	fi
	echo "link-state: ${link} is already a symlink to ${current}, not ${target}; left untouched" >&2
	exit 1
fi

mkdir -p "${target}"
if [ -d "${link}" ]; then
	aside="${link}.sbxagent-aside"
	if [ -e "${aside}" ]; then
		echo "link-state: ${aside} exists from an earlier interrupted run; remove it by hand. ${link} left untouched" >&2
		exit 1
	fi
	if ! cp -R "${link}"/. "${target}"/; then
		echo "link-state: could not copy ${link} into ${target}; ${link} left untouched" >&2
		exit 1
	fi
	mv "${link}" "${aside}"
	if ! ln -s "${target}" "${link}"; then
		mv "${aside}" "${link}"
		echo "link-state: could not create symlink ${link}; original directory restored" >&2
		exit 1
	fi
	rm -rf "${aside}"
	exit 0
fi

parent="$(dirname "${link}")"
mkdir -p "${parent}"
if ! ln -s "${target}" "${link}"; then
	echo "link-state: could not create symlink ${link}; nothing changed" >&2
	exit 1
fi
