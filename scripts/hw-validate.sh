#!/bin/sh
# Hardware validation — feat/buildroot-2026.02 / kernel 6.18.33
# Run on a flashed BMC (factory board MAC is not stored in this script):
#   sh hw-validate.sh --mac aa:bb:cc:dd:ee:ff | tee /tmp/hw-validate.log
#   EXPECTED_BOARD_MAC=aa:bb:cc:dd:ee:ff sh hw-validate.sh
# Manual sections: E (MSD per node), B2 (screen UART), C2 (static IP lab test)

set -u

usage() {
	cat <<'EOF'
Usage: hw-validate.sh [--mac ADDR] [ADDR]

  --mac ADDR   Expected factory board MAC on br0 (also: first positional arg)
  ADDR         Same as --mac when the value contains ':'

Environment:
  EXPECTED_BOARD_MAC   Same as --mac

If no MAC is given, section C skips the factory MAC/OUI match (other C checks still run).
EOF
}

normalize_mac() {
	printf '%s' "$1" | tr 'A-F' 'a-f'
}

mac_oui_prefix() {
	# First three octets, e.g. c4:ff:84 from c4:ff:84:10:00:ba
	printf '%s' "$1" | awk -F: '{ if (NF >= 3) print $1":"$2":"$3; }'
}

EXPECTED_KERNEL="6.18.33"
EXPECTED_BOARD_MAC=${EXPECTED_BOARD_MAC:-}

while [ $# -gt 0 ]; do
	case "$1" in
	-h|--help)
		usage
		exit 0
		;;
	--mac)
		if [ $# -lt 2 ]; then
			echo "hw-validate.sh: --mac requires an address" >&2
			exit 1
		fi
		EXPECTED_BOARD_MAC=$2
		shift 2
		;;
	-*)
		echo "hw-validate.sh: unknown option: $1" >&2
		usage >&2
		exit 1
		;;
	*)
		if [ -z "$EXPECTED_BOARD_MAC" ] && printf '%s' "$1" | grep -q ':'; then
			EXPECTED_BOARD_MAC=$1
			shift
		else
			echo "hw-validate.sh: unexpected argument: $1" >&2
			usage >&2
			exit 1
		fi
		;;
	esac
done

if [ -n "$EXPECTED_BOARD_MAC" ]; then
	EXPECTED_BOARD_MAC=$(normalize_mac "$EXPECTED_BOARD_MAC")
	EXPECTED_BOARD_OUI=$(mac_oui_prefix "$EXPECTED_BOARD_MAC")
fi

REPORT=/tmp/hw-validate-"$(date +%Y%m%d-%H%M%S 2>/dev/null || echo run)".log

pass() { printf 'PASS  %s\n' "$1"; }
fail() { printf 'FAIL  %s\n' "$1"; }
warn() { printf 'WARN  %s\n' "$1"; }
skip() { printf 'SKIP  %s\n' "$1"; }
info() { printf '      %s\n' "$1"; }

section() {
	printf '\n=== %s ===\n' "$1"
}

