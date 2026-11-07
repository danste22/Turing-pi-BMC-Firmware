#!/bin/sh
# Apply BMC MAC to dsa/br0 before the first DHCP on br0 (ifupdown-ng pre-up).
if [ ! -f /etc/network/apply_bmc_mac.sh ]; then
	echo "set_br0_mac_pre_dhcp: missing /etc/network/apply_bmc_mac.sh" >&2
	exit 0
fi
# shellcheck source=/dev/null
. /etc/network/apply_bmc_mac.sh

# bond profile: bouncing br0 releases bond0 from the bridge; MAC comes from bond slaves.
if [ -f /etc/network/interfaces.d/10-bond-lacp ]; then
	exit 0
fi

if [ -r /proc/net/bonding/bond0 ] 2>/dev/null; then
	exit 0
fi

ip link show br0 >/dev/null 2>&1 || exit 0
cpu=$(bmc_dsa_cpu_iface)
[ -n "$cpu" ] || exit 0
apply_bmc_mac "$cpu" br0 || true
exit 0
