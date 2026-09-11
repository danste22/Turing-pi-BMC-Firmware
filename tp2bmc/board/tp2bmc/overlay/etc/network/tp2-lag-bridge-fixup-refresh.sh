#!/bin/sh
# Re-run kernel LAG bridge uplink fixup after br0 is up so ge0/ge1 inherit the
# node bridge EFID. bond0 pre-dates br0 in ifup order, so lag_refresh often runs
# with efid 0 unless node ports have already joined br0 offload.
#
# Kernels with net-dsa/0004 port_bridge_join already call
# rtl8365mb_lag_bridge_fixup_refresh() when nodes join br0 — so a bond0
# ifdown/ifup bounce is usually unnecessary and *breaks* LACP right after
# convergence (partner RX dies until renegotiation). Only bounce when fixup
# has never reported a non-zero efid.

set -u

LOG_TAG=tp2-lag-br-fixup
STAMP=/run/tp2-lag-fixup.ifindex

log() {
	echo "${LOG_TAG}: $*" >&2
	logger -t "${LOG_TAG}" "$*" 2>/dev/null || true
}

# 0004 copies bond0's VLAN DB onto ge0/ge1 only from port_bridge_join / lag
# apply. tp2-net-config programs VLANs *after* those events, so the ASIC
# stays "members transparent" unless a user port rejoins. Do not bounce
# bond0 here — that tears LACP down.
if [ "${1:-}" = "vlan-sync" ]; then
	[ -e /sys/class/net/bond0 ] || exit 0
	[ -e /sys/class/net/br0/bridge ] || exit 0
	[ "$(cat /sys/class/net/br0/bridge/vlan_filtering 2>/dev/null)" = 1 ] || exit 0
	ip link show bond0 2>/dev/null | grep -q 'master br0' || exit 0

	_p=
	for _c in node4 node3 node2 node1; do
		if ip link show "$_c" 2>/dev/null | grep -q 'master br0'; then
			_p=$_c
			break
		fi
	done
	[ -n "$_p" ] || exit 0

	log "vlan-sync: $_p leave/join so ASIC copies bond0 VLAN DB"
	ip link set "$_p" nomaster 2>/dev/null || exit 0
	ip link set "$_p" master br0 2>/dev/null || true
	ip link set "$_p" up 2>/dev/null || true
	exit 0
fi

[ -e /sys/class/net/bond0 ] || exit 0
[ -e /sys/class/net/br0 ] || exit 0
ip link show br0 2>/dev/null | grep -q 'state UP' || exit 0
ip link show bond0 2>/dev/null | grep -q 'master br0' || exit 0
dmesg 2>/dev/null | grep -q 'LAG bridge uplink fixup' || exit 0

bond_ifindex=$(cat /sys/class/net/bond0/ifindex 2>/dev/null || true)
last_efid=$(dmesg 2>/dev/null | sed -n 's/.*efid \([0-9][0-9]*\).*/\1/p' | tail -1)

if [ -n "$bond_ifindex" ] && [ -f "$STAMP" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$bond_ifindex" ]; then
	log "skip refresh (bond0 ifindex=${bond_ifindex} already handled, last efid=${last_efid:-?})"
	exit 0
fi

# Already have a real EFID from bridge_join / lag_refresh — do not bounce bond0.
if [ -n "${last_efid:-}" ] && [ "${last_efid}" != "0" ]; then
	log "skip bond bounce (fixup already efid=${last_efid}; bridge_join refreshes HW)"
	[ -n "$bond_ifindex" ] && echo "$bond_ifindex" >"$STAMP" 2>/dev/null || true
	# Keep bond on br0 without tearing LACP down.
	ip link set dev bond0 master br0 2>/dev/null || true
	ip link set dev bond0 up 2>/dev/null || true
	exit 0
fi

log "refreshing bond0 so LAG fixup sees br0 node EFID (last efid=${last_efid:-0})"
ifdown bond0 --force 2>/dev/null || true
ifup -f bond0 2>/dev/null || /etc/network/tp2-bond-up.sh lacp || exit 0
ip link set dev bond0 master br0 2>/dev/null || true
ip link set dev bond0 up 2>/dev/null || true

bond_ifindex=$(cat /sys/class/net/bond0/ifindex 2>/dev/null || true)
[ -n "$bond_ifindex" ] && echo "$bond_ifindex" >"$STAMP" 2>/dev/null || true

new_efid=$(dmesg 2>/dev/null | sed -n 's/.*efid \([0-9][0-9]*\).*/\1/p' | tail -1)
if [ "${new_efid:-0}" = "0" ]; then
	log "warn: fixup still efid 0 — node DHCP may not reach bond0; flash kernel with 0004 bridge_join"
else
	log "fixup refreshed efid=${new_efid}"
fi
