#!/bin/sh
# Re-run kernel LAG bridge uplink fixup after br0 is up so ge0/ge1 inherit the
# node bridge EFID. bond0 pre-dates br0 in ifup order, so lag_refresh often runs
# with efid 0 unless node ports have already joined br0 offload.
#
# On kernels with net-dsa/0003 bridge_join hook this is usually redundant; harmless.

set -u

LOG_TAG=tp2-lag-br-fixup

log() {
	echo "${LOG_TAG}: $*" >&2
	logger -t "${LOG_TAG}" "$*" 2>/dev/null || true
}

[ -e /sys/class/net/bond0 ] || exit 0
[ -e /sys/class/net/br0 ] || exit 0
ip link show br0 2>/dev/null | grep -q 'state UP' || exit 0
ip link show bond0 2>/dev/null | grep -q 'master br0' || exit 0
dmesg 2>/dev/null | grep -q 'LAG bridge uplink fixup' || exit 0

last_efid=$(dmesg 2>/dev/null | sed -n 's/.*efid \([0-9][0-9]*\).*/\1/p' | tail -1)
if [ "${last_efid:-0}" != "0" ]; then
	log "skip refresh (last fixup efid=${last_efid})"
	exit 0
fi

log "refreshing bond0 so LAG fixup sees br0 node EFID (was efid 0)"
ifdown bond0 --force 2>/dev/null || true
ifup -f bond0 2>/dev/null || /etc/network/tp2-bond-up.sh lacp || exit 0
ip link set dev bond0 master br0 2>/dev/null || true
ip link set dev bond0 up 2>/dev/null || true

new_efid=$(dmesg 2>/dev/null | sed -n 's/.*efid \([0-9][0-9]*\).*/\1/p' | tail -1)
if [ "${new_efid:-0}" = "0" ]; then
	log "warn: fixup still efid 0 — node DHCP may not reach bond0; flash kernel with 0004 bridge_join"
else
	log "fixup refreshed efid=${new_efid}"
fi