# Drop by-tpi symlinks whose /dev/sdX block device no longer exists (E3 / RockUSB).
cleanup_stale_by_tpi_links() {
	dir=/dev/disk/by-tpi
	[ -d "$dir" ] || return 0
	for n in 1 2 3 4; do
		link="${dir}/node${n}"
		[ -L "$link" ] || continue
		target=$(readlink "$link" 2>/dev/null) || continue
		bname=${target#/dev/}
		[ -n "$bname" ] || continue
		if [ ! -d "/sys/block/${bname}" ]; then
			rm -f "$link"
			info "E3 removed stale ${link} (block ${bname} gone)"
		fi
	done
}

find_i2c_device() {
	addr=$1
	for dev in /sys/bus/i2c/devices/*-"$addr"; do
		[ -e "$dev/name" ] || continue
		printf '%s\n' "$dev"
		return 0
	done
	return 1
}

format_mac_hex() {
	printf '%s' "$1" | sed 's/../&:/g; s/:$//'
}

read_eeprom_mac() {
	eeprom_file=$1
	if command -v hexdump >/dev/null 2>&1; then
		dd if="$eeprom_file" bs=1 skip=44 count=6 2>/dev/null \
			| hexdump -v -e '6/1 "%02x" "\n"'
	elif command -v od >/dev/null 2>&1; then
		dd if="$eeprom_file" bs=1 skip=44 count=6 2>/dev/null \
			| od -An -tx1 | tr -d ' \n'
	else
		return 1
	fi
}

netdev_master() {
	dev=$1
	if [ -e "/sys/class/net/$dev/master" ]; then
		basename "$(readlink "/sys/class/net/$dev/master" 2>/dev/null)"
	fi
}

# --- A: image sanity ---
section "A — Image and toolchain"
kr=$(uname -r 2>/dev/null || echo unknown)
if [ "$kr" = "$EXPECTED_KERNEL" ]; then
	pass "A1 uname -r = $kr"
else
	fail "A1 uname -r = $kr (expected $EXPECTED_KERNEL)"
fi

if command -v tpi >/dev/null 2>&1; then
	pass "A2 tpi present: $(tpi --version 2>/dev/null | head -1)"
else
	fail "A2 tpi not in PATH"
fi

if pidof bmcd >/dev/null 2>&1 || [ -x /usr/bin/bmcd ]; then
	pass "A2 bmcd: $(pidof bmcd 2>/dev/null || echo binary present)"
else
	warn "A2 bmcd not running (may start later)"
fi

info "A3 README version audit — manual on build host"

# --- B: QoL packages ---
section "B — tcpdump, screen, NAND, SysRq"
if command -v tcpdump >/dev/null 2>&1; then
	pass "B1 tcpdump: $(tcpdump --version 2>/dev/null | head -1)"
	if tcpdump -i lo -c 1 >/dev/null 2>&1; then
		pass "B1 tcpdump -i lo -c 1"
	else
		fail "B1 tcpdump -i lo -c 1"
	fi
	if tcpdump -i dsa -c 1 >/dev/null 2>&1; then
		warn "B1 tcpdump -i dsa unexpectedly OK (doc says rtl8_4 tag may fail)"
	else
		pass "B1 tcpdump -i dsa fails as expected (use br0/ge*/node*)"
	fi
else
	fail "B1 tcpdump missing"
fi

if command -v screen >/dev/null 2>&1; then
	pass "B2 screen: $(screen -v 2>/dev/null | head -1)"
	for n in 1 2 3 4; do
		[ -x "/usr/bin/node$n" ] && pass "B2 /usr/bin/node$n exists" || warn "B2 /usr/bin/node$n missing"
	done
	skip "B2 interactive UART — run: node1 (Ctrl-A k to quit)"
else
	fail "B2 screen missing"
fi

if dmesg 2>/dev/null | grep -qi '256.*MiB\|MX35LF2'; then
	pass "B3 SPI NAND 256 MiB (v2.5.x class)"
elif dmesg 2>/dev/null | grep -qi '128.*MiB\|MX35LF1'; then
	pass "B3 SPI NAND 128 MiB (v2.4 class)"
else
	warn "B3 SPI NAND size — check: dmesg | grep -i nand"
fi

sysrq=$(sysctl -n kernel.sysrq 2>/dev/null || cat /proc/sys/kernel/sysrq 2>/dev/null)
if [ "$sysrq" = "0" ]; then
	pass "B4 kernel.sysrq = 0"
else
	warn "B4 kernel.sysrq = ${sysrq:-?} (expected 0 on cold boot)"
fi
grep -q 'kernel.sysrq' /etc/sysctl.conf 2>/dev/null \
	&& pass "B4 /etc/sysctl.conf has sysrq" \
	|| warn "B4 no sysrq in /etc/sysctl.conf"

# --- C: br0 / MAC ---
section "C — br0 / factory MAC (#238)"
if ip link show br0 >/dev/null 2>&1; then
	br_mac=$(ip -br link show br0 2>/dev/null | awk '{print $3}')
	br_ip=$(ip -br addr show br0 2>/dev/null | awk '{print $3}')
	pass "C1 br0 up: mac=$br_mac addr=$br_ip"
	br_mac=$(normalize_mac "$br_mac")
	if [ -n "$EXPECTED_BOARD_MAC" ]; then
		if [ "$br_mac" = "$EXPECTED_BOARD_MAC" ]; then
			pass "C1 board MAC matches expected"
		else
			case "$br_mac" in
			"${EXPECTED_BOARD_OUI}"*)
				pass "C1 factory OUI on br0 (expected prefix $EXPECTED_BOARD_OUI)"
				;;
			*)
				fail "C1 br0 MAC $br_mac (expected $EXPECTED_BOARD_MAC)"
				;;
			esac
		fi
	else
		case "$br_mac" in
		02:00:*) fail "C1 br0 still locally administered ($br_mac) — check apply_bmc_mac / S39bmc-mac" ;;
		esac
		skip "C1 factory MAC check — pass --mac ADDR or EXPECTED_BOARD_MAC"
	fi
