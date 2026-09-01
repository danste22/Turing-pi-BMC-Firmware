#!/bin/sh
# TP2 BMC network configurator — single command for all modes.
# Config: /etc/tp2/network.conf (see network.conf.example)
#
# Usage:
#   tp2-net-config apply              # apply /etc/tp2/network.conf (bond+VLAN+IP)
#   tp2-net-config apply -c FILE      # apply alternate config
#   tp2-net-config show               # dump effective config + kernel state
#   tp2-net-config reset              # flat br0, ge0+ge1 direct, DHCP
#   tp2-net-config pre-up / post-up   # ifupdown hooks (internal)

set -u

CONF=/etc/tp2/network.conf
LOG_TAG=tp2-net-config
NODE_PORTS="node1 node2 node3 node4"
UPLINK_PORTS="ge0 ge1"
ALL_SWITCH_PORTS="$NODE_PORTS $UPLINK_PORTS"
INTERFACES_D=/etc/network/interfaces.d

# --- logging ---

log() {
	echo "${LOG_TAG}: $*" >&2
	logger -t "${LOG_TAG}" "$*" 2>/dev/null || true
}

die() {
	log "error: $*"
	exit 1
}

# --- config parse (simple INI) ---

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
			if (k==key) { print v; found=1; exit }
		}
		END { if (NR && !found) exit 1 }
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

# --- helpers ---

iface_exists() {
	ip link show "$1" >/dev/null 2>&1
}

bond_hw_offload_expected() {
	_mode=$1
	_hash=$2
	case "$_mode" in
	802.3ad | 4)
		case "$_hash" in
		layer2 | layer2+3 | '' ) return 0 ;;
		esac
		;;
	esac
	return 1
}

normalize_bond_mode() {
	_m=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
	case "$_m" in
	0 | balance-rr | rr | round-robin) printf '%s' 'balance-rr' ;;
	1 | active-backup | backup | ha) printf '%s' 'active-backup' ;;
	2 | balance-xor | xor) printf '%s' 'balance-xor' ;;
	3 | broadcast) printf '%s' 'broadcast' ;;
	4 | 802.3ad | lacp) printf '%s' '802.3ad' ;;
	5 | balance-tlb | tlb) printf '%s' 'balance-tlb' ;;
	6 | balance-alb | alb) printf '%s' 'balance-alb' ;;
	*) die "unknown bond mode: $1 (use 802.3ad, active-backup, balance-rr, ...)" ;;
	esac
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

list_vlan_subif_sections() {
	awk '
		/^[[:space:]]*\[vlan\./ {
			line=$0
			gsub(/^[[:space:]]*\[vlan\.|\][[:space:]]*$/, "", line)
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

# --- IP addressing ---

stop_dhcp() {
	killall udhcpc 2>/dev/null || true
	ip addr flush dev br0 scope global 2>/dev/null || true
}

# Override /etc/resolv.conf when [bridge] dns= is set (dhcp or static).
# DHCP often installs the gateway as nameserver; that may not recurse.
apply_dns_from_conf() {
	_dns=$(cfg_get bridge dns '')
	[ -n "$_dns" ] || return 0
	: > /etc/resolv.conf
	for _d in $(comma_to_space "$_dns"); do
		echo "nameserver $_d" >> /etc/resolv.conf
	done
	log "resolv.conf nameserver(s): $_dns (from $CONF)"
}

apply_ip() {
	_ip=$(cfg_get bridge ip 'dhcp' | tr 'A-Z' 'a-z')
	_gw=$(cfg_get bridge gateway '')

	stop_dhcp

	case "$_ip" in
	dhcp | '')
		log "br0: starting DHCP"
		udhcpc -b -R -p /var/run/udhcpc.br0.pid -i br0 \
			-x "hostname:$(hostname)" -t 25 -T 2
		apply_dns_from_conf
		;;
	none | manual)
		log "br0: no IP (manual)"
		;;
	*)
		ip addr add "$_ip" dev br0 || die "failed to set br0 address $_ip"
		log "br0: static $_ip"
		if [ -n "$_gw" ]; then
			ip route replace default via "$_gw" dev br0 \
				|| log "warning: default route via $_gw failed"
		fi
		apply_dns_from_conf
		;;
	esac
}

