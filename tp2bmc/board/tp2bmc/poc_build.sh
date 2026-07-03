#!/usr/bin/env bash
# shellcheck shell=bash
# True when the active Buildroot defconfig is tp2bmc_smi_mux_poc_defconfig.

tp2bmc_smi_mux_poc_build() {
	local cfg="${BR2_CONFIG:-}"
	if [[ -z "$cfg" && -n "${BUILD_DIR:-}" ]]; then
		cfg="${BUILD_DIR}/../.config"
	fi
	[[ -n "$cfg" && -f "$cfg" ]] &&
		grep -qE 'linux_smi_mux_poc_defconfig' "$cfg"
}
