#!/bin/sh
# Apply factory BMC MAC from NVMEM cell or EEPROM @ 0x2C to netdev(s).
# Sourced from S39bmc-mac, S00dsa, and set_br0_mac_pre_dhcp.sh.

BMC_MAC_LOG_TAG=apply_bmc_mac

log() {
	echo "${BMC_MAC_LOG_TAG}: $*" >&2
	logger -t "${BMC_MAC_LOG_TAG}" "$*" 2>/dev/null || true
}

# Six bytes (stdin or file redirect) -> aa:bb:cc:dd:ee:ff (BusyBox od; no hexdump -e).
bytes_to_mac() {
	# od -An -tx1 prints e.g. " c4 ff 84 10 00 ba"
	set -- $(od -An -tx1 -N6 2>/dev/null)
	[ $# -eq 6 ] || return 1
	mac=$(printf '%s:%s:%s:%s:%s:%s' "$1" "$2" "$3" "$4" "$5" "$6")
	case "$mac" in
	([0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]) ;;
	(*) return 1 ;;
	esac
	printf '%s' "$mac"
}

read_mac_from_file() {
	[ -r "$1" ] || return 1
	bytes_to_mac < "$1"
}

read_bmc_mac() {
	mac=

	for cell in /sys/bus/nvmem/devices/*/cells/mac-address@2c,*; do
		[ -e "$cell" ] || continue
		mac=$(read_mac_from_file "$cell") && printf '%s' "$mac" && return 0
	done

	for p in /sys/bus/i2c/devices/*-0050/eeprom; do
		[ -r "$p" ] || continue
		mac=$(dd if="$p" bs=1 skip=44 count=6 2>/dev/null | bytes_to_mac) \
			&& printf '%s' "$mac" && return 0
	done
	return 1
}

set_iface_mac() {
	_iface=$1
	_mac=$2
	if ip link set dev "$_iface" address "$_mac" 2>/dev/null; then
		return 0
	fi
	# Bridges often reject address changes while UP with ports attached.
	if [ "$_iface" = br0 ]; then
		ip link set dev br0 down 2>/dev/null || true
		if ip link set dev br0 address "$_mac" 2>/dev/null; then
			ip link set dev br0 up 2>/dev/null || true
			return 0
		fi
		ip link set dev br0 up 2>/dev/null || true
	fi
	return 1
}

apply_bmc_mac() {
	mac=
	src=

	if [ -f /etc/tpi.cfg ]; then
		mac=$(sed -n 's/^[[:space:]]*mac[[:space:]]*=[[:space:]]*//p' /etc/tpi.cfg \
			| head -n1 | tr -d '\r')
	fi
	case "$mac" in
	([0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]) src=tpi.cfg ;;
	(*)
		mac=$(read_bmc_mac) || {
			log "no factory MAC (NVMEM cell / EEPROM unreadable)"
			return 1
		}
		src=factory
		;;
	esac

	log "using MAC $mac ($src)"

	_ok=0
	for iface in "$@"; do
		[ -n "$iface" ] || continue
		if ! ip link show "$iface" >/dev/null 2>&1; then
			log "skip $iface (no such netdev)"
			continue
		fi
		if set_iface_mac "$iface" "$mac"; then
			log "$iface <- $mac"
			_ok=1
		else
			log "failed: ip link set dev $iface address $mac"
		fi
	done
	[ "$_ok" -eq 1 ]
}