reset_ip_dhcp() {
	stop_dhcp
	log "br0: starting DHCP (reset)"
	udhcpc -b -R -p /var/run/udhcpc.br0.pid -i br0 \
		-x "hostname:$(hostname)" -t 25 -T 2
}

# --- bond ---

bond_slaves_from_config() {
	_sl=$(cfg_get bond slaves '')
	if [ -n "$_sl" ]; then
		printf '%s' "$_sl"
	else
		printf '%s' "$UPLINK_PORTS"
	fi
}

teardown_bond() {
	iface_exists bond0 || return 0
	for _s in $(bond_slaves_from_config); do
		ip link set "$_s" down 2>/dev/null || true
		ip link set "$_s" nomaster 2>/dev/null || true
	done
	ip link set bond0 down 2>/dev/null || true
	ip link del bond0 2>/dev/null || true
}

setup_bond() {
	if ! cfg_bool bond enabled 0; then
		teardown_bond
		return 0
	fi

	_mode=$(normalize_bond_mode "$(cfg_get bond mode '802.3ad')")
	_miimon=$(cfg_int bond miimon 100)
	_hash=$(cfg_get bond xmit_hash_policy 'layer2+3')
	_primary=$(cfg_get bond primary '')
	_lacp=$(cfg_get bond lacp_rate 'fast')
	_reselect=$(cfg_get bond primary_reselect 'failure')

	modprobe bonding 2>/dev/null || true

	if ! iface_exists bond0; then
		ip link add bond0 type bond mode "$_mode" miimon "$_miimon" || die "failed to create bond0"
	else
		sysfs=/sys/class/net/bond0/bonding
		[ -w "$sysfs/mode" ] && echo "$_mode" >"$sysfs/mode" 2>/dev/null || true
		[ -w "$sysfs/miimon" ] && echo "$_miimon" >"$sysfs/miimon" 2>/dev/null || true
	fi

	case "$_mode" in
	802.3ad)
		[ -w /sys/class/net/bond0/bonding/xmit_hash_policy ] \
			&& echo "$_hash" > /sys/class/net/bond0/bonding/xmit_hash_policy 2>/dev/null || true
		case "$_lacp" in
		fast | slow) ;;
		*) _lacp=fast ;;
		esac
		[ -w /sys/class/net/bond0/bonding/lacp_rate ] \
			&& echo "$_lacp" > /sys/class/net/bond0/bonding/lacp_rate 2>/dev/null || true
		;;
	balance-xor | balance-tlb | balance-alb)
		[ -n "$_hash" ] && [ -w /sys/class/net/bond0/bonding/xmit_hash_policy ] \
			&& echo "$_hash" > /sys/class/net/bond0/bonding/xmit_hash_policy 2>/dev/null || true
		;;
	active-backup)
		if [ -n "$_primary" ] && iface_exists "$_primary"; then
			[ -w /sys/class/net/bond0/bonding/primary ] \
				&& echo "$_primary" > /sys/class/net/bond0/bonding/primary 2>/dev/null || true
		fi
		case "$_reselect" in
		always | better | failure) ;;
		*) _reselect=failure ;;
		esac
		[ -w /sys/class/net/bond0/bonding/primary_reselect ] \
			&& echo "$_reselect" > /sys/class/net/bond0/bonding/primary_reselect 2>/dev/null || true
		;;
	esac

	if bond_hw_offload_expected "$_mode" "$_hash"; then
		log "bond mode $_mode xmit_hash_policy=${_hash:-layer2+3} — RTL8365MB HW LAG expected"
	else
		log "bond mode $_mode — software bonding only (no HW LAG offload)"
	fi

	for _slave in $(bond_slaves_from_config); do
		iface_exists "$_slave" || die "bond slave $_slave missing"
		ip link set "$_slave" nomaster 2>/dev/null || true
		ip link set "$_slave" down || die "cannot set $_slave down (required before enslave)"
		ip link set "$_slave" master bond0 || die "cannot enslave $_slave to bond0"
	done

	ip link set bond0 up || die "cannot bring bond0 up"
	for _slave in $(bond_slaves_from_config); do
		ip link set "$_slave" up 2>/dev/null || true
	done
}

# --- LACP convergence + fixup ---

