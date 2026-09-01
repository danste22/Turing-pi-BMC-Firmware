#!/bin/sh
# Wait for LACP aggregator before br0 DHCP (boot: links converge after bond create).
# Usage: tp2-bond-wait-lacp.sh [bond] [max_seconds]
#
# Exit 0 = LACP ready (2 ports, non-zero partner MAC).
# Exit 1 = timed out. Callers must not treat a DHCP lease as proof of uplink —
# broadcasts can still succeed with Partner Mac 00:00:00:00:00:00.

BOND=${1:-bond0}
MAX=${2:-45}

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
