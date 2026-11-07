#!/usr/bin/env bash
# Compare BMC boot settings + built image to the known-good reference (not the product pin):
#   https://github.com/danste22/Turing-pi-u-boot/commits/feat/buildroot2025.11
#   ref 7164231fd43a — OF_EMBED, legacy mkimage @ 0x8000, spl_spi 3x NAND→NOR.
# Product U-Boot version is BR2_TARGET_UBOOT_CUSTOM_VERSION_VALUE in tp2bmc_defconfig.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DEFCONFIG="${ROOT}/tp2bmc/board/tp2bmc/uboot_defconfig"
BR_DEFCONFIG="${ROOT}/tp2bmc/configs/tp2bmc_defconfig"
CHECK_IMG="${ROOT}/tp2bmc/scripts/check_spi_boot_image.sh"
PATCH_DIR="${ROOT}/tp2bmc/patches/uboot"
UBOOT_BUILD_HELPER="${ROOT}/tp2bmc/board/tp2bmc/uboot_build_dir.sh"

REF_COMMIT="${UBOOT_REF_COMMIT:-7164231fd43aaaa00ed76975b60c84b3d73fbecd}"
REF_BRANCH="${UBOOT_REF_BRANCH:-feat/buildroot2025.11}"

fail=0
ok() { echo "OK: $*"; }
bad() { echo "FAIL: $*"; fail=1; }
warn() { echo "WARN: $*"; }

echo "Reference (compare only): ${REF_BRANCH} @ ${REF_COMMIT:0:12}"
echo ""

echo "=== 1) uboot_defconfig boot keys (must match ${REF_BRANCH}) ==="
for badopt in CONFIG_SPL_LOAD_FIT CONFIG_OF_SEPARATE CONFIG_SPL_FIT CONFIG_OF_BOARD; do
	if grep -q "^${badopt}=y" "$DEFCONFIG" 2>/dev/null; then
		bad "$badopt enabled (reference disables this for cold SPI)"
	fi
done
grep -q '^CONFIG_OF_EMBED=y' "$DEFCONFIG" || bad 'CONFIG_OF_EMBED missing'
grep -q '^# CONFIG_OF_SEPARATE is not set' "$DEFCONFIG" || bad 'OF_SEPARATE must be disabled'
grep -q '^CONFIG_SPL_SPI_SUNXI=y' "$DEFCONFIG" || bad 'CONFIG_SPL_SPI_SUNXI missing'
grep -q '^CONFIG_SPL_SPI_SUNXI_NAND=y' "$DEFCONFIG" || bad 'CONFIG_SPL_SPI_SUNXI_NAND missing'
grep -q '^CONFIG_MULTI_DTB_FIT=y' "$DEFCONFIG" || bad 'CONFIG_MULTI_DTB_FIT missing'
grep -q '^CONFIG_TARGET_TURINGPI2=y' "$DEFCONFIG" || bad 'CONFIG_TARGET_TURINGPI2 missing'
grep -q '^CONFIG_LTO=y' "$DEFCONFIG" || bad 'CONFIG_LTO missing'
grep -q '^CONFIG_UBI_DEFAULT_VID_OFFSET=2048' "$DEFCONFIG" || bad 'CONFIG_UBI_DEFAULT_VID_OFFSET=2048 missing'
grep -q '^# CONFIG_TOOLS_MKEFICAPSULE is not set' "$DEFCONFIG" || \
	bad 'CONFIG_TOOLS_MKEFICAPSULE must be disabled (host GnuTLS has no PKCS#11)'
grep -q '^# CONFIG_EFI_LOADER is not set' "$DEFCONFIG" || \
	bad 'CONFIG_EFI_LOADER must be disabled (pulls in mkeficapsule)'
grep -q '^BR2_TARGET_UBOOT_DEFAULT_ENV_FILE=' "$BR_DEFCONFIG" 2>/dev/null || \
	bad 'BR2_TARGET_UBOOT_DEFAULT_ENV_FILE missing in tp2bmc_defconfig'
[[ $fail -eq 0 ]] && ok 'uboot_defconfig boot keys'

echo ""
echo "=== 2) Product U-Boot version (Buildroot) ==="
pin=""
if [[ ! -f "$BR_DEFCONFIG" ]]; then
	bad "missing $BR_DEFCONFIG"
else
	pin=$(grep '^BR2_TARGET_UBOOT_CUSTOM_VERSION_VALUE=' "$BR_DEFCONFIG" | cut -d= -f2 | tr -d '"')
	[[ -n "$pin" ]] || pin=$(grep '^BR2_TARGET_UBOOT_CUSTOM_REPO_VERSION=' "$BR_DEFCONFIG" | cut -d= -f2 | tr -d '"')
	ok "product U-Boot ${pin} (reference is ${REF_COMMIT:0:12}, not required to match)"