else
	fail "C1 br0 missing"
fi

[ -f /etc/network/apply_bmc_mac.sh ] \
	&& pass "C1 apply_bmc_mac.sh present ($(wc -c </etc/network/apply_bmc_mac.sh) bytes)" \
	|| fail "C1 apply_bmc_mac.sh missing"
[ -f /etc/init.d/S39bmc-mac ] && pass "C1 S39bmc-mac present" || warn "C1 S39bmc-mac missing"
grep -q set_br0_mac_pre_dhcp /etc/network/interfaces 2>/dev/null \
	&& pass "C1 pre-up hook in /etc/network/interfaces" \
	|| warn "C1 no set_br0_mac_pre_dhcp in interfaces"

if grep -q apply_bmc_mac /var/log/messages 2>/dev/null; then
	pass "C1 apply_bmc_mac logged on boot"
else
	warn "C1 no apply_bmc_mac in /var/log/messages (syslog empty?)"
fi

skip "C2 static br0 + ping — lab-only manual"
skip "C3 SD tpi.ini MAC — optional manual"

# --- D: boot hygiene ---
section "D — Boot log / kconfig"
if dmesg 2>/dev/null | grep -F 'sunxi_ccu_probe' | grep -q 'No max_rate, ignoring min_rate'; then
	fail "D1 #249 sunxi_ccu_probe No max_rate line present"
else
	pass "D1 no #249 sunxi_ccu No max_rate spam"
fi

if dmesg 2>/dev/null | grep -F 'Fixed dependency cycle' | grep -qE 'mixer@|tcon-top@|lcd-controller@'; then
	fail "D2 DE display dependency-cycle flood still present"
else
	pass "D2 no mixer/tcon/lcd dependency-cycle flood"
fi
dmesg 2>/dev/null | grep -F 'Fixed dependency cycle' | grep -q 'rtc@7090000' \
	&& info "D2 CCU↔RTC cycles present (expected noise)" || true

if dmesg 2>/dev/null | grep -qE 'exFAT-fs|F2FS-fs'; then
	warn "D3 exFAT/F2FS messages in dmesg (review if BMC root card)"
else
	pass "D3 no exFAT/F2FS fs noise in dmesg"
fi

if [ -r /proc/config.gz ]; then
	zcat /proc/config.gz 2>/dev/null | grep -q '^CONFIG_F2FS_FS=' && fail "D4 CONFIG_F2FS_FS=y" || pass "D4 CONFIG_F2FS_FS off"
	zcat /proc/config.gz 2>/dev/null | grep -q '^CONFIG_EXFAT_FS=' && fail "D4 CONFIG_EXFAT_FS=y" || pass "D4 CONFIG_EXFAT_FS off"
elif [ -f "/boot/config-${EXPECTED_KERNEL}" ]; then
	grep -q '^CONFIG_F2FS_FS=y' "/boot/config-${EXPECTED_KERNEL}" && fail "D4 F2FS=y" || pass "D4 F2FS off"
else
	skip "D4 kconfig — no /proc/config.gz"
fi

# --- E: MSD symlinks (static checks only) ---
section "E — #225 MSD by-tpi (static + manual)"
[ -x /usr/bin/mdev-tpi-msd-symlink ] && pass "E mdev-tpi-msd-symlink installed" || fail "E helper missing"
grep -q mdev-tpi-msd-symlink /etc/mdev.conf 2>/dev/null && pass "E mdev.conf hook" || fail "E mdev.conf hook missing"
cleanup_stale_by_tpi_links
if [ -d /dev/disk/by-tpi ]; then
	ls -la /dev/disk/by-tpi/ 2>/dev/null | while read -r line; do info "$line"; done
	pass "E /dev/disk/by-tpi exists"
