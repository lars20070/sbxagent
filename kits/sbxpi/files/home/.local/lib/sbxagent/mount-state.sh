#!/bin/sh
# Relocate an agent's trace folder onto this sandbox's state mount.
# Usage: sh mount-state.sh LINK SUBDIR
#   LINK    the agent's stock trace folder, e.g. ~/.codex/sessions
#   SUBDIR  the folder under $SBXAGENT_STATE_DIR to relocate it onto
#
# A bind mount, not a symlink. An earlier version replaced LINK with a symlink
# and left the sandbox unable to restart: the parent claude kit provisions
# ~/.claude/projects as its own volume, and the runtime recreates that mount
# destination on every start. It refuses to do so through a symlink, failing
# with "No such file or directory", which surfaces to the user only as
# "failed to start runtime: 500 Internal Server Error". Keeping LINK a real
# directory keeps it a valid mount destination for the life of the sandbox.
#
# The trade is that a mount does not persist the way a symlink did, so this has
# to run on every boot rather than once ever. It is idempotent: once bound,
# LINK and TARGET are the same directory and it exits 0 having touched nothing.
#
# No-op without SBXAGENT_STATE_DIR, so a sandbox created by plain `sbx run`
# keeps the agent's default location. With it set, every failure is fatal and
# the caller must refuse to start the agent: traces written to an unbound LINK
# live only inside the sandbox and die with it, and no later boot would find
# them to migrate.
set -eu
[ -n "${SBXAGENT_STATE_DIR:-}" ] || exit 0
link="$1"
target="${SBXAGENT_STATE_DIR}/$2"

# Matching device and inode means LINK is already bound to TARGET. This is the
# sole idempotency signal, deliberately not a marker file: a marker under
# SBXAGENT_STATE_DIR is host-persisted, so it outlives `sbx rm` and would make a
# rebuilt sandbox skip merging in the files its parent kit had just seeded.
#
# GNU-then-BSD probe, the same shape as scripts/sbxagent's shasum/sha256sum
# fallback. In production this only ever runs on Linux, but
# tests/mount_state_test.sh runs it directly on the developer's machine, macOS
# included.
same_fs() {
	one="$(stat -c '%d:%i' "$1" 2>/dev/null || stat -f '%d:%i' "$1" 2>/dev/null)"
	two="$(stat -c '%d:%i' "$2" 2>/dev/null || stat -f '%d:%i' "$2" 2>/dev/null)"
	[ -n "${one}" ] && [ "${one}" = "${two}" ]
}

if [ -L "${link}" ]; then
	echo "mount-state: ${link} is a symlink; this design needs it to stay a real directory. Remove and recreate the sandbox" >&2
	exit 2
fi

mkdir -p "${target}" || {
	echo "mount-state: could not create ${target}" >&2
	exit 1
}
# LINK too, not just TARGET: `mount --bind` needs an existing destination and
# will not create one, and a fresh sandbox may have neither the trace directory
# nor its parents (the pi kit never provisions ~/.pi/agent/sessions). A no-op
# when LINK already exists, including as the parent kit's mounted volume, so it
# never touches the ownership or contents of something already there.
mkdir -p "${link}" || {
	echo "mount-state: could not create ${link}" >&2
	exit 1
}

# shellcheck disable=SC2310 # A false answer here is the normal "not yet bound"
# result, not an error to propagate under set -e.
if same_fs "${link}" "${target}"; then
	exit 0
fi

# Host state is authoritative: fill in only the names it does not already have,
# and never overwrite an existing host entry with whatever is presently sitting
# at LINK -- a freshly re-provisioned parent volume, or a rebuilt sandbox's
# newly seeded files. This one loop, on every un-bound boot, covers both the
# first-ever migration and a later rebuild's new seed files, with no need for a
# marker: once bound, LINK's own view is TARGET, so the loop is unreachable and
# can never copy stale content back over live writes.
for entry in "${link}"/.[!.]* "${link}"/..?* "${link}"/*; do
	[ -e "${entry}" ] || continue
	name="$(basename "${entry}")"
	# A fresh ext4 filesystem's reserved lost+found is root-owned and
	# unreadable by the unprivileged agent user; skip it by name rather than
	# let one unreadable entry fail the whole copy.
	[ "${name}" = "lost+found" ] && continue
	[ -e "${target}/${name}" ] && continue
	if ! cp -R "${entry}" "${target}/"; then
		echo "mount-state: could not copy ${link}/${name} into ${target}" >&2
		exit 1
	fi
done

if ! sudo -n mount --bind "${target}" "${link}"; then
	echo "mount-state: could not bind-mount ${target} onto ${link}" >&2
	exit 1
fi
