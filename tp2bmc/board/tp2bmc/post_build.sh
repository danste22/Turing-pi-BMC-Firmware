#!/bin/bash

set -euo pipefail

BOARD_DIR="$(cd "$(dirname "$0")" && pwd)"
TP2BMC_DIR="$(cd "${BOARD_DIR}/../.." && pwd)"
CHECK_SPI_IMG="${TP2BMC_DIR}/scripts/check_spi_boot_image.sh"
# shellcheck source=uboot_build_dir.sh
source "${BOARD_DIR}/uboot_build_dir.sh"

# buildroots uboot-tools are ancient. Use the one from our uboot build.
pin="$(tp2bmc_uboot_pin "${TP2BMC_DIR}/configs/tp2bmc_defconfig")"
if ! uboot_build="$(tp2bmc_uboot_resolve_dir "${BUILD_DIR}" "${pin}")"; then
	echo "${uboot_build}" >&2
	exit 1
fi
mkimage="${uboot_build}/tools/mkimage"
if [[ ! -x "${mkimage}" ]]; then
	echo "error: U-Boot mkimage not found at ${mkimage}" >&2
	exit 1
fi

cd "${0%/*}"
mkdir -p "$TARGET_DIR/boot/"
"$mkimage" -A arm -T script -d boot.scr "$TARGET_DIR/boot/boot.scr.uimg"

# turing-pi2.its incbins DTBs/zImage from BINARIES_DIR. Sync board DTS into the
# kernel tree and build any missing DTBs (e.g. after adding v2.5.2.dts without
# make linux-reconfigure).
linux_bdir=""
for d in "${BUILD_DIR}"/linux-*; do
	[[ -d "$d" ]] || continue
	linux_bdir="$d"
	break
done
if [[ -z "$linux_bdir" ]]; then
	echo "error: linux build dir not found under ${BUILD_DIR}" >&2
	exit 1
fi

linux_dts_dir="${linux_bdir}/arch/arm/boot/dts"
mkdir -p "${linux_dts_dir}"
for f in "${BOARD_DIR}"/sun8i-t113s-turing-pi2*.dts "${BOARD_DIR}"/sun8i-t113s-turing-pi2*.dtsi; do
	[[ -f "$f" ]] || continue
	install -D -m 0644 "$f" "${linux_dts_dir}/$(basename "$f")"
done

cross="${TARGET_CROSS:-${HOST_DIR}/bin/arm-buildroot-linux-gnueabi-}"
kmake=(make -C "${linux_bdir}" ARCH=arm CROSS_COMPILE="${cross}"
	DTC_EXT="${HOST_DIR}/bin/dtc" DTC_FLAGS=-@)

fit_dtbs=(sun8i-t113s-turing-pi2-v2.4.dtb sun8i-t113s-turing-pi2-v2.5.dtb
	sun8i-t113s-turing-pi2-v2.5.1.dtb sun8i-t113s-turing-pi2-v2.5.2.dtb
	sun8i-t113s-turing-pi2-locked.dtb)

need_build=0
for dtb in "${fit_dtbs[@]}"; do
	[[ -f "${linux_dts_dir}/${dtb}" ]] || need_build=1
done
if [[ "$need_build" -eq 1 ]]; then
	"${kmake[@]}" "${fit_dtbs[@]}"
fi

for dtb in "${fit_dtbs[@]}"; do
	src="${linux_dts_dir}/${dtb}"
	if [[ ! -f "$src" ]]; then
		echo "error: failed to build ${src}" >&2
		exit 1
	fi
	install -D -m 0644 "$src" "${BINARIES_DIR}/${dtb}"
done
# Always refresh: BINARIES_DIR/zImage survives make linux-dirclean/linux and
# would otherwise leave turing-pi2.itb packing a stale kernel.
install -D -m 0644 "${linux_bdir}/arch/arm/boot/zImage" "${BINARIES_DIR}/zImage"

# LAG fixup helpers are static — verify source + that the object was linked
# (dev_dbg format strings are omitted from release builds; use nm + a durable
# summary string that stays as dev_info).
main_c="${linux_bdir}/drivers/net/dsa/realtek/rtl8365mb_main.c"
lag_c="${linux_bdir}/drivers/net/dsa/realtek/rtl8365mb_lag.c"
lag_o="${linux_bdir}/drivers/net/dsa/realtek/rtl8365mb_lag.o"
linux_stamp="${linux_bdir}/.stamp_built"
vmlinux="${linux_bdir}/vmlinux"

if ! grep -q 'rtl8365mb_port_fdb_add' "$main_c" 2>/dev/null; then
	echo "FAIL: net-dsa/0004 LAG fixup not applied to kernel tree" >&2
	exit 1
fi
if ! grep -q 'rtl8365mb_lag_bridge_isolation_fixup' "$lag_c" 2>/dev/null; then
	echo "FAIL: net-dsa/0004 LAG bridge uplink fixup missing in kernel tree" >&2
	exit 1