else
	info "E /dev/disk/by-tpi absent until MSD — manual per node:"
	info "  tpi advanced msd -nN"
	info "  ls -la /dev/disk/by-tpi/"
	info "  readlink -f /dev/disk/by-tpi/nodeN"
	info "  tpi advanced normal -nN"
fi
skip "E1–E4 full matrix — one node at a time (msd/normal per node)"

# --- F: I2C shared bus ---
section "F — I2C / EEPROM / RTC / SMI arbiter"
if dmesg 2>/dev/null | grep -qi 'arbiter on .*i2c'; then
	pass "F1 tpi-i2c-smi-arbiter probe: $(dmesg 2>/dev/null | grep -i 'arbiter on .*i2c' | tail -1)"
else
	fail "F1 no tpi-i2c-smi-arbiter probe line in dmesg"
fi

if eeprom_dev=$(find_i2c_device 0050); then
	eeprom_name=$(cat "$eeprom_dev/name" 2>/dev/null || echo unknown)
	pass "F2 EEPROM present: $(basename "$eeprom_dev") name=$eeprom_name"
	if [ -r "$eeprom_dev/eeprom" ]; then
		eeprom_mac_hex=$(read_eeprom_mac "$eeprom_dev/eeprom" 2>/dev/null || true)
		if [ "${#eeprom_mac_hex}" = 12 ]; then
			eeprom_mac=$(normalize_mac "$(format_mac_hex "$eeprom_mac_hex")")
			pass "F2 EEPROM MAC read: $eeprom_mac"
			if [ -n "$EXPECTED_BOARD_MAC" ]; then
				if [ "$eeprom_mac" = "$EXPECTED_BOARD_MAC" ]; then
					pass "F2 EEPROM MAC matches expected"
				else
					warn "F2 EEPROM MAC $eeprom_mac differs from expected $EXPECTED_BOARD_MAC"
				fi
			fi
		else
			fail "F2 EEPROM read failed or returned ${#eeprom_mac_hex} hex chars"
		fi
	else
		fail "F2 EEPROM sysfs data file missing at $eeprom_dev/eeprom"
	fi
else
	fail "F2 EEPROM @0x50 missing from /sys/bus/i2c/devices"
fi

if rtc_i2c_dev=$(find_i2c_device 0051); then
	pass "F3 RTC I2C device present: $(basename "$rtc_i2c_dev") name=$(cat "$rtc_i2c_dev/name" 2>/dev/null || echo unknown)"
else
	board_model=$(cat /sys/firmware/devicetree/base/model 2>/dev/null | tr -d '\0')
	case "$board_model" in
	*"v2.4"*) skip "F3 RTC @0x51 not expected on v2.4 base DT" ;;
	*) fail "F3 RTC @0x51 missing from /sys/bus/i2c/devices" ;;
	esac
fi

rtc_found=0
for rtc in /sys/class/rtc/rtc*; do
	[ -e "$rtc/name" ] || continue
	rtc_name=$(cat "$rtc/name" 2>/dev/null || echo unknown)
	case "$rtc_name" in
	*pcf8563*|*PCF8563*)
		rtc_found=1
		rtc_dev="/dev/$(basename "$rtc")"
		pass "F3 external RTC present: $(basename "$rtc") name=$rtc_name"
		if command -v hwclock >/dev/null 2>&1; then
			rtc_time=$(hwclock -f "$rtc_dev" -r 2>/dev/null || hwclock -r 2>/dev/null || true)
			if [ -n "$rtc_time" ]; then
				pass "F3 RTC read: $rtc_time"
				printf '%s' "$rtc_time" | grep -q '20[2-9][0-9]' \
					|| warn "F3 RTC time did not include a modern year"
			else
				fail "F3 hwclock could not read $rtc_dev"
			fi
		elif [ -r "$rtc/time" ] && [ -r "$rtc/date" ]; then
			pass "F3 RTC sysfs read: $(cat "$rtc/date" 2>/dev/null) $(cat "$rtc/time" 2>/dev/null)"
		else
			fail "F3 no hwclock and no readable RTC sysfs time"
		fi
		;;
	esac
done
if [ "$rtc_found" = 0 ]; then
	board_model=$(cat /sys/firmware/devicetree/base/model 2>/dev/null | tr -d '\0')
	case "$board_model" in
	*"v2.4"*) skip "F3 external PCF8563 RTC not expected on v2.4 base DT" ;;
	*) fail "F3 external PCF8563 RTC not found" ;;
	esac
