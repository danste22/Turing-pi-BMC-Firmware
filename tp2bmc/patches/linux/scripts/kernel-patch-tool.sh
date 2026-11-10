#!/usr/bin/env bash
# TP2 BMC — enumerate / check / apply kernel patches in Buildroot order.
# Baseline for learning & docs: Linux 6.8.x tree under tmp/linux-6.8.12 (configurable).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_ROOT="${PATCH_ROOT:-$(cd "${SCRIPT_DIR}/.." && pwd)}"
# BMC-Firmware repo root = tp2bmc/patches/linux/scripts/../../../..
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
KERNEL_SRC="${KERNEL_SRC:-${WORKSPACE_ROOT}/tmp/linux-6.8.12}"

usage() {
	cat <<EOF
Usage: $(basename "$0") <command>

Commands:
  inventory             List patches in apply order and paths touched (from patch text).
  files <patch>         Paths touched by one patch (relative to ${PATCH_ROOT}/).
  list-order            Absolute paths of patches, one per line (production TARGET layout).
  list-order-hive <dir> Flat hive root patches in Buildroot order (default: ${PATCH_ROOT}).
  check                 Sequential git apply --check against KERNEL_SRC (no writes).
  check-hive            Like check, but hive flat list (HIVE_PATCH_ROOT or ${PATCH_ROOT}).
  apply                 Apply all patches to KERNEL_SRC (git apply).
  apply-hive            Apply hive flat list to KERNEL_SRC.
  markdown-inventory    Markdown snippets for KERNEL_UPGRADE_LOG.md (stdout).

Environment:
  KERNEL_SRC            Kernel tree (default: ${KERNEL_SRC})

Examples:
  KERNEL_SRC=\$PWD/tmp/linux-6.8.12 $(basename "$0") check
  $(basename "$0") files power/0001-regulator-fixed-preserve-boot-state.patch
EOF
}

