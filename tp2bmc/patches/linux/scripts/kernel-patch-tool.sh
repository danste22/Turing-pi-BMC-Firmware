#!/usr/bin/env bash
# TP2 BMC — enumerate / check / apply kernel patches in Buildroot order.
# Baseline for learning & docs: Linux 6.8.x tree under tmp/linux-6.8.12 (configurable).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# BMC-Firmware repo root = tp2bmc/patches/linux/scripts/../../../..
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/../../../.." && pwd)"
KERNEL_SRC="${KERNEL_SRC:-${WORKSPACE_ROOT}/tmp/linux-6.8.12}"

usage() {
	cat <<EOF
Usage: $(basename "$0") <command>

Commands:
  inventory             List patches in apply order and paths touched (from patch text).
  files <patch>         Paths touched by one patch (relative to ${PATCH_ROOT}/).
  list-order            Absolute paths of patches, one per line.
  check                 Sequential git apply --check against KERNEL_SRC (no writes).
  apply                 Apply all patches to KERNEL_SRC (git apply).
  markdown-inventory    Markdown snippets for KERNEL_UPGRADE_LOG.md (stdout).

Environment:
  KERNEL_SRC            Kernel tree (default: ${KERNEL_SRC})

Examples:
  KERNEL_SRC=\$PWD/tmp/linux-6.8.12 $(basename "$0") check
  $(basename "$0") files power/0001-regulator-fixed-preserve-boot-state.patch
EOF
}

ordered_patches() {
	local root="$PATCH_ROOT" d p
	for d in power gpio pwm i2c net-dsa; do
		case "$d" in
		i2c)
			shopt -s nullglob
			for p in "${root}/${d}"/i2c-*.patch; do
				echo "$p"
			done
			shopt -u nullglob
			;;
		*)
			shopt -s nullglob
			for p in "${root}/${d}"/*.patch; do
				echo "$p"
			done
			shopt -u nullglob
			;;
		esac
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

cmd_check() {
	if [[ ! -d "$KERNEL_SRC" ]]; then
		echo "error: KERNEL_SRC not found: $KERNEL_SRC" >&2
		exit 1
	fi
	local p ok=0
	while IFS= read -r p; do
		echo "--- check $(basename "$p") ---"
		if (cd "$KERNEL_SRC" && git apply --check "$p"); then
			ok=$((ok + 1))
		else
			echo "FAIL: $p" >&2
			exit 1
		fi
	done < <(ordered_patches)
	echo "OK: all $ok patches pass git apply --check (tree unchanged)."
}

cmd_apply() {
	if [[ ! -d "$KERNEL_SRC" ]]; then
		echo "error: KERNEL_SRC not found: $KERNEL_SRC" >&2
		exit 1
	fi
	local p
	while IFS= read -r p; do
		echo "Applying $(basename "$p") ..."
		(cd "$KERNEL_SRC" && git apply "$p")
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
	check)              cmd_check ;;
	apply)              cmd_apply ;;
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
