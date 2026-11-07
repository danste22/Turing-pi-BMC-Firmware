#!/bin/sh
# Create bond0 on ge0+ge1 (explicit ip link — reliable on TP2; avoids ifupdown-ng use bond).
# Usage: tp2-bond-up.sh <profile>
#   lacp  — 802.3ad, layer2+3, lacp_rate fast (HW LAG on RTL8370MB)
#   ha    — active-backup, primary ge0

set -u

PROFILE=${1:-lacp}
LOG_TAG=tp2-bond-up
SLAVES="ge0 ge1"
MIIMON=100

log() {
	echo "${LOG_TAG}: $*" >&2
	logger -t "${LOG_TAG}" "$*" 2>/dev/null || true
}

die() {
	log "error: $*"
	exit 1
}

modprobe bonding 2>/dev/null || true
# bonding_masters is a sysfs file on 6.x (CONFIG_BONDING=y), not always a directory
[ -e /sys/class/net/bonding_masters ] || die "bonding driver not available"

case "$PROFILE" in
lacp | 802.3ad) MODE=802.3ad ;;
ha | active-backup) MODE=active-backup ;;
*) die "unknown profile: $PROFILE (use lacp or ha)" ;;
esac

bond_already_ok() {
	ip link show bond0 >/dev/null 2>&1 || return 1
	for _s in $SLAVES; do
		ip link show "$_s" 2>/dev/null | grep -q 'master bond0' || return 1
	done
	case "$MODE" in
	802.3ad)
		grep -q 'Bonding Mode: IEEE 802.3ad' /proc/net/bonding/bond0 2>/dev/null || return 1
		;;
	active-backup)
		grep -q 'Bonding Mode: fault-tolerance (active-backup)' /proc/net/bonding/bond0 2>/dev/null || return 1
		;;
	esac
	return 0
}

# Check before tearing slaves down — otherwise we always recreate.
if bond_already_ok; then
	log "bond0 already configured mode=$MODE slaves=$SLAVES"
	exit 0
fi

for _s in $SLAVES; do
	ip link show "$_s" >/dev/null 2>&1 || die "slave $_s missing"
	ip link set dev "$_s" nomaster 2>/dev/null || true
	ip link set dev "$_s" down 2>/dev/null || true
done

if ip link show bond0 >/dev/null 2>&1; then
	ip link set bond0 down 2>/dev/null || true
	ip link del bond0 2>/dev/null || true
fi

ip link add bond0 type bond mode "$MODE" miimon "$MIIMON" \
	|| die "ip link add bond0 failed"

BOND=/sys/class/net/bond0/bonding
case "$MODE" in
802.3ad)
	[ -w "$BOND/xmit_hash_policy" ] && echo layer2+3 >"$BOND/xmit_hash_policy" 2>/dev/null || true
	[ -w "$BOND/lacp_rate" ] && echo fast >"$BOND/lacp_rate" 2>/dev/null || true
	;;
active-backup)
	[ -w "$BOND/primary" ] && echo ge0 >"$BOND/primary" 2>/dev/null || true
	[ -w "$BOND/primary_reselect" ] && echo failure >"$BOND/primary_reselect" 2>/dev/null || true
	;;
esac

for _s in $SLAVES; do
	ip link set dev "$_s" master bond0 || die "enslave $_s failed"
done

ip link set bond0 up || die "cannot bring bond0 up"
for _s in $SLAVES; do
	ip link set dev "$_s" up 2>/dev/null || true
done

log "bond0 up mode=$MODE slaves=$SLAVES"
if dmesg 2>/dev/null | grep -q "LAG bridge uplink fixup:.*cpu 0x"; then
	_efid=$(dmesg 2>/dev/null | sed -n 's/.*efid \([0-9][0-9]*\).*/\1/p' | tail -1)
	if [ "${_efid:-0}" = "0" ]; then
		log "driver: LAG fixup active but efid 0 (bond before br0) — br0 post-up refresh or ifdown/ifup bond0 after br0"
	else
		log "driver: LAG bridge uplink fixup active efid=${_efid} (net-dsa/0003)"
	fi
elif dmesg 2>/dev/null | grep -q "LAG bridge uplink fixup"; then
	log "warn: egress-only LAG fixup (no cpu in dmesg) — flash kernel with net-dsa/0003 ingress fix"
else
	log "warn: no LAG bridge uplink fixup in dmesg — node WAN may hairpin via eth0 (100M); rebuild kernel with net-dsa/0003"
fi
