#!/bin/sh
# Snapshot udev properties for a USB mass-storage block device (MSD from a node).
# Used to build stable /etc/udev/rules.d rules for #225 — see README "Node MSD".
# Usage: tpi-msd-udev-snapshot.sh /dev/sdX
set -eu
dev=${1:?usage: $0 /dev/sdX}
if [ ! -b "$dev" ]; then
	echo "Not a block device: $dev" >&2
	exit 1
fi
base=$(basename "$dev")
out=/tmp/msd-udev-${base}.txt
{
	echo "### udevadm all (name=$dev) ###"
	udevadm info --query=all --name="$dev" 2>/dev/null || true
	echo
	echo "### udevadm property (filtered) ###"
	udevadm info --query=property --name="$dev" 2>/dev/null | grep -E '^(DEVNAME|DEVPATH|ID_|SUBSYSTEM|MAJOR|MINOR)=' || true
} | tee "$out"
echo "Wrote $out" >&2
