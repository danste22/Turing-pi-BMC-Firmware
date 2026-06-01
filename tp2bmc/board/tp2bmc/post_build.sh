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

# Logging: only Buildroot S01syslogd + S02klogd (/etc/default/syslogd for -R).
rm -f "${TARGET_DIR}/etc/init.d/S01syslog"

BOARD_DIR="${0%/*}"
# Overlay checkout may drop +x; rcS execs init scripts — must be 755 on erofs.
find "${BOARD_DIR}/overlay/etc/init.d" -maxdepth 1 -name 'S*' -exec chmod 755 {} +
find "${TARGET_DIR}/etc/init.d" -maxdepth 1 -name 'S*' -exec chmod 755 {} + 2>/dev/null || true

# Factory MAC helpers (overlay may lose +x depending on host checkout).
chmod 755 "${TARGET_DIR}/etc/network/apply_bmc_mac.sh" 2>/dev/null || true
chmod 755 "${TARGET_DIR}/etc/network/set_br0_mac_pre_dhcp.sh" 2>/dev/null || true

# #225: mdev hooks for /dev/disk/by-tpi/nodeN (block + USB hub port remove).
mdev_script="mdev-tpi-msd-symlink"
mconf="${TARGET_DIR}/etc/mdev.conf"
chmod 755 "${TARGET_DIR}/usr/bin/${mdev_script}" 2>/dev/null || true
if [ -f "${mconf}" ]; then
	# Idempotent: drop corrupt/duplicate hooks (must invoke @/usr/bin/..., not a host path).
	sed -i '\|tp2bmc/board.*mdev-tpi-msd-symlink|d' "${mconf}"
	sed -i 's/root:usb/root:root/g' "${mconf}"
	sed -i '/# mdev-tpi-msd-symlink (#225)/d' "${mconf}"
	sed -i '/# mdev-tpi-msd-usb (#225)/d' "${mconf}"
	sed -i '/sd\[a-z\].*mdev-tpi-msd-symlink/d' "${mconf}"
	sed -i '/[12]-1\\.[1-4].*mdev-tpi-msd-symlink/d' "${mconf}"
	if ! grep -q '@/usr/bin/mdev-tpi-msd-symlink' "${mconf}"; then
		printf '\n# mdev-tpi-msd-symlink (#225)\nsd[a-z]\troot:disk\t660\t@/usr/bin/%s\n' \
			"${mdev_script}" >>"${mconf}"
		printf '# mdev-tpi-msd-usb (#225) — stale by-tpi on hub port disconnect\n' >>"${mconf}"
		# root:root — there is no "usb" group in Buildroot; root:usb breaks mdev -s.
		printf '1-1\\.[1-4](:.*)?\troot:root\t660\t@/usr/bin/%s\n' "${mdev_script}" >>"${mconf}"
		printf '2-1\\.[1-4](:.*)?\troot:root\t660\t@/usr/bin/%s\n' "${mdev_script}" >>"${mconf}"
	fi
fi

# Rootfs size snapshot for dev-docs/rootfs-size-audit.md (NAND / 370 LEB budget).
if [[ -d "${TARGET_DIR}" ]]; then
	{
		echo "Turing Pi BMC — staged rootfs size (Buildroot TARGET_DIR)"
		echo "Generated at rootfs image assembly."
		echo ""
		du -sh "${TARGET_DIR}"
		echo ""
		echo "Top-level directories:"
		du -h -d 1 "${TARGET_DIR}" 2>/dev/null | LC_ALL=C sort -hr
		echo ""
		echo "Largest paths under usr/ and lib/ (if present):"
		du -h "${TARGET_DIR}/usr" "${TARGET_DIR}/lib" 2>/dev/null | LC_ALL=C sort -hr | head -25
	} >"${docdir}/rootfs-staged-size.txt"
fi
