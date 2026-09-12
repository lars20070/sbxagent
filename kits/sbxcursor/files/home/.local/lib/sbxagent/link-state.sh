#!/bin/sh
# Point an agent's trace folder at this sandbox's state mount.
# Usage: sh link-state.sh LINK SUBDIR
#   LINK    the agent's stock trace folder, e.g. ~/.codex/sessions
#   SUBDIR  the folder under $SBXAGENT_STATE_DIR to link it to
# No-op without SBXAGENT_STATE_DIR, so a sandbox created by plain `sbx run`
# keeps the agent's default location. Idempotent. Migrates two kinds of
# pre-existing LINK: a real directory (the cursor parent kit seeds files
# there) and a separate mount (the claude parent kit provisions
# ~/.claude/projects as its own volume for chat-history persistence, so a
# plain `mv` on it always fails with EBUSY). A mount is copied out and
# unmounted first, which turns it into an ordinary directory; either way,
# contents are copied into the target first, the most-recently-copied
# version winning on a name clash, before anything destructive happens.
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

aside="${link}.sbxagent-aside"
if [ -d "${link}" ] && { [ -e "${aside}" ] || [ -L "${aside}" ]; }; then
	echo "link-state: ${aside} exists from an earlier interrupted run; remove it by hand. ${link} left untouched" >&2
	exit 1
fi

unmounted=""
renamed=""
fail_migration() {
	if [ -n "${renamed}" ] && ! mv "${aside}" "${link}"; then
		echo "link-state: $1; could not restore ${aside} to ${link}; copied contents remain in ${target}" >&2
		exit 1
	fi
	# After unmounting, the directory at LINK holds the underlying contents.
	# Restore the saved traces on every later failure, even before a rename.
	if [ -n "${unmounted}" ]; then
		if ! cp -R "${target}"/. "${link}"/; then
			echo "link-state: $1; could not restore the unmounted traces at ${link}; copied contents remain in ${target}" >&2
			exit 1
		fi
		echo "link-state: $1; traces restored at ${link}" >&2
	elif [ -n "${renamed}" ]; then
		echo "link-state: $1; original directory restored" >&2
	else
		echo "link-state: $1; ${link} left untouched" >&2
	fi
	exit 1
}

mkdir -p "${target}"
if command -v mountpoint >/dev/null 2>&1 && mountpoint -q "${link}"; then
	# A separate mount can never be mv'd aside (EBUSY: "Device or resource
	# busy"). Copy its contents out and unmount it first; whatever remains
	# at LINK afterward (normally nothing) is then migrated exactly like an
	# ordinary directory below, under the same collision policy.
	for entry in "${link}"/.[!.]* "${link}"/..?* "${link}"/*; do
		[ -e "${entry}" ] || continue
		# A fresh ext4 filesystem's reserved lost+found is root-owned and
		# unreadable by the unprivileged agent user; skip it by name rather
		# than let one unreadable entry fail the whole copy.
		[ "$(basename "${entry}")" = "lost+found" ] && continue
		if ! cp -R "${entry}" "${target}/"; then
			echo "link-state: could not copy ${link} into ${target}; ${link} left mounted and untouched" >&2
			exit 1
		fi
	done
	if ! sudo -n umount "${link}"; then
		echo "link-state: could not unmount ${link}; left mounted and untouched" >&2
		exit 1
	fi
	unmounted=1
fi

if [ -d "${link}" ]; then
	if ! cp -R "${link}"/. "${target}"/; then
		fail_migration "could not copy ${link} into ${target}"
	fi
	if ! mv "${link}" "${aside}"; then
		fail_migration "could not move ${link} aside"
	fi
	renamed=1
	if ! ln -s "${target}" "${link}"; then
		fail_migration "could not create symlink ${link}"
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
