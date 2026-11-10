#!/usr/bin/env bash
# Phase 4-audit: materialize HIVE@6.12.109 and TARGET@6.18.62 patched trees (local only).
set -euo pipefail

die() { echo "error: $*" >&2; exit 1; }

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AUDIT_DIR="${ROOT}/tmp/kernel-audit"
TOOL="${ROOT}/tp2bmc/patches/linux/scripts/kernel-patch-tool.sh"
HIVE_PATCH_ROOT="${HIVE_PATCH_ROOT:-${ROOT}/tmp/hive-patches-612}"
TARGET_PATCH_ROOT="${TARGET_PATCH_ROOT:-${ROOT}/../BMC-Firmware/tp2bmc/patches/linux}"
SHA_612="5484e552a334e15019f4aeba89e5b58f04651cf2f4e24e04de9f152f1c38e3fa"
SHA_618="490a7aedf1b355c565d3a6c05333ccccb5da82064eca46b590448a7099d7d651"
URL_612="https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.12.109.tar.xz"
URL_618="https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.18.62.tar.xz"

log() { echo "[kernel-audit] $*"; }

ensure_tar() {
	local url="$1" file="$2" want_sha="$3"
	mkdir -p "${AUDIT_DIR}"
	if [[ ! -f "${file}" ]]; then
		log "download ${file##*/}"
		curl -fL --retry 3 -o "${file}" "${url}"
	fi
	echo "${want_sha}  ${file##*/}" | (cd "${AUDIT_DIR}" && shasum -a 256 -c -)
}

prepare_tree() {
	local tar="$1" out="$2" bn
	bn="$(basename "${tar}" .tar.xz)"
	rm -rf "${out}" "${AUDIT_DIR}/${bn}"
	tar -C "${AUDIT_DIR}" -xf "${tar}"
	mv "${AUDIT_DIR}/${bn}" "${out}"
	(
		cd "${out}"
		git init -q
		git add -A
		git -c user.email=audit@local -c user.name=audit commit -q -m "vanilla"
	)
}

apply_target_git() {
	local tree="$1"
	log "TARGET apply (production order) → ${tree}"
	PATCH_FUZZ="${PATCH_FUZZ:-3}" KERNEL_SRC="${tree}" PATCH_ROOT="${TARGET_PATCH_ROOT}" "${TOOL}" check
}

apply_hive_git() {
	local tree="$1"
	log "HIVE apply → ${tree}"
	KERNEL_SRC="${tree}" HIVE_PATCH_ROOT="${HIVE_PATCH_ROOT}" "${TOOL}" apply-hive
}

main() {
	[[ -x "${TOOL}" ]] || die "missing ${TOOL}"
	[[ -d "${TARGET_PATCH_ROOT}" ]] || {
		echo "error: TARGET_PATCH_ROOT not found: ${TARGET_PATCH_ROOT}" >&2
		exit 1
	}

	mkdir -p "${HIVE_PATCH_ROOT}"
	if [[ ! -f "${HIVE_PATCH_ROOT}/realtek-switch.patch" ]]; then
		log "extract hive patches from excavador/hive"
		(
			cd "${ROOT}"
			for f in \
				0001-regulator-fixed-perserve-boot-state.patch \
				0002-gpio-aggregator-Add-turingmachines-tp2-nodes-compati.patch \
				Add-support-for-Allwinner-PWM-on-D1-T113s-R329-SoCs.patch \
				i2c.patch \
				realtek-switch.patch \
				rtl8370-vlan-support.patch
			do
				git show "excavador/hive:tp2bmc/patches/linux/${f}" >"${HIVE_PATCH_ROOT}/${f}"
			done
		)
	fi

	local t612="${AUDIT_DIR}/linux-6.12.109.tar.xz"
	local t618="${AUDIT_DIR}/linux-6.18.62.tar.xz"
	ensure_tar "${URL_612}" "${t612}" "${SHA_612}"
	ensure_tar "${URL_618}" "${t618}" "${SHA_618}"

	local tree_hive="${AUDIT_DIR}/linux-6.12.109-hive"
	local tree_target="${AUDIT_DIR}/linux-6.18.62-target"

	prepare_tree "${t612}" "${tree_hive}"
	prepare_tree "${t618}" "${tree_target}"

	KERNEL_SRC="${tree_hive}" HIVE_PATCH_ROOT="${HIVE_PATCH_ROOT}" "${TOOL}" check-hive
	apply_hive_git "${tree_hive}"

	apply_target_git "${tree_target}"

	log "done"
	log "  HIVE tree:    ${tree_hive}"
	log "  TARGET tree:  ${tree_target}"
}

main "$@"