fi
if ! grep -q 'rtl8365mb_lag_pin_conduit_mac' "$lag_c" 2>/dev/null; then
	echo "FAIL: net-dsa/0004 conduit MAC pin missing in kernel tree" >&2
	exit 1
fi
for f in "$main_c" "$lag_c"; do
	if [[ -f "$linux_stamp" && "$f" -nt "$linux_stamp" ]]; then
		echo "FAIL: kernel sources newer than last build — run: make linux-dirclean linux" >&2
		exit 1
	fi
done

lag_fixup_ok=0
if [[ -f "$lag_o" ]] && nm "$lag_o" 2>/dev/null | grep -q 'rtl8365mb_lag_bridge_isolation_fixup'; then
	lag_fixup_ok=1
fi
if [[ "$lag_fixup_ok" -ne 1 ]]; then
	for blob in "$vmlinux" "$lag_o"; do
		if [[ -f "$blob" ]] && strings "$blob" 2>/dev/null | grep -qF 'LAG bridge uplink fixup'; then
			lag_fixup_ok=1
			break
		fi
	done
fi
if [[ "$lag_fixup_ok" -ne 1 ]]; then
	echo "FAIL: LAG bridge uplink fixup not in built kernel (expect isolation_fixup in rtl8365mb_lag.o)" >&2
	echo "      Run: make linux-dirclean linux && make target-finalize rootfs-erofs" >&2
	exit 1
fi

cp "$PWD"/*.its "$BINARIES_DIR/"
cd "$BINARIES_DIR"
fit_itb="$BINARIES_DIR/turing-pi2.itb"
"$mkimage" -E -f turing-pi2.its "$fit_itb"
if [ ! -f "$fit_itb" ]; then
	echo "error: mkimage did not create ${fit_itb}" >&2
	exit 1
fi
install -D -m 0644 "$fit_itb" "$TARGET_DIR/boot/turing-pi2.itb"

# SPI cold-boot: must be legacy mkimage @ 0x8000 (b04fcbf / feat/buildroot2025.11 layout).
uboot_img="${BINARIES_DIR}/u-boot-sunxi-with-spl.bin"
if [[ ! -x "${CHECK_SPI_IMG}" ]]; then
	echo "error: missing ${CHECK_SPI_IMG}" >&2
	exit 1
fi
if [[ ! -f "${uboot_img}" ]]; then
	echo "error: missing ${uboot_img} (U-Boot must be built before target-finalize)" >&2
	exit 1
fi
"${CHECK_SPI_IMG}" "${uboot_img}"

# /dev/ttyGS0 only exists while the ACM gadget is bound, so a respawn entry
# here makes init log "GS0 respawning too fast" on every boot without a USB
# host. mdev-ttyGS0-getty runs the getty instead; drop the entry incremental
# builds may still carry.
if [ -e ${TARGET_DIR}/etc/inittab ]; then
	sed -i '/^GS0::/d' ${TARGET_DIR}/etc/inittab
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

# Overlay checkout may drop +x; rcS execs init scripts — must be 755 on erofs.
find "${BOARD_DIR}/overlay/etc/init.d" -maxdepth 1 -name 'S*' -exec chmod 755 {} +
find "${TARGET_DIR}/etc/init.d" -maxdepth 1 -name 'S*' -exec chmod 755 {} + 2>/dev/null || true

# Factory MAC helpers (overlay may lose +x depending on host checkout).
chmod 755 "${TARGET_DIR}/etc/network/apply_bmc_mac.sh" 2>/dev/null || true
chmod 755 "${TARGET_DIR}/etc/network/set_br0_mac_pre_dhcp.sh" 2>/dev/null || true
chmod 755 "${TARGET_DIR}/etc/network/tp2-bond-up.sh" 2>/dev/null || true
chmod 755 "${TARGET_DIR}/etc/network/tp2-bond-down.sh" 2>/dev/null || true
chmod 755 "${TARGET_DIR}/etc/network/tp2-bond-wait-lacp.sh" 2>/dev/null || true
chmod 755 "${TARGET_DIR}/etc/network/install-bond-lacp-profile.sh" 2>/dev/null || true
chmod 755 "${TARGET_DIR}/usr/share/tp2/uplink-hairpin-test.sh" 2>/dev/null || true
chmod 755 "${TARGET_DIR}/usr/share/tp2/hw-validate.sh" 2>/dev/null || true

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

# USB-gadget serial console: run a getty only while /dev/ttyGS0 exists.
chmod 755 "${TARGET_DIR}/usr/bin/mdev-ttyGS0-getty" 2>/dev/null || true
if [ -f "${mconf}" ]; then
	sed -i '/# mdev-ttyGS0-getty/d' "${mconf}"
	sed -i '/ttyGS0.*mdev-ttyGS0-getty/d' "${mconf}"
	# '*' runs the helper on both add and remove; it reads $ACTION.
	printf '\n# mdev-ttyGS0-getty — USB-OTG serial console\nttyGS0\troot:root\t660\t*/usr/bin/mdev-ttyGS0-getty\n' \
		>>"${mconf}"
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