wait_lacp_and_fixup() {
	if ! cfg_bool bond enabled 0; then
		return 0
	fi

	_mode=$(normalize_bond_mode "$(cfg_get bond mode '802.3ad')")
	_timeout=$(cfg_int bond lacp_timeout 60)

	if [ "$_mode" = "802.3ad" ]; then
		log "waiting for LACP convergence (max ${_timeout}s)..."
		if [ -x /etc/network/tp2-bond-wait-lacp.sh ]; then
			/etc/network/tp2-bond-wait-lacp.sh bond0 "$_timeout"
		else
			sleep 5
		fi
	fi

	if [ -x /etc/network/tp2-lag-bridge-fixup-refresh.sh ]; then
		/etc/network/tp2-lag-bridge-fixup-refresh.sh
	fi
}

# --- bridge membership ---

detach_from_br0() {
	for _p in $ALL_SWITCH_PORTS bond0; do
		ip link set "$_p" nomaster 2>/dev/null || true
	done
}

attach_to_br0() {
	if ! iface_exists br0; then
		ip link add name br0 type bridge || die "failed to create br0"
	fi

	for _p in $NODE_PORTS; do
		iface_exists "$_p" || die "missing $_p"
		ip link set "$_p" master br0 || die "cannot attach $_p to br0"
		ip link set "$_p" up 2>/dev/null || true
	done

	if cfg_bool bond enabled 0; then
		iface_exists bond0 || die "bond0 missing"
		ip link set bond0 master br0 || die "cannot attach bond0 to br0"
	else
		for _p in $UPLINK_PORTS; do
			iface_exists "$_p" || die "missing $_p"
			ip link set "$_p" master br0 || die "cannot attach $_p to br0"
			ip link set "$_p" up 2>/dev/null || true
		done
	fi
}

# --- VLAN ---

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

	if cfg_bool bond enabled 0; then
		case "$_port" in
		ge0 | ge1)
			log "skip port.$_port VLAN (enslaved to bond0; use port.bond0)"
			return 0
			;;
		esac
	fi

	iface_exists "$_port" || die "port.$_port: netdev $_port not found"

	case "$_mode" in
	access)
		_vid=$(cfg_int "port.$_port" vlan 0)
		[ "$_vid" -gt 0 ] || die "port.$_port access mode requires vlan="
		validate_vid "$_vid"
		bridge vlan add dev "$_port" vid "$_vid" pvid untagged \
			|| die "bridge vlan add access $_port vid $_vid"
		bridge vlan add dev br0 vid "$_vid" self 2>/dev/null || true
		;;
	trunk)
		_native=$(cfg_int "port.$_port" native 1)
		validate_vid "$_native"
		_vlans=$(cfg_get "port.$_port" vlans '')
		[ -n "$_vlans" ] || die "port.$_port trunk mode requires vlans="
		bridge vlan add dev "$_port" vid "$_native" pvid untagged \
			|| die "bridge vlan native $_port vid $_native"
		bridge vlan add dev br0 vid "$_native" self 2>/dev/null || true
		for _v in $(comma_to_space "$_vlans"); do
			validate_vid "$_v"
			if [ "$_v" = "$_native" ]; then
				continue
			fi
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

apply_vlan_subifs() {
	_parent=$1
	iface_exists "$_parent" || die "vlan.$_parent: parent $_parent not found"
	_ids=$(cfg_get "vlan.$_parent" ids '')
	[ -n "$_ids" ] || return 0
	_up=$(cfg_get "vlan.$_parent" up '1')
	for _id in $(comma_to_space "$_ids"); do
		validate_vid "$_id"
		_if="${_parent}.${_id}"
		if ! iface_exists "$_if"; then
			ip link add link "$_parent" name "$_if" type vlan id "$_id" \
				|| die "failed to create $_if"
		fi
		case "$_up" in
		1 | yes | true | on) ip link set "$_if" up 2>/dev/null || true ;;
		esac
	done
}

apply_vlans() {
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

	for _p in $ALL_SWITCH_PORTS bond0 br0; do
		clear_port_vlans "$_p"
	done

	for _p in $(list_port_sections); do
		apply_port_vlan "$_p"
	done

	for _p in $(list_vlan_subif_sections); do
		apply_vlan_subifs "$_p"
	done

	# Host stack on br0 needs a PVID when vlan_filtering=1 (DHCP/ARP from BMC).
	if [ "$_filtering" -eq 1 ]; then
		apply_br0_host_pvid
	fi
}