fi
patch_count=$(find "$PATCH_DIR" -name '*.patch' 2>/dev/null | wc -l | tr -d ' ')
if [[ "${patch_count}" -eq 0 ]]; then
	bad "no U-Boot patches under ${PATCH_DIR}/ — expected sunxi/usb/ubi/i2c/spl/board series"
else
	ok "${patch_count} U-Boot patch(es) in ${PATCH_DIR}/"
fi

echo ""
echo "=== 3) Built tree vs reference: spl_spi.c ==="
uboot_dir="${UBOOT_DIR:-}"
if [[ -z "$uboot_dir" && -n "${BUILD_DIR:-}" && -n "$pin" && -f "$UBOOT_BUILD_HELPER" ]]; then
	# shellcheck source=/dev/null
	source "$UBOOT_BUILD_HELPER"
	if ! uboot_dir="$(tp2bmc_uboot_resolve_dir "$BUILD_DIR" "$pin")"; then
		bad "expected ${BUILD_DIR}/uboot-${pin} — run: make uboot-dirclean && make"
		uboot_dir=""
	fi
fi
if [[ -z "$uboot_dir" && -d "${ROOT}/../turing-bmc-bootloader/.git" ]]; then
	uboot_dir="${ROOT}/../turing-bmc-bootloader"
fi
if [[ -z "$uboot_dir" ]]; then
	bad 'set UBOOT_DIR or BUILD_DIR to the product U-Boot source tree'