fi

if emc_dev=$(find_i2c_device 002f); then
	pass "F4 optional EMC2301 present: $(basename "$emc_dev") name=$(cat "$emc_dev/name" 2>/dev/null || echo unknown)"
else
	warn "F4 optional EMC2301 @0x2f not present (normal unless v2.4 fan mod is populated)"
fi

if dmesg 2>/dev/null | grep -qi 'realtek-smi-i2c\|rtl8365mb-i2c\|I2C_FUNC_NOSTART'; then
	fail "F5 retired RTK-over-I2C/NOSTART path still appears in dmesg"
else
	pass "F5 no retired RTK-over-I2C/NOSTART path in dmesg"
fi

# --- G: DSA smoke ---
section "G — DSA / switch / network interfaces"
if dmesg 2>/dev/null | grep -qi 'RTL8370'; then
	pass "G1 RTL8370MB in dmesg"
else
	fail "G1 no RTL8370 in dmesg"
fi
for p in br0 node1 node2 node3 node4 ge0 ge1; do
	if ip link show "$p" >/dev/null 2>&1; then
		master=$(netdev_master "$p")
		state=$(cat "/sys/class/net/$p/operstate" 2>/dev/null || echo unknown)
		carrier=$(cat "/sys/class/net/$p/carrier" 2>/dev/null || echo n/a)
		info "G2 netdev: $p state=$state carrier=$carrier master=${master:-none}"
		pass "G2 netdev present: $p"
	else
		fail "G2 netdev missing: $p"
	fi
done
if ip link show dsa >/dev/null 2>&1; then
	state=$(cat /sys/class/net/dsa/operstate 2>/dev/null || echo unknown)
	info "G2 optional CPU conduit netdev: dsa state=$state"
else
	skip "G2 no netdev named dsa (OK: this kernel exposes DSA user ports, not necessarily a dsa master name)"
fi
ip link show br0 2>/dev/null | grep -q UP && pass "G2 br0 UP" || warn "G2 br0 not UP"

for p in node1 node2 node3 node4 ge0 ge1; do
	if ip link show "$p" >/dev/null 2>&1; then
		master=$(netdev_master "$p")
		if [ "$p" = ge0 ] || [ "$p" = ge1 ]; then
			if [ -d /sys/class/net/bond0 ]; then
				[ "$master" = bond0 ] && pass "G3 $p enslaved to bond0" \
					|| warn "G3 $p master=${master:-none} (expected bond0 with LACP profile)"
			else
				[ "$master" = br0 ] && pass "G3 $p enslaved to br0" \
					|| warn "G3 $p master=${master:-none} (expected br0)"
			fi
		else
			[ "$master" = br0 ] && pass "G3 $p enslaved to br0" \
				|| warn "G3 $p master=${master:-none} (expected br0)"
		fi
	fi
done

for p in ge1 dsa eth0 end0; do
	if ip link show "$p" >/dev/null 2>&1; then
		speed=$(cat "/sys/class/net/$p/speed" 2>/dev/null || echo ?)
		info "G4 $p speed=${speed}Mb/s"
	fi
done

