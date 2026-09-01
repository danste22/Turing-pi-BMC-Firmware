#!/bin/sh
# One-shot installer for LACP bond profile on a running BMC (no reflash).
set -u

echo "Installing LACP bond profile files..."

cat > /etc/network/interfaces.d/10-bond-lacp << 'EOF'
auto bond0
iface bond0 inet manual
  pre-up /etc/network/tp2-bond-up.sh lacp
  pre-down /etc/network/tp2-bond-down.sh

auto br0
iface br0 inet dhcp
  use bridge
  requires bond0
  bridge-ports node1 node2 node3 node4 bond0
  pre-up /etc/network/nfs_check
  pre-up /etc/network/tp2-bond-wait-lacp.sh bond0 60
  post-up /etc/network/tp2-lag-bridge-fixup-refresh.sh
  udhcpc-opts "-t 25 -T 2"
  wait-delay 15
  hostname $(hostname)
EOF

cat > /etc/network/set_br0_mac_pre_dhcp.sh << 'EOF'
#!/bin/sh
# Apply BMC MAC to dsa/br0 before the first DHCP on br0 (ifupdown-ng pre-up).
if [ ! -f /etc/network/apply_bmc_mac.sh ]; then
	echo "set_br0_mac_pre_dhcp: missing /etc/network/apply_bmc_mac.sh" >&2
	exit 0
fi
# shellcheck source=/dev/null
. /etc/network/apply_bmc_mac.sh

# LACP bond profile: MAC comes from bond0 slaves; never bounce br0 here.
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
EOF

# apply_bmc_mac.sh, tp2-bond-*.sh, S41 — caller must copy from repo or re-run build overlay.
# This script only writes profile + set_br0 guard; patch apply_bmc_mac separately if needed.

cat > /etc/network/tp2-bond-wait-lacp.sh << 'EOF'
#!/bin/sh
BOND=${1:-bond0}
MAX=${2:-60}
lacp_ready() {
	[ -r "/proc/net/bonding/${BOND}" ] || return 1
	grep -q '^MII Status: up' "/proc/net/bonding/${BOND}" || return 1
	grep -A6 'Active Aggregator Info' "/proc/net/bonding/${BOND}" \
		| grep -q 'Number of ports: 2' || return 1
	grep -A6 'Active Aggregator Info' "/proc/net/bonding/${BOND}" \
		| grep -q 'Partner Mac Address: 00:00:00:00:00:00' && return 1
	return 0
}
i=0
while [ "$i" -lt "$MAX" ]; do
	lacp_ready && exit 0
	sleep 1
	i=$((i + 1))
done
echo "tp2-bond-wait: LACP not ready on ${BOND} after ${MAX}s (no partner / <2 ports)" >&2
logger -t tp2-bond-wait "LACP not ready on ${BOND} after ${MAX}s" 2>/dev/null || true
exit 1
EOF

cat > /etc/init.d/S41bond-br0-dhcp << 'EOF'
#!/bin/sh
BOND_PROFILE=/etc/network/interfaces.d/10-bond-lacp
case "$1" in
start|"")
	[ -f "$BOND_PROFILE" ] || exit 0
	ip -4 addr show dev br0 2>/dev/null | grep -q 'inet ' && exit 0
	[ -x /etc/network/tp2-bond-wait-lacp.sh ] && \
		/etc/network/tp2-bond-wait-lacp.sh bond0 60
	bridge link show dev bond0 2>/dev/null | grep -q 'master br0' || \
		ip link set dev bond0 master br0 2>/dev/null || true
	[ -x /etc/network/tp2-lag-bridge-fixup-refresh.sh ] && \
		/etc/network/tp2-lag-bridge-fixup-refresh.sh
	killall udhcpc 2>/dev/null || true
	sleep 1
	udhcpc -i br0 -x "hostname:$(hostname)" -t 25 -T 2 -n 2>/dev/null && exit 0
	udhcpc -b -R -p /var/run/udhcpc.br0.pid -i br0 -x "hostname:$(hostname)" -t 10 -T 2
	;;
stop) ;;
esac
exit 0
EOF

chmod 755 /etc/network/set_br0_mac_pre_dhcp.sh \
	/etc/network/tp2-bond-wait-lacp.sh \
	/etc/init.d/S41bond-br0-dhcp

echo "Done. IMPORTANT: also update /etc/network/apply_bmc_mac.sh (bond profile skips br0)."
echo "Also install /etc/network/tp2-lag-bridge-fixup-refresh.sh from the firmware overlay."
echo "Then: ifdown br0 bond0 --force; echo -n > /run/ifstate; ifup -f bond0; ifup -f br0"
