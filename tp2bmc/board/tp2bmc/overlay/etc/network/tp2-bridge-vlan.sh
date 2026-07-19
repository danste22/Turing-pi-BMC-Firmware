#!/bin/sh
# DSA bridge port VLAN programming (access/trunk) for RTL8365MB offload path.
# Bonding, br0 membership, and 802.1Q subifs belong in /etc/network/interfaces.
#
# Config: /etc/tp2/bridge-vlan.conf (see bridge-vlan.conf.example)
#
# Usage:
#   tp2-bridge-vlan apply [-c FILE]
#   tp2-bridge-vlan clear [-c FILE]
#   tp2-bridge-vlan show [-c FILE]

set -u

CONF=/etc/tp2/bridge-vlan.conf
LOG_TAG=tp2-bridge-vlan
NODE_PORTS="node1 node2 node3 node4"
UPLINK_PORTS="ge0 ge1"
ALL_PORTS="$NODE_PORTS $UPLINK_PORTS bond0 br0"

log() {
	echo "${LOG_TAG}: $*" >&2
	logger -t "${LOG_TAG}" "$*" 2>/dev/null || true
}

die() {
	log "error: $*"
	exit 1
}

cfg_get() {
	_section=$1
	_key=$2
	_default=${3:-}
	awk -F= -v sec="$_section" -v key="$_key" '
		BEGIN { in_sec=0 }
		/^[[:space:]]*#/ { next }
		/^[[:space:]]*;/ { next }
		/^[[:space:]]*\[/ {
			line=$0
			gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", line)
			in_sec=(line==sec)
			next
		}
		in_sec && $1 ~ /^[[:space:]]*[^[:space:]]+[[:space:]]*$/ {
			k=$1
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
			v=$2
			for (i=3; i<=NF; i++) v=v FS $i
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
			if (k==key) { print v; exit }
		}
	' "$CONF" 2>/dev/null || printf '%s' "$_default"
}

cfg_bool() {
	case "$(cfg_get "$1" "$2" "${3:-0}" | tr 'A-Z' 'a-z')" in
	1 | yes | true | on) return 0 ;;
	*) return 1 ;;
	esac
}

cfg_int() {
	_val=$(cfg_get "$1" "$2" "${3:-}")
	case "$_val" in
	'' | *[!0-9]*) printf '%s' "${3:-0}" ;;
	*) printf '%s' "$_val" ;;
	esac
}

iface_exists() {
	ip link show "$1" >/dev/null 2>&1
}

port_is_bond_slave() {
	_dev=$1
	[ -e "/sys/class/net/$_dev/master" ] || return 1
	[ "$(basename "$(readlink -f "/sys/class/net/$_dev/master" 2>/dev/null)")" = bond0 ]
}

list_port_sections() {
	awk '
		/^[[:space:]]*\[port\./ {
			line=$0
			gsub(/^[[:space:]]*\[port\.|\][[:space:]]*$/, "", line)
			print line
		}
	' "$CONF"
}

comma_to_space() {
	printf '%s' "$1" | tr ',' ' '
}

validate_vid() {
	_v=$1
	case "$_v" in
	*[!0-9]*) die "invalid VLAN id: $_v" ;;
	esac
	[ "$_v" -ge 1 ] && [ "$_v" -le 4094 ] || die "VLAN id out of range (1-4094): $_v"
}

clear_port_vlans() {
	_dev=$1
	for _vid in $(bridge vlan show dev "$_dev" 2>/dev/null \
		| awk '/^[[:space:]]*[0-9]+/ { print $1 } /^[^[:space:]]/ { print $2 }' \
		| grep -E '^[0-9]+$' | sort -u); do
		bridge vlan del dev "$_dev" vid "$_vid" 2>/dev/null || true
	done
}

