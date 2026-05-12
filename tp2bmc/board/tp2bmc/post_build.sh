#!/bin/bash

set -euo pipefail
# buildroots uboot-tools are ancient. Use the one from our uboot build.
mkimage="$BUILD_DIR/uboot-*/tools/mkimage"

cd "${0%/*}"
mkdir -p $TARGET_DIR/boot/
$mkimage -A arm -T script -d boot.scr $TARGET_DIR/boot/boot.scr.uimg

cp $PWD/*.its "$BINARIES_DIR/"
cd "$BINARIES_DIR"
$mkimage -E -f "turing-pi2.its" "$TARGET_DIR/boot/turing-pi2.itb"

if [ -e ${TARGET_DIR}/etc/inittab ]; then
	grep -qE '^GS0::' ${TARGET_DIR}/etc/inittab || \
    sed -i '/GENERIC_SERIAL/a\
GS0::respawn:/sbin/getty -L ttyGS0 115200 vt100 # BMC-USB-OTG' ${TARGET_DIR}/etc/inittab
fi

# Bill of materials helper: every per-package build directory under output/build/
# (names are usually <pkg>-<upstream-version>). Present on the flashed BMC at:
#   /usr/share/doc/turing-pi-bmc/buildroot-output-build-dir-listing.txt
docdir="${TARGET_DIR}/usr/share/doc/turing-pi-bmc"
mkdir -p "${docdir}"
outdir=$(dirname "${TARGET_DIR}")
if [[ -d "${outdir}/build" ]]; then
	{
		echo "Turing Pi BMC — Buildroot output/build directory listing"
		echo "One line per directory under the Buildroot output build tree."
		echo "Typical pattern: <package-name>-<upstream-version> (see Buildroot manual)."
		echo "host-* entries are host tools; most other lines are target rootfs inputs."
		echo "Generated at rootfs image assembly."
		echo ""
		ls -1 "${outdir}/build" | LC_ALL=C sort -f
	} > "${docdir}/buildroot-output-build-dir-listing.txt"
else
	echo "No build/ directory beside TARGET_DIR (${outdir}); BOM listing skipped." \
		> "${docdir}/buildroot-output-build-dir-listing.txt"
fi

# #225: append mdev hook for stable /dev/disk/by-tpi/nodeN (UMS on 1-1.N only).
marker="mdev-tpi-msd-symlink"
mconf="${TARGET_DIR}/etc/mdev.conf"
if [ -f "${mconf}" ] && ! grep -qF "${marker}" "${mconf}"; then
	printf '\n# %s (#225)\nsd[a-z] root:disk 660 @/usr/bin/%s\n' "${marker}" "${marker}" >>"${mconf}"
fi
