#!/bin/sh
# Apply a MAC override from /etc/tpi.cfg to br0 *before* the first DHCP
# exchange for iface br0 (ifupdown-ng runs this as `pre-up`).
#
# Context: [#238](https://github.com/turing-machines/BMC-Firmware/issues/238) —
# `S93startup` runs *after* `S40network`, so any MAC/IP logic that only ran in
# `/etc/setStaticNet.sh` arrived too late: `udhcpc` had already started on br0
# with the default bridge address.  This hook covers the common case
# "MAC only in persistent /etc/tpi.cfg on the overlay".
#
# SD-card `/mnt/sdcard/tpi.ini` is mounted later (see `S93startup`); overrides
# that live only there are still handled in `/etc/setStaticNet.sh`, which may
# need a DHCP renew / interface bounce if the first DISCOVER used the wrong MAC
# — left as a follow-up once we have a safe pattern on hardware.

TPI_CFG=/etc/tpi.cfg
[ -f "$TPI_CFG" ] || exit 0

mac=$(sed -n 's/^[[:space:]]*mac[[:space:]]*=[[:space:]]*//p' "$TPI_CFG" | head -n1 | tr -d '\r')
[ -n "$mac" ] || exit 0

case "$mac" in
([0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]:[0-9a-fA-F][0-9a-fA-F]) ;;
(*) exit 0 ;;
esac

if ! ip link show br0 >/dev/null 2>&1; then
	exit 0
fi

echo "set_br0_mac_pre_dhcp: applying $mac to br0" >&2
ip link set dev br0 address "$mac" 2>/dev/null || true
exit 0