apply_port_vlan() {
	_port=$1
	_mode=$(cfg_get "port.$_port" mode '' | tr 'A-Z' 'a-z')
	[ -n "$_mode" ] || return 0

	case "$_port" in
	ge0 | ge1)
		if port_is_bond_slave "$_port"; then
			log "skip port.$_port (bond slave; configure [port.bond0] instead)"
			return 0
		fi
		;;
	esac

	iface_exists "$_port" || die "port.$_port: netdev $_port not found"

	case "$_mode" in
	access)
		_vid=$(cfg_int "port.$_port" vlan 0)
		[ "$_vid" -gt 0 ] || die "port.$_port access requires vlan="
		validate_vid "$_vid"
		bridge vlan add dev "$_port" vid "$_vid" pvid untagged \
			|| die "bridge vlan add access $_port vid $_vid"
		bridge vlan add dev br0 vid "$_vid" self 2>/dev/null || true
		;;
	trunk)
		_native=$(cfg_int "port.$_port" native 1)
		validate_vid "$_native"
		_vlans=$(cfg_get "port.$_port" vlans '')
		[ -n "$_vlans" ] || die "port.$_port trunk requires vlans="
		bridge vlan add dev "$_port" vid "$_native" pvid untagged \
			|| die "bridge vlan native $_port vid $_native"
		bridge vlan add dev br0 vid "$_native" self 2>/dev/null || true
		for _v in $(comma_to_space "$_vlans"); do
			validate_vid "$_v"
			[ "$_v" = "$_native" ] && continue
			bridge vlan add dev "$_port" vid "$_v" \
				|| die "bridge vlan add trunk $_port vid $_v"
			bridge vlan add dev br0 vid "$_v" self 2>/dev/null || true
		done
		;;
	*)
		die "port.$_port unknown mode=$_mode (use access or trunk)"
		;;
	esac
}

cmd_apply() {
	if [ ! -r "$CONF" ]; then
		log "no $CONF — skipping bridge VLAN apply (flat br0)"
		return 0
	fi

	iface_exists br0 || die "br0 not present (ifup br0 first)"

	_filtering=0
	if cfg_bool bridge vlan_filtering 0; then
		_filtering=1
	fi
	for _p in $(list_port_sections); do
		[ -n "$(cfg_get "port.$_p" mode '')" ] && _filtering=1
	done

	if [ "$_filtering" -eq 1 ]; then
		ip link set br0 type bridge vlan_filtering 1 \
			|| die "failed to enable bridge vlan_filtering"
	fi

	for _p in $ALL_PORTS; do
		iface_exists "$_p" && clear_port_vlans "$_p"
	done

	for _p in $(list_port_sections); do
		apply_port_vlan "$_p"
	done

	log "applied $CONF"
}

cmd_clear() {
	for _p in $ALL_PORTS; do
		iface_exists "$_p" && clear_port_vlans "$_p"
	done
	iface_exists br0 && ip link set br0 type bridge vlan_filtering 0 2>/dev/null || true
	log "cleared bridge VLAN rules"
}

cmd_show() {
	if [ -r "$CONF" ]; then
		echo "# config: $CONF"
		echo "[bridge] vlan_filtering=$(cfg_get bridge vlan_filtering 0)"
		for _p in $(list_port_sections); do
			echo "[port.$_p] mode=$(cfg_get port.$_p mode) vlan=$(cfg_get port.$_p vlan) native=$(cfg_get port.$_p native) vlans=$(cfg_get port.$_p vlans)"
		done
	else
		echo "# no $CONF"
	fi
	echo "--- kernel ---"
	[ -d /sys/class/net/br0/bridge ] && \
		echo "br0 vlan_filtering=$(cat /sys/class/net/br0/bridge/vlan_filtering 2>/dev/null)"
	bridge vlan show 2>/dev/null || true
}

usage() {
	cat <<'EOF'
Usage: tp2-bridge-vlan <apply|clear|show> [-c /etc/tp2/bridge-vlan.conf]

Programs DSA port VLAN tables via bridge vlan (ASIC offload when vlan_filtering=1).
Bonding and br0 topology are configured in /etc/network/interfaces — see
/usr/share/tp2/interfaces.examples/README and profile templates.

Port sections in bridge-vlan.conf:
  [port.<netdev>]  mode=access  vlan=<id>
  [port.<netdev>]  mode=trunk   native=<id>  vlans=<id>[,<id>...]

Use [port.bond0] for uplink VLAN when ge0/ge1 are bond slaves.
EOF
}

cmd=show
while [ $# -gt 0 ]; do
	case "$1" in
	apply | clear | show) cmd=$1; shift ;;
	-c | --config)
		shift
		[ $# -gt 0 ] || die "-c requires a path"
		CONF=$1
		shift
		;;
	-h | --help) usage; exit 0 ;;
	*) die "unknown argument: $1" ;;
	esac
done

case "$cmd" in
apply) cmd_apply ;;
clear) cmd_clear ;;
show) cmd_show ;;
esac