else
	# Buildroot names trees output/build/uboot-<pin>; a git clone used for dev may differ.
	if [[ -n "${BUILD_DIR:-}" && -n "$pin" && "$(basename "$uboot_dir")" != "uboot-${pin}" ]]; then
		bad "tree is $(basename "$uboot_dir"), expected uboot-${pin} — make uboot-dirclean && make"
	fi

	if [[ -n "${BUILD_DIR:-}" && -n "$pin" && "$(basename "$uboot_dir")" == "uboot-${pin}" && \
		-f "${uboot_dir}/.config" ]]; then
		for badopt in CONFIG_SPL_LOAD_FIT CONFIG_OF_SEPARATE CONFIG_OF_BOARD; do
			if grep -q "^${badopt}=y" "${uboot_dir}/.config"; then
				bad "built .config has ${badopt}=y (causes SPL/initr_dm regressions)"
			fi
		done
		grep -q '^CONFIG_OF_EMBED=y' "${uboot_dir}/.config" || \
			bad 'built .config missing CONFIG_OF_EMBED=y'
		[[ $fail -eq 0 ]] && ok 'built .config boot options'
	fi

	spl_file="${uboot_dir}/arch/arm/mach-sunxi/spl_spi_sunxi.c"
	if [[ ! -f "$spl_file" ]]; then
		bad "missing ${spl_file}"
	else
		if grep -q 'spl_board_spi_' "$spl_file"; then
			bad 'spl_spi_sunxi.c uses spl_board_spi_* (drops 3x NAND→NOR retries)'
		fi
		for need in SUNXI_SPL_SPI_MAX_ATTEMPTS 'load.read = spi_load_read_nor'; do
			grep -q "$need" "$spl_file" || bad "spl_spi_sunxi.c missing: $need"
		done
		if ! grep -q 'CONFIG_TEXT_BASE' "$spl_file" &&
		   ! grep -q 'header_buf' "$spl_file"; then
			bad 'spl_spi_sunxi.c missing try_load header (CONFIG_TEXT_BASE or header_buf)'
		fi
	fi

	ref_repo="${UBOOT_REF_GIT:-}"
	[[ -z "$ref_repo" && -d "${ROOT}/../turing-bmc-bootloader/.git" ]] && \
		ref_repo="${ROOT}/../turing-bmc-bootloader"
	spl_matched=0
	if [[ -n "$ref_repo" && -n "$pin" ]] && \
		git -C "$ref_repo" cat-file -e "${pin}:arch/arm/mach-sunxi/spl_spi_sunxi.c" 2>/dev/null; then
		ref_spl="$(mktemp)"
		git -C "$ref_repo" show "${pin}:arch/arm/mach-sunxi/spl_spi_sunxi.c" >"$ref_spl"
		if diff -q "$ref_spl" "$spl_file" >/dev/null; then
			ok "spl_spi_sunxi.c matches product pin ${pin:0:12}"
			spl_matched=1
		fi
		rm -f "$ref_spl"
	fi
	if [[ $spl_matched -eq 0 && -n "$ref_repo" ]] && \
		git -C "$ref_repo" cat-file -e "${REF_COMMIT}:arch/arm/mach-sunxi/spl_spi_sunxi.c" 2>/dev/null; then
		ref_spl="$(mktemp)"
		git -C "$ref_repo" show "${REF_COMMIT}:arch/arm/mach-sunxi/spl_spi_sunxi.c" >"$ref_spl"
		if diff -q "$ref_spl" "$spl_file" >/dev/null; then
			ok "spl_spi_sunxi.c matches reference ${REF_COMMIT:0:12}"
			spl_matched=1
		elif grep -q 'header_buf' "$spl_file" &&
		     grep -q 'SUNXI_SPL_SPI_MAX_ATTEMPTS' "$spl_file"; then
			ok 'spl_spi_sunxi.c has reference retry loop (+ stack header / erased-NAND guards)'
			spl_matched=1
		else
			bad "spl_spi_sunxi.c differs from reference ${REF_COMMIT:0:12}"
		fi
		rm -f "$ref_spl"
	elif [[ $spl_matched -eq 0 && -d "${uboot_dir}/.git" ]] && \
		git -C "$uboot_dir" cat-file -e "${REF_COMMIT}:arch/arm/mach-sunxi/spl_spi_sunxi.c" 2>/dev/null; then
		if git -C "$uboot_dir" diff "${REF_COMMIT}" HEAD -- \
			arch/arm/mach-sunxi/spl_spi_sunxi.c | grep -q .; then
			if grep -q 'header_buf' "$spl_file" &&
			   grep -q 'SUNXI_SPL_SPI_MAX_ATTEMPTS' "$spl_file"; then
				ok 'spl_spi_sunxi.c has reference retry loop (+ stack header / erased-NAND guards)'
				spl_matched=1
			else
				bad "spl_spi_sunxi.c differs from reference ${REF_COMMIT:0:12}"
			fi
		else
			ok "spl_spi_sunxi.c matches reference ${REF_COMMIT:0:12}"
			spl_matched=1
		fi
	fi
	if [[ $spl_matched -eq 0 ]]; then
		warn "set UBOOT_REF_GIT to a clone with ${REF_COMMIT:0:12} to verify spl_spi byte match"
		ok 'spl_spi_sunxi.c has reference markers'
	fi

	if [[ -f "${uboot_dir}/board/turing/pi2/turingpi2-spl.c" ]]; then
		ok 'board/turing/pi2 (product layout; reference uses board/tp2bmc)'
	elif [[ -f "${uboot_dir}/board/tp2bmc/turingpi2-spl.c" ]]; then
		warn 'board/tp2bmc (reference layout on product pin?)'
	fi

	ubi_lookup="${uboot_dir}/drivers/mtd/ubi/ubi-uclass.c"
	fit_lookup="${uboot_dir}/board/turing/pi2/turingpi2-board.c"
	if [[ -f "$ubi_lookup" ]]; then
		if grep -q 'ubi_find_volume_dev' "$ubi_lookup"; then
			ok 'ubi_find_volume_dev present (ubi 0:rootfs name lookup)'
		else
			bad 'missing ubi_find_volume_dev — ubi 0:rootfs fails (blk child is ubi0.rootfs)'
		fi
	fi
	if [[ -f "$fit_lookup" ]]; then
		if grep -q 'turingpi2_hw_version()' "$fit_lookup" &&
		   grep -A2 'turingpi2_set_fit_config_env' "$fit_lookup" | grep -q 'turingpi2_hw_version'; then
			ok 'tpi_fit_config from EEPROM hw_version'
		else
			bad 'turingpi2_set_fit_config_env must use EEPROM hw_version (not embedded DT model)'
		fi
	fi
fi

echo ""
echo "=== 4) binman: SPL_LOAD_FIT off => u-boot-img @ 0x8000 ==="
if [[ -n "${uboot_dir:-}" && -f "${uboot_dir}/arch/arm/dts/sunxi-u-boot.dtsi" ]]; then
	grep -q 'CONFIG_SPL_LOAD_FIT' "${uboot_dir}/arch/arm/dts/sunxi-u-boot.dtsi" && \
		ok 'sunxi-u-boot.dtsi gates FIT on CONFIG_SPL_LOAD_FIT'
fi

echo ""
echo "=== 5) Built image (layout vs reference) ==="
img="${1:-${BINARIES_DIR:-${ROOT}/output/images}/u-boot-sunxi-with-spl.bin}"
if [[ -f "$img" ]]; then
	"$CHECK_IMG" "$img" || fail=1
	if strings "$img" 2>/dev/null | grep -q 'U-Boot SPL 2026.01'; then
		warn 'image is reference-era 2026.01 — product pin may be 2026.04'
	fi
	ok 'SPI image layout checked (mkimage @ 0x8000)'
else
	bad "missing ${img}"
fi

echo ""
if [[ $fail -eq 0 ]]; then
	echo "VALIDATION PASSED (boot keys + layout vs ${REF_BRANCH})"
else
	echo "VALIDATION FAILED (vs ${REF_BRANCH} reference)"
	exit 1
fi
