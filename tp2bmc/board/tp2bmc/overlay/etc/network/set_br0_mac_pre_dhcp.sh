#!/bin/sh
# Apply BMC MAC to dsa/br0 before the first DHCP on br0 (ifupdown-ng pre-up).
if [ ! -f /etc/network/apply_bmc_mac.sh ]; then
	echo "set_br0_mac_pre_dhcp: missing /etc/network/apply_bmc_mac.sh" >&2
	exit 0
fi
# shellcheck source=/dev/null
. /etc/network/apply_bmc_mac.sh

ip link show br0 >/dev/null 2>&1 || exit 0
cpu=$(bmc_dsa_cpu_iface)
[ -n "$cpu" ] || exit 0
apply_bmc_mac "$cpu" br0 || true
exit 0
