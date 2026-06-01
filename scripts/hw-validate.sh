#!/bin/sh
# Hardware validation — feat/buildroot-2026.02 / kernel 6.18.33
# Run on a flashed BMC:  sh hw-validate.sh | tee /tmp/hw-validate.log
# Manual sections: E (MSD per node), B2 (screen UART), C2 (static IP lab test)

set -u

EXPECTED_KERNEL="6.18.33"
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
	case "$br_mac" in
	c4:ff:84:*) pass "C1 factory OUI on br0" ;;
	02:00:*) fail "C1 br0 still locally administered ($br_mac) — check apply_bmc_mac / S39bmc-mac" ;;
	*) warn "C1 unexpected br0 MAC: $br_mac" ;;
	esac
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

# --- F: DSA smoke ---
section "F — DSA / switch"
if dmesg 2>/dev/null | grep -qi 'RTL8370'; then
	pass "F1 RTL8370MB in dmesg"
else
	fail "F1 no RTL8370 in dmesg"
fi
for p in node1 node2 node3 node4 ge0 ge1 dsa br0; do
	ip link show "$p" >/dev/null 2>&1 && info "F1 netdev: $p" || true
done
ip link show br0 2>/dev/null | grep -q UP && pass "F1 br0 UP" || warn "F1 br0 not UP"

for p in ge1 dsa; do
	if ip link show "$p" >/dev/null 2>&1; then
		speed=$(cat "/sys/class/net/$p/speed" 2>/dev/null || echo ?)
		info "F2 $p speed=${speed}Mb/s"
	fi
done

section "Done"
info "Full log: run with: sh $0 2>&1 | tee $REPORT"
info "Board: $(cat /sys/firmware/devicetree/base/model 2>/dev/null | tr -d '\0')"
info "Commit under test: run on build host: git rev-parse --short HEAD"