# Native/PVID for br0 itself (from uplink trunk native=, else 1).
apply_br0_host_pvid() {
	_native=1
	for _p in bond0 ge0 ge1; do
		_mode=$(cfg_get "port.$_p" mode '' | tr 'A-Z' 'a-z')
		if [ "$_mode" = "trunk" ]; then
			_native=$(cfg_int "port.$_p" native 1)
			break
		fi
	done
	validate_vid "$_native"
	bridge vlan add dev br0 vid "$_native" pvid untagged self \
		|| die "bridge vlan br0 host PVID $_native"
}

# --- interfaces file generation ---

write_interfaces_profile() {
	_bond_enabled=0
	_ip="dhcp"
	_gw=""
	_dns=""
	_mode="802.3ad"

	if [ -r "$CONF" ]; then
		cfg_bool bond enabled 0 && _bond_enabled=1
		_ip=$(cfg_get bridge ip 'dhcp' | tr 'A-Z' 'a-z')
		_gw=$(cfg_get bridge gateway '')
		_dns=$(cfg_get bridge dns '')
		_mode=$(normalize_bond_mode "$(cfg_get bond mode '802.3ad')")
	fi

	rm -f "$INTERFACES_D"/00-br0-flat "$INTERFACES_D"/00-br0-flat.disabled \
		"$INTERFACES_D"/10-bond-lacp 2>/dev/null || true

	if [ "$_bond_enabled" -eq 1 ]; then
		_file="$INTERFACES_D/10-bond-lacp"

		case "$_mode" in
		802.3ad) _profile_arg="lacp" ;;
		active-backup) _profile_arg="ha" ;;
		*) _profile_arg="lacp" ;;
		esac

		cat > "$_file" <<ENDPROFILE
# Generated by tp2-net-config from $CONF

auto bond0
iface bond0 inet manual
  pre-up /etc/network/tp2-bond-up.sh $_profile_arg
  pre-down /etc/network/tp2-bond-down.sh

auto br0
ENDPROFILE

		case "$_ip" in
		dhcp | '')
			cat >> "$_file" <<ENDPROFILE
iface br0 inet dhcp
  use bridge
  requires bond0
  bridge-ports $NODE_PORTS bond0
  pre-up /etc/network/nfs_check
  pre-up /etc/network/tp2-bond-wait-lacp.sh bond0 60
  post-up /etc/network/tp2-lag-bridge-fixup-refresh.sh
  udhcpc-opts "-t 25 -T 2"
  wait-delay 15
  hostname \$(hostname)
ENDPROFILE
			;;
		none | manual)
			cat >> "$_file" <<ENDPROFILE
iface br0 inet manual
  use bridge
  requires bond0
  bridge-ports $NODE_PORTS bond0
  pre-up /etc/network/nfs_check
  pre-up /etc/network/tp2-bond-wait-lacp.sh bond0 60
  post-up /etc/network/tp2-lag-bridge-fixup-refresh.sh
ENDPROFILE
			;;
		*)
			_addr=$(echo "$_ip" | cut -d/ -f1)
			_mask=$(echo "$_ip" | grep '/' | cut -d/ -f2)
			[ -z "$_mask" ] && _mask=24
			cat >> "$_file" <<ENDPROFILE
iface br0 inet static
  use bridge
  requires bond0
  bridge-ports $NODE_PORTS bond0
  address $_addr
  netmask $_mask
ENDPROFILE
			[ -n "$_gw" ] && echo "  gateway $_gw" >> "$_file"
			[ -n "$_dns" ] && echo "  dns-nameservers $_dns" >> "$_file"
			cat >> "$_file" <<ENDPROFILE
  pre-up /etc/network/nfs_check
  pre-up /etc/network/tp2-bond-wait-lacp.sh bond0 60
  post-up /etc/network/tp2-lag-bridge-fixup-refresh.sh
