#!/bin/bash
#
# Static / overridden BMC management MAC and IP (see GitHub #238).
#
# --- Init ordering (why this file is not enough on its own) ---
# `S00dsa` renames the CPU DSA link `eth0` -> `dsa`.  User traffic uses `br0`.
# Buildroot's `S40network` runs `ifup br0` *before* this script is invoked from
# `S93startup`, so the first DHCP DISCOVER can happen with the wrong MAC unless
# something runs earlier.  `/etc/network/set_br0_mac_pre_dhcp.sh` is wired as
# `pre-up` on `iface br0 inet dhcp` so `/etc/tpi.cfg` MAC overrides apply before
# that first DHCP when the override lives on the overlay filesystem.
#
# --- SD card `tpi.ini` ---
# `S93startup` mounts `/mnt/sdcard` first; this script can merge `tpi.ini` into
# `/etc/tpi.cfg`.  If MAC/IP only exist on the SD card, the *first* DHCP may
# still have used the old address; renewing DHCP or bouncing `br0` may be
# required — confirm on hardware before automating a full `ifdown`/`ifup`.
#
# --- DSA / bridge quirks (from #238 discussion) ---
# Reporters saw `permaddr` on DSA ports stay at the locally administered default
# even after `ifconfig` on several netdevs; the client identifier seen on the
# wire follows what the bridge uses when DHCP starts.  `br0` is the intended
# management face; avoid pointing this script at `dsa` or individual `nodeN`
# ports unless we add a dedicated design for that.
#
# --- Security ---
# Values from `tpi.cfg` / `tpi.ini` are still parsed with simple `sed`/`grep`;
# do not inject shell metacharacters into those files (see F10 in
# KERNEL_UPGRADE_LOG.md).

# LAN-facing interface: v2.1+ DSA images use br0; eth0 is renamed to dsa (S00dsa).
set_static_net_iface() {
	if ip link show br0 >/dev/null 2>&1; then
		echo br0
	elif ip link show eth0 >/dev/null 2>&1; then
		echo eth0
	else
		echo ""
	fi
}

WAN_IF=$(set_static_net_iface)
if [ -z "$WAN_IF" ]; then
	echo "setStaticNet: no br0 or eth0; skipping" >&2
	exit 0
fi

if [ -f /etc/tpi.cfg ]; then
	ip=$(sed -n 's/^[[:space:]]*ip[[:space:]]*=[[:space:]]*//p' /etc/tpi.cfg | head -n1 | tr -d '\r')
	mac=$(sed -n 's/^[[:space:]]*mac[[:space:]]*=[[:space:]]*//p' /etc/tpi.cfg | head -n1 | tr -d '\r')
fi
if [ -f /mnt/sdcard/tpi.ini ]; then
	inip=$(sed -n 's/^[[:space:]]*ip[[:space:]]*=[[:space:]]*//p' /mnt/sdcard/tpi.ini | head -n1 | tr -d '\r')
	inmac=$(sed -n 's/^[[:space:]]*mac[[:space:]]*=[[:space:]]*//p' /mnt/sdcard/tpi.ini | head -n1 | tr -d '\r')
	echo input ip:$inip
	echo input mac:$inmac
fi

validate_ip() {
  local  ip=$1
  local  stat=1

  if [[ $ip =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    OIFS=$IFS
    IFS='.'
    ip=($ip)
    IFS=$OIFS
    [[ ${ip[0]} -le 255 && ${ip[1]} -le 255 && ${ip[2]} -le 255 && ${ip[3]} -le 255 ]]
    stat=$?
  fi
  return $stat
}

validate_mac() {
  local mac=$1
  local stat=1

  if [[ $mac =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
    stat=0
  fi

  return $stat
}

# 调用函数来验证MAC地址
if [ -n "${inmac:-}" ]; then
    if validate_mac "$inmac"; then
    if [ "$mac" != "$inmac" ]; then
        mac=$inmac;
        if [ -n "${ip:-}" ]; then
            echo "ip=$ip" > /etc/tpi.cfg
        fi
        echo "mac=$inmac" >> /etc/tpi.cfg
    fi
    else
    echo "MAC $inmac error" > /mnt/sdcard/tpi_ini_err.log
    fi
fi

# 调用函数来验证IP地址
if [ -n "${inip:-}" ]; then
    if validate_ip "$inip"; then
    if [ "$ip" != "$inip" ]; then
        ip=$inip;
        echo "ip=$inip" > /etc/tpi.cfg
        if [ -n "${mac:-}" ]; then
            echo "mac=$mac" >> /etc/tpi.cfg
        fi
    fi
    else
    echo "IP $inip error" >> /mnt/sdcard/tpi_ini_err.log
    fi
fi

# 如果不为空则设置mac
if [ -n "${mac:-}" ]; then
	ifconfig "$WAN_IF" down
	echo set mac: $mac
	ifconfig "$WAN_IF"  hw ether $mac
	ifconfig "$WAN_IF" up
fi
# 如果不为空则设置IP
if [ -n "${ip:-}" ]; then
	echo set ip: $ip
    udhcpc -i "$WAN_IF" -r $ip -n
    if [ $? -eq 0 ]; then
        curip=$(ifconfig "$WAN_IF" | grep 'inet addr:' | grep -v '127.0.0.1' | awk '{print $2}' | cut -d ':' -f 2)
        if [ "$ip" != "$curip" ]; then
            ifconfig "$WAN_IF" $ip up
        fi
    else
        ifconfig "$WAN_IF" $ip up
    fi
fi