# Production order (KERNEL_UPGRADE_LOG): generic → net-dsa → tp2 (0001 drops monolith via git delete hunk)
ordered_patches() {
	local root="$PATCH_ROOT" d p
	for d in generic/i2c generic/pwm net-dsa tp2/gpio tp2/power tp2/tpi-smi-mux; do
		shopt -s nullglob
		for p in "${root}/${d}"/*.patch; do
			echo "$p"
		done
		shopt -u nullglob
	done
}

# excavador hive @ 6.12.109 — flat root patches only (Buildroot LC_COLLATE order)
ordered_patches_hive() {
	local root="${1:-$PATCH_ROOT}" p
	local names=(
		0001-regulator-fixed-perserve-boot-state.patch
		0002-gpio-aggregator-Add-turingmachines-tp2-nodes-compati.patch
		Add-support-for-Allwinner-PWM-on-D1-T113s-R329-SoCs.patch
		i2c.patch
		realtek-switch.patch
		rtl8370-vlan-support.patch
	)
	for p in "${names[@]}"; do
		if [[ -f "${root}/${p}" ]]; then
			echo "${root}/${p}"
		fi
	done
}

patch_touched_files() {
	local patch="$1"
	if [[ ! -f "$patch" ]]; then
		echo "error: not a file: $patch" >&2
		return 1
	fi
	while IFS= read -r line; do
		if [[ "$line" =~ ^diff\ --git\ a/([^[:space:]]+)\ b/([^[:space:]]+) ]]; then
			echo "${BASH_REMATCH[2]}"
		fi
	done <"$patch"
	while IFS= read -r line; do
		if [[ "$line" =~ ^---\ a/([^[:space:]]+) ]]; then
			local f="${BASH_REMATCH[1]}"
			[[ "$f" == "/dev/null" ]] && continue
			echo "$f"
		fi
	done <"$patch"
}

patch_touched_files_unique() {
	patch_touched_files "$1" | sort -u
}

cmd_inventory() {
	local p rel
	while IFS= read -r p; do
		rel="${p#"${PATCH_ROOT}/"}"
		echo "=== ${rel} ==="
		patch_touched_files_unique "$p" | sed 's/^/  /'
		echo
	done < <(ordered_patches)
}

cmd_files() {
	local patch="$1"
	if [[ ! "$patch" =~ ^/ ]]; then
		patch="${PATCH_ROOT}/${patch}"
	fi
	patch_touched_files_unique "$patch"
}

cmd_list_order() {
	ordered_patches
}

cmd_list_order_hive() {
	ordered_patches_hive "${1:-$PATCH_ROOT}"
}

cmd_check_hive() {
	if [[ ! -d "$KERNEL_SRC" ]]; then
		echo "error: KERNEL_SRC not found: $KERNEL_SRC" >&2
		exit 1
	fi
	local hive_root="${HIVE_PATCH_ROOT:-$PATCH_ROOT}"
	local p ok=0
	while IFS= read -r p; do
		echo "--- check $(basename "$p") ---"
		if apply_one_check "$KERNEL_SRC" "$p"; then
			ok=$((ok + 1))
		else
			echo "FAIL: $p" >&2
			exit 1
		fi
		apply_one "$KERNEL_SRC" "$p"
	done < <(ordered_patches_hive "$hive_root")
	echo "OK: all $ok hive patches applied (cumulative check)."
}

cmd_apply_hive() {
	if [[ ! -d "$KERNEL_SRC" ]]; then
		echo "error: KERNEL_SRC not found: $KERNEL_SRC" >&2
		exit 1
	fi
	local hive_root="${HIVE_PATCH_ROOT:-$PATCH_ROOT}"
	local p
	while IFS= read -r p; do
		echo "Applying $(basename "$p") ..."
		apply_one "$KERNEL_SRC" "$p"
	done < <(ordered_patches_hive "$hive_root")
	echo "Done (hive)."
}

apply_one_check() {
	local tree="$1" patch="$2"
	patch -p1 -F"${PATCH_FUZZ:-0}" -g0 -d "${tree}" --dry-run -N -s <"${patch}"
}

apply_one() {
	local tree="$1" patch="$2" errf rejects
	errf="$(mktemp)"
	if ! patch -p1 -F"${PATCH_FUZZ:-0}" -g0 -d "${tree}" -N -s <"${patch}" 2>"${errf}"; then
		cat "${errf}" >&2
		rm -f "${errf}"
		return 1
	fi
	if grep -qi fail "${errf}"; then
		cat "${errf}" >&2
		rm -f "${errf}"
		return 1
	fi
	rm -f "${errf}"
	rejects="$(find "${tree}" -name '*.rej' -print 2>/dev/null | head -1)"
	if [[ -n "${rejects}" ]]; then
		echo "reject files present after $(basename "${patch}") e.g. ${rejects}" >&2
		return 1
	fi
}

cmd_check() {
	if [[ ! -d "$KERNEL_SRC" ]]; then
		echo "error: KERNEL_SRC not found: $KERNEL_SRC" >&2
		exit 1
	fi
	local p ok=0
	while IFS= read -r p; do
		echo "--- check $(basename "$p") ---"
		if apply_one_check "$KERNEL_SRC" "$p"; then
			ok=$((ok + 1))
		else
			echo "FAIL: $p" >&2
			exit 1
		fi
		apply_one "$KERNEL_SRC" "$p"
	done < <(ordered_patches)
	echo "OK: all $ok patches applied (cumulative check)."
}

cmd_apply() {
	if [[ ! -d "$KERNEL_SRC" ]]; then
		echo "error: KERNEL_SRC not found: $KERNEL_SRC" >&2
		exit 1
	fi
	local p
	while IFS= read -r p; do
		echo "Applying $(basename "$p") ..."
		apply_one "$KERNEL_SRC" "$p"
	done < <(ordered_patches)
	echo "Done."
}

cmd_markdown_inventory() {
	local p rel f
	echo "### Auto-generated file list (run: \`scripts/kernel-patch-tool.sh inventory\`)"
	echo
	while IFS= read -r p; do
		rel="${p#"${PATCH_ROOT}/"}"
		echo "#### \`${rel}\`"
		echo
		echo "| Path |"
		echo "|------|"
		while IFS= read -r f; do
			echo "| \`${f}\` |"
		done < <(patch_touched_files_unique "$p")
		echo
	done < <(ordered_patches)
}

main() {
	case "${1:-}" in
	inventory)          cmd_inventory ;;
	files)              shift; cmd_files "${1:?patch path}" ;;
	list-order)         cmd_list_order ;;
	list-order-hive)    shift; cmd_list_order_hive "${1:-}" ;;
	check)              cmd_check ;;
	check-hive)         cmd_check_hive ;;
	apply)              cmd_apply ;;
	apply-hive)         cmd_apply_hive ;;
	markdown-inventory) cmd_markdown_inventory ;;
	-h|help|"")
		usage
		[[ "${1:-}" == "" ]] && exit 1
		;;
	*)
		echo "unknown command: $1" >&2
		usage
		exit 1
		;;
	esac
}

main "$@"