ENDPROFILE
			;;
		esac

		log "wrote $_file (bond $_mode, ip=$_ip)"
	else
		_file="$INTERFACES_D/00-br0-flat"

		case "$_ip" in
		dhcp | '')
			cat > "$_file" <<ENDPROFILE
# Generated by tp2-net-config from $CONF

auto br0
iface br0 inet dhcp
  use bridge
  bridge-ports $NODE_PORTS $UPLINK_PORTS
  pre-up /etc/network/nfs_check
  pre-up /etc/network/set_br0_mac_pre_dhcp.sh
  wait-delay 15
  hostname \$(hostname)
ENDPROFILE
			;;
		none | manual)
			cat > "$_file" <<ENDPROFILE
# Generated by tp2-net-config from $CONF

auto br0
iface br0 inet manual
  use bridge
  bridge-ports $NODE_PORTS $UPLINK_PORTS
  pre-up /etc/network/nfs_check
ENDPROFILE
			;;
		*)
			_addr=$(echo "$_ip" | cut -d/ -f1)
			_mask=$(echo "$_ip" | grep '/' | cut -d/ -f2)
			[ -z "$_mask" ] && _mask=24
			cat > "$_file" <<ENDPROFILE
# Generated by tp2-net-config from $CONF

auto br0
iface br0 inet static
  use bridge
  bridge-ports $NODE_PORTS $UPLINK_PORTS
  address $_addr
  netmask $_mask
ENDPROFILE
			[ -n "$_gw" ] && echo "  gateway $_gw" >> "$_file"
			[ -n "$_dns" ] && echo "  dns-nameservers $_dns" >> "$_file"
			cat >> "$_file" <<ENDPROFILE
  pre-up /etc/network/nfs_check
ENDPROFILE
			;;
		esac

		log "wrote $_file (flat, ip=$_ip)"
	fi
}

write_flat_profile() {
	rm -f "$INTERFACES_D"/10-bond-lacp 2>/dev/null || true
	rm -f "$INTERFACES_D"/00-br0-flat.disabled 2>/dev/null || true
	cat > "$INTERFACES_D/00-br0-flat" <<'ENDPROFILE'
# Shipped default — flat br0 (node1–4 + ge0 + ge1, DHCP on br0).

auto br0
iface br0 inet dhcp
  use bridge
  bridge-ports node1 node2 node3 node4 ge0 ge1
  pre-up /etc/network/nfs_check
  pre-up /etc/network/set_br0_mac_pre_dhcp.sh
  wait-delay 15
  hostname $(hostname)
ENDPROFILE
	log "wrote $INTERFACES_D/00-br0-flat (factory default)"
}

# --- commands ---

cmd_apply() {
	[ -r "$CONF" ] || die "config not found: $CONF (copy network.conf.example)"

	log "applying $CONF"

	stop_dhcp

	if iface_exists br0; then
		ifdown br0 2>/dev/null || ip link set br0 down 2>/dev/null || true
	fi

	detach_from_br0
	setup_bond
	attach_to_br0
	apply_vlans

	ip link set br0 up || die "cannot bring br0 up"

	wait_lacp_and_fixup
	apply_ip
	write_interfaces_profile

	log "apply complete — run 'tp2-net-config show' to verify"
}

cmd_reset() {
	log "resetting to flat br0 (no bond, no VLAN filtering, DHCP)"

	stop_dhcp

	if iface_exists br0; then
		ifdown br0 2>/dev/null || ip link set br0 down 2>/dev/null || true
	fi

	for _p in $ALL_SWITCH_PORTS bond0 br0; do
		clear_port_vlans "$_p" 2>/dev/null || true
	done

	detach_from_br0
	teardown_bond
	attach_to_br0

	ip link set br0 type bridge vlan_filtering 0 2>/dev/null || true
	ip link set br0 up 2>/dev/null || true

	reset_ip_dhcp
	write_flat_profile

	log "reset complete (flat br0, ge0+ge1 direct, DHCP)"
}

# True if network.conf needs a full apply after boot (bond or per-port VLANs).
# Flat factory (bond=0, no [port.*]) is handled by interfaces.d alone.
conf_needs_boot_apply() {
	[ -r "$CONF" ] || return 1
	cfg_bool bond enabled 0 && return 0
	for _p in $(list_port_sections); do
		[ -n "$(cfg_get "port.$_p" mode '')" ] && return 0
	done
	return 1
}