if command -v bridge >/dev/null 2>&1; then
	bridge_detail=$(bridge -d link show 2>/dev/null || true)
	if printf '%s\n' "$bridge_detail" | grep -qi offload; then
		pass "G5 bridge link reports offload marker"
	else
		skip "G5 bridge link has no visible offload marker (often not exposed by this kernel/iproute2)"
	fi

	if dmesg 2>/dev/null | grep -qiE 'rtl8365mb.*(lag|trunk).*(fail|error)|port_lag.*EOPNOTSUPP'; then
		fail "G5 LAG offload-related error in dmesg"
	elif [ -d "/sys/class/net/bond0" ] && [ -r /proc/net/bonding/bond0 ]; then
		if grep -q "802.3ad" /proc/net/bonding/bond0 2>/dev/null \
		   && grep -q "ge0" /proc/net/bonding/bond0 2>/dev/null \
		   && grep -q "ge1" /proc/net/bonding/bond0 2>/dev/null; then
			if dmesg 2>/dev/null | grep -q "LAG bridge uplink fixup"; then
				pass "G5 bond0 802.3ad ge0+ge1 + LAG bridge uplink fixup (0003)"
			else
				warn "G5 bond0 802.3ad ge0+ge1 but no LAG bridge uplink fixup in dmesg — node WAN may cap at ~100M via eth0; rebuild with net-dsa/0003"
			fi
		else
			warn "G5 bond0 present but not 802.3ad ge0+ge1 (HW LAG not exercised)"
		fi
	else
		info "G5 no bond0 configured (HW LAG not exercised; see README bond0+br0 cookbook)"
	fi

	if dmesg 2>/dev/null | grep -qiE 'rtl8365mb.*bridge.*(fail|error)|dsa.*bridge.*(fail|error)'; then
		fail "G5 bridge offload-related error in dmesg"
	else
		pass "G5 no bridge offload-related errors in dmesg"
	fi

	if [ -r /sys/class/net/br0/bridge/vlan_filtering ]; then
		vlan_filtering=$(cat /sys/class/net/br0/bridge/vlan_filtering 2>/dev/null)
		if [ "$vlan_filtering" = 1 ]; then
			if [ -d /sys/class/net/bond0 ]; then
				warn "G5 br0 vlan_filtering=1 with bond0 — VLAN uplink via bond not validated; see README"
			else
				pass "G5 br0 vlan_filtering=1 (VLAN/PVID offload path; flat ge0/ge1 on br0)"
			fi
		else
			info "G5 br0 vlan_filtering=0 (shipped default; VLAN offload not active)"
		fi
	fi

	fdb_detail=$(bridge -d fdb show br br0 2>/dev/null || bridge -d fdb show 2>/dev/null || true)
	if printf '%s\n' "$fdb_detail" | grep -qi offload; then
		pass "G5 bridge FDB reports offloaded entries"
	else
		info "G5 no offloaded FDB entries visible yet (generate traffic, then rerun bridge -d fdb show br br0)"
	fi
else
	skip "G5 bridge command missing; cannot inspect bridge offload markers"
fi

section "G6 — bond uplink hairpin (needs powered node + traffic)"
if [ -d /sys/class/net/bond0 ] && grep -q "802.3ad" /proc/net/bonding/bond0 2>/dev/null; then
	eth0_speed=$(cat /sys/class/net/eth0/speed 2>/dev/null || echo ?)
	info "G6 eth0 (CPU port) speed=${eth0_speed}Mb/s — must not carry switched node WAN traffic"
	if [ -r /var/run/tp2-uplink-test-eth0-delta ]; then
		delta=$(cat /var/run/tp2-uplink-test-eth0-delta 2>/dev/null || echo 0)
		max=${UPLINK_ETH0_DELTA_MAX:-67108864}
		if [ "$delta" -gt "$max" ] 2>/dev/null; then
			fail "G6 eth0 hairpin delta=${delta} bytes (>${max}) — node WAN via CPU ~100M; need net-dsa/0003"
		else
			pass "G6 eth0 hairpin delta=${delta} bytes (uplink likely ASIC-switched)"
		fi
	elif [ "${UPLINK_HAIRPIN_TEST:-0}" = 1 ] && [ -x /usr/share/tp2/uplink-hairpin-test.sh ]; then
		info "G6 running uplink-hairpin-test (start node iperf during wait)..."
		if /usr/share/tp2/uplink-hairpin-test.sh; then
			pass "G6 uplink-hairpin-test passed"
		else
			fail "G6 uplink-hairpin-test failed"
		fi
	else
		skip "G6 run: UPLINK_HAIRPIN_TEST=1 sh hw-validate.sh (node: iperf3 -c <gw> -t10 during wait) or sh /usr/share/tp2/uplink-hairpin-test.sh"
		info "G6 expect node iperf ~900+ Mbit/s; ~88 Mbit/s = eth0 hairpin before 0004"
	fi
else
	skip "G6 no bond0 802.3ad — uplink hairpin test N/A (flat br0 uses ge0/ge1 on bridge)"
fi

section "Done"
info "Full log: run with: sh $0 [--mac ADDR] 2>&1 | tee $REPORT"
if [ -n "$EXPECTED_BOARD_MAC" ]; then
	info "Expected board MAC: $EXPECTED_BOARD_MAC"
fi
info "Board: $(cat /sys/firmware/devicetree/base/model 2>/dev/null | tr -d '\0')"
info "Commit under test: run on build host: git rev-parse --short HEAD"
