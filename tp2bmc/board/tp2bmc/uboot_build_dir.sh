# shellcheck shell=bash
# Resolve Buildroot's U-Boot source directory.
# Upstream custom version: output/build/uboot-<BR2_TARGET_UBOOT_CUSTOM_VERSION_VALUE>
# Legacy git pin: output/build/uboot-<BR2_TARGET_UBOOT_CUSTOM_REPO_VERSION>

tp2bmc_uboot_pin() {
	local br_defconfig="${1:?}"
	local ver

	ver=$(grep '^BR2_TARGET_UBOOT_CUSTOM_VERSION_VALUE=' "$br_defconfig" | cut -d= -f2 | tr -d '"')
	if [[ -n "$ver" ]]; then
		echo "$ver"
		return 0
	fi
	grep '^BR2_TARGET_UBOOT_CUSTOM_REPO_VERSION=' "$br_defconfig" | cut -d= -f2 | tr -d '"'
}

tp2bmc_uboot_expected_dir() {
	local build_dir="${1:?}" pin="${2:?}"
	echo "${build_dir}/uboot-${pin}"
}

# Print the U-Boot source tree path or return 1 with a message on stderr.
tp2bmc_uboot_resolve_dir() {
	local build_dir="${1:?}" pin="${2:?}"
	local expected dir

	expected="$(tp2bmc_uboot_expected_dir "$build_dir" "$pin")"
	if [[ -d "$expected" ]]; then
		echo "$expected"
		return 0
	fi

	for dir in "${build_dir}"/uboot-*; do
		[[ -d "$dir" ]] || continue
		echo "error: stale U-Boot build ${dir} (expected ${expected})" >&2
		echo "error: run: make uboot-dirclean && make" >&2
		return 1
	done

	echo "error: no U-Boot build under ${build_dir} (expected ${expected})" >&2
	return 1
}