# Called from S42tp2-net-config after S40network so Mode 2–4 survive reboot.
cmd_boot() {
	if ! conf_needs_boot_apply; then
		exit 0
	fi
	log "boot: re-applying $CONF (bond/VLAN not in interfaces.d alone)"
	cmd_apply
}

cmd_show() {
	if [ -r "$CONF" ]; then
		echo "# config: $CONF"
		echo "[bridge] ip=$(cfg_get bridge ip dhcp) vlan_filtering=$(cfg_get bridge vlan_filtering 0)"
		echo "[bond] enabled=$(cfg_get bond enabled 0) mode=$(cfg_get bond mode 802.3ad) xmit_hash_policy=$(cfg_get bond xmit_hash_policy layer2+3)"
		for _p in $(list_port_sections); do
			echo "[port.$_p] mode=$(cfg_get "port.$_p" mode) vlan=$(cfg_get "port.$_p" vlan) native=$(cfg_get "port.$_p" native) vlans=$(cfg_get "port.$_p" vlans)"
		done
	else
		echo "# no $CONF (using factory flat br0)"
	fi
	echo "--- kernel ---"
	ip -4 addr show dev br0 2>/dev/null | grep -E '^\s+inet' || echo "br0: no IPv4"
	ip -br link show type bridge 2>/dev/null || true
	ip -br link show type bond 2>/dev/null || true
	[ -d /sys/class/net/br0/bridge ] && \
		echo "br0 vlan_filtering=$(cat /sys/class/net/br0/bridge/vlan_filtering 2>/dev/null)"
	bridge link 2>/dev/null || true
	bridge vlan show 2>/dev/null || true
	[ -r /proc/net/bonding/bond0 ] && head -20 /proc/net/bonding/bond0
	dmesg 2>/dev/null | grep 'LAG bridge uplink fixup' | tail -3
}

hook_pre_up() {
	[ -r "$CONF" ] || exit 0
	cfg_bool bond enabled 0 || exit 0
	setup_bond
}

hook_post_up() {
	[ -r "$CONF" ] || exit 0
	# Prefer S42tp2-net-config boot apply; this is a light fallback for ifup.
	conf_needs_boot_apply || exit 0
	apply_vlans
}

usage() {
	cat <<'EOF'
Usage: tp2-net-config <command> [-c /etc/tp2/network.conf]

Commands:
  apply              Apply config: bond + VLAN + IP addressing + persist
  reset              Factory flat br0 (ge0+ge1 direct, DHCP) + persist
  boot               Re-apply on boot if bond or [port.*] VLANs are configured
  show               Print config summary and kernel bridge/bond/VLAN state
  pre-up             ifupdown hook: create bond before bridge-ports attach
  post-up            ifupdown hook: VLAN rules after br0 is up

Config sections:
  [bridge]  ip=dhcp|<CIDR>|none  gateway=  dns=  vlan_filtering=0|1
  [bond]    enabled=0|1  mode=802.3ad|active-backup|...
  [port.X]  mode=access vlan=<id>  |  mode=trunk native=<id> vlans=<id>,<id>
  [vlan.X]  ids=100,200 up=1

Examples:
  # Flat DHCP (factory default):
  [bond]
  enabled=0

  # LACP + DHCP:
  [bond]
  enabled=1
  mode=802.3ad

  # LACP + static IP:
  [bond]
  enabled=1
  mode=802.3ad
  [bridge]
  ip=192.168.1.50/24
  gateway=192.168.1.1
  dns=192.168.1.1

See /etc/tp2/network.conf.example
EOF
}

# --- main ---

cmd=show
while [ $# -gt 0 ]; do
	case "$1" in
	apply | reset | boot | show | pre-up | post-up)
		cmd=$1
		shift
		;;
	-c | --config)
		shift
		[ $# -gt 0 ] || die "-c requires a path"
		CONF=$1
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	*)
		die "unknown argument: $1"
		;;
	esac
done

case "$cmd" in
apply) cmd_apply ;;
reset) cmd_reset ;;
boot) cmd_boot ;;
show) cmd_show ;;
pre-up) hook_pre_up ;;
post-up) hook_post_up ;;
esac
