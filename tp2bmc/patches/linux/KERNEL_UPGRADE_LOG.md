# TP2 BMC — kernel patch log & production migration

Maintainer notes for Linux **6.18.33** (Buildroot `tp2bmc_defconfig`).  
Patch inventory: `scripts/kernel-patch-tool.sh inventory`.

**See also:** [`dev-docs/tp2-network-uboot-kernel.md`](../../../dev-docs/tp2-network-uboot-kernel.md) — U-Boot vs kernel network split, SMI migration gap, open U-Boot follow-ups.

---

## SMI mux — production status (2026-07-02)

**Merged** into `tp2bmc_defconfig` + `sun8i-t113s-turing-pi2.dtsi` (GPIO SMI on shared PE12/PE13).

Hardware-validated before promotion (`tp2bmc_smi_mux_poc_defconfig`, now removed):

- GPIO SMI + `tpi-i2c-smi-arbiter` on shared PE12/PE13
- RTL8370MB-CG probe, DSA ports (`node1`–`ge1`), `br0` + DHCP
- EEPROM @ `0x50` and RTC @ `0x51` on HW I²C after switch traffic
- Node link on powered slot (`node2` 1G, carrier + `dmesg` link events)

Retired: RTK-over-I²C switch @ `0x5c`, `realtek-smi-i2c`, mv64xxx NOSTART chain (i2c 0002–0005).

---

## Production migration matrix

**Status: completed 2026-07-02** on branch `feat/buildroot-2026.02-pinctrl`.

Legend: **KEEP** carry in tree · **DROP** remove after step · **REPLACE** superseded by upstream · **MERGE** fold into main files · **SUBMIT** send upstream

### Phase A — kernel config (`linux_defconfig`) — **DONE**

| Item | Current production | Target production | Action |
|------|-------------------|-------------------|--------|
| `CONFIG_NET_DSA_REALTEK_SMI` | off | `y` | **MERGE** |
| `CONFIG_NET_DSA_REALTEK_SMI_I2C` | `y` | off | **DROP** |
| `CONFIG_TPI_I2C_SMI_ARBITER` | absent | `y` | **MERGE** |
| `CONFIG_I2C_GPIO` | off | off | unchanged |
| `BR2_LINUX_KERNEL_PATCH` | no `tp2/tpi-smi-mux` | include `tp2/tpi-smi-mux` | **MERGE** |

PoC defconfig (`linux_smi_mux_poc_defconfig`, `tp2bmc_smi_mux_poc_defconfig`) → **DROPPED** (Phase D).

### Phase B — device tree (`sun8i-t113s-turing-pi2.dtsi`) — **DONE**

| Item | Current | Target | Action |
|------|---------|--------|--------|
| `ethernet-switch@5c` on `&i2c2` | RTK I²C child | deleted | **DROP** |
| `switch@smi` platform node | in `*-smi-mux.dtsi` only | in `.dtsi` for all boards | **MERGE** from `sun8i-t113s-turing-pi2-smi-mux.dtsi` |
| `tpi-i2c-smi-arb` | PoC overlay | in `.dtsi` | **MERGE** |
| `&i2c2` `pinctrl-names` | `default` only | `default`, `smi_mode` + empty `pinctrl-1` | **MERGE** |
| `sun8i-t113s-turing-pi2-v2.5.2-smi-mux.dts` | PoC model string | remove; use standard v2.5.2 DTS | **DROP** |
| `sun8i-t113s-turing-pi2-smi-mux.dtsi` | separate include | contents → `.dtsi` | **DROP** file after merge |

### Phase C — FIT / image build — **DONE**

| Item | Current PoC | Target production | Action |
|------|-------------|-------------------|--------|
| `turing-pi2-poc.its` | smi-mux FIT config | standard ITS only | **DROP** |
| `boot-poc.scr` / `install-poc.scr` | config override | standard `boot.scr` | **DROP** |
| `poc_build.sh` gating | PoC branch detection | remove | **DROP** |
| `post_build.sh` / `post_image.sh` PoC paths | conditional smi-mux DTB | build smi-mux DTB from merged `.dtsi` or drop extra DTB name | **MERGE** |

### Phase D — patch directories — **DONE**

#### `patches/linux/tp2/tpi-smi-mux/` (0001–0003)

| Patch | Purpose | Production |
|-------|---------|------------|
| 0001 | DT binding arbiter | **KEEP** (until upstream binding) |
| 0002 | arbiter driver (incl. shared-pin probe / pinctrl / pin release formerly 0004–0006) | **KEEP** (TP2-specific) |
| 0003 | realtek-smi shared-bus bracket | **KEEP** |

**Removed from tree:** former `0004`–`0006` (folded into `0001`–`0003`). PoC DTS/defconfigs/scripts dropped.

Add directory to `BR2_LINUX_KERNEL_PATCH` in `tp2bmc_defconfig` (order: `generic/i2c` → `generic/pwm` → `net-dsa` → `tp2/gpio` → `tp2/power` → `tp2/tpi-smi-mux`).  
Long-term: **SUBMIT** arbiter + binding upstream (optional).

#### `patches/linux/net-dsa/`

| Patch | Purpose | Production |
|-------|---------|------------|
| 0001 | Backport `realtek_forward` through net-next `660a9e399ab0`: bridge, FDB, VLAN, bridge flags, `tag_rtl8_4` REASON handling | **KEEP** until shipped kernel includes the series |
| 0002 | RTL8370MB-CG `0x6368/0x0010` chip row | **KEEP** until upstream adds chip row · **SUBMIT** |
| 0003 | HW LAG/trunk offload (`port_lag_*`, dumb-mode trunk, LACP RMA trap); replaces unused HSR ops | **KEEP** |
| 0004 | LAG bridge uplink fixups (isolation, EFID, VLAN filtering guard, conduit MAC pin, FDB CPU→lag remap) | **KEEP** (TP2 topology) |
| 0005 | PHY autoneg kick on node ports | **KEEP** (TP2 quirk) |

**Removed from tree (superseded — do not re-add):** `0001-net-dsa-tag_rtl8_4-*` (in backport `0001`), old `0002` i2c_addr, duplicate `0003` chip row, `0004` RTK-over-I²C, old `0005` bridge offload, `0006` smi-i2c NOSTART doc, monolithic LAG+fixup `0003-net-dsa-rtl8365mb-hw-lag-bridge-uplink.patch`.

#### `patches/linux/generic/i2c/` (mv64xxx)

| Patch | Purpose | Production SMI |
|-------|---------|----------------|
| 0001 | clear bus errors before xfer | **KEEP** — EEPROM/RTC robustness |
| 0002 | clean up private struct | **DROPPED** — only needed for removed NOSTART chain |
| 0003 | FSM refactor | **DROPPED** — only needed for removed NOSTART chain |
| 0004 | continue after read | **DROPPED** — only needed for removed NOSTART chain |
| 0005 | `I2C_FUNC_NOSTART` / EFR | **DROPPED** — only for removed RTK-over-I²C switch |

Production retains **0001** only unless bench shows regressions without 0002–0004.

#### `patches/linux/tp2/power/` / `tp2/gpio/` / `generic/pwm/`

| Path | Purpose | Production |
|------|---------|------------|
| `tp2/power/0001` | regulator-fixed `preserve-boot-state` | **KEEP** (TP2 warm-reboot) |
| `tp2/power/0002` | gpio-latch SRAM shadow @ `0x0709010c` | **KEEP** (TP2 SPL contract; not mainline-generic) |
| `tp2/gpio/0001` | gpio-aggregator `turing,pi2-nodes` | **KEEP** |
| `generic/pwm/0001–0003` | Allwinner D1/T113 PWM | **KEEP** until upstream |

Former combined `power/0001-power-regulator-fixed-gpio-latch-…` was split into `0001`+`0002` above.

---

## Upstream monitor — `realtek_forward` (bridge / VLAN / FDB offload)

**Backported locally.** When it lands in a kernel version we ship, drop local `net-dsa/0001` and keep only the RTL8370MB-CG chip row if still missing upstream.

| Field | Value |
|-------|--------|
| Series name | `realtek_forward` |
| Subject | `net: dsa: realtek: rtl8365mb: bridge offloading and VLAN support` |
| Author | Luiz Angelo Daros de Luca (based on Alvin Šipraga) |
| v1 Message-ID | `20260331-realtek_forward-v1-0-44fb63033b7e@gmail.com` |
| v1 link | https://patch.msgid.link/20260331-realtek_forward-v1-0-44fb63033b7e@gmail.com |
| Latest tracked | **v13** (2026-06-06) |
| LWN summary | https://lwn.net/Articles/1076755/ |
| Target tree | `linux-net-next` → expect **6.19+** (not in 6.18.33 mainline; locally backported) |
| change-id | `20260323-realtek_forward-1bac3a77c664` |

### What the local backport adds (replacing old `net-dsa/0005`)

- `port_bridge_{join,leave}` via **isolation masks + EFID** (no dot1x trap hack)
- HW **FDB** + `fdb_isolation`, assisted learning on CPU port
- HW **VLAN** filtering / PVID offload
- Bridge port flags; driver split (`rtl8365mb_main/l2/vlan/table.c`, `rtl83xx` ops)
- `tag_rtl8_4` updates (accepted upstream separately and included in local backport)

### What upstream does **not** include (still ours)

- **RTL8370MB-CG** chip table row (`0x6368` / `0x0010`) — keep **`net-dsa/0002`** or submit separately
- **Hardware LAG / trunk** (`port_lag_join`) — keep **`net-dsa/0003`–`0005`**; not in `realtek_forward`
- **`tpi-i2c-smi-arbiter`** / shared PE12/PE13 — TP2-only
- **`realtek-smi-i2c`** — we are dropping this path

### Mode 4 — VLAN DB on LAG members (fixed in `0004`)

`realtek_forward` VLAN offload targets **DSA user ports in the bridge**.
With `bond0` on `br0`, `ge0`/`ge1` are bond slaves, so `port_vlan_add` never
ran for the ASIC trunk ports (Mode 3 flat `ge0` trunk was fine; Mode 4 leaked
untagged native DHCP alongside tagged VLAN DHCP).

**Fix in `0003`:** `rtl8365mb_lag_sync_uplink_vlans()` mirrors `bond0`’s bridge
VLAN DB onto each lag member via `port_vlan_filtering` + `port_vlan_add`,
called from lag refresh and `rtl8365mb_lag_bridge_fixup_refresh()` (after
`tp2-net-config` applies VLANs). Validate with LAN DHCP enabled: nodes must
get only `.10.x`/`.20.x`; `tcpdump -ni lagg0` must not see untagged node DHCP.

### Mode 2 — LACP data plane on the HW trunk (2026-08-31)

Mode 2 (802.3ad `ge0`+`ge1`, flat `br0`, DHCP) had **two independent bugs**
that presented as one. Both are fixed; the sequence below is recorded because
several plausible-looking theories cost days and should not be re-tried.

**Bug 1 — partner LACPDUs never reached bonding.** With the HW trunk
programmed, the ASIC consumes slow-protocol frames itself, so
`/proc/net/bonding/bond0` stayed at `ports: 1` with a zero partner MAC.
Fix: `rtl8365mb_rma_trap_lacp()` in `0003` writes `RMA_CTRL02` (`0x0802`) to
trap `01:80:c2:00:00:02` to the CPU. Linux runs LACP, the ASIC only
aggregates the data plane (dumb mode).

**Bug 2 — VLAN filtering against an empty VLAN table.**
`rtl8365mb_lag_sync_uplink_vlans()` called `port_vlan_filtering(ge0/ge1, true)`
whenever `bond0` sat on a bridge, **without checking whether the bridge was
VLAN filtering**. In Mode 2 `br0` is flat, so `br_vlan_get_info()` failed for
every VID and no membership was programmed — while ingress *and* egress
membership checks were now enforced (the driver also clears transparent-VLAN
toward every other port). The ASIC dropped everything from the uplink except
RMA-trapped frames.

This is why the failure looked so contradictory: **LACP converged perfectly,
ARP/DHCP left the box, OPNsense answered on `lagg0`, and nothing ever arrived
on `ge0`/`ge1`.** It is also why forcing `lag_can_offload` false appeared to
"fix" it — with no `lag_member_pmask` the fixup and VLAN sync never ran.
Fix: follow the bridge via `br_vlan_enabled()`; log and return early when flat.

**Obsolete workaround removed.** `0005` used to clear `skb->offload_fwd_mark`
in `tag_rtl8_4` for all non-LAG ingress while a LAG was active, so the
software bridge would forward node traffic to `bond0`. That existed only
because the ASIC could not forward (Bug 2) and it **forces every node frame
through the 100M CPU port**: measured 94 Mbit/s node→WAN with ~120 MB in each
direction on the conduit for a 112 MB transfer. Removed; the mark is left at
DSA's default so the bridge skips software forwarding and the trunk carries
node traffic in hardware.

**Verified on hardware (kernel 6.18.38, OPNsense `lagg0` = `igb0`+`igb2`):**

| Check | Result |
|-------|--------|
| `/proc/net/bonding/bond0` | `ports: 2`, partner `00:0d:b9:49:07:38`, Collecting+Distributing |
| BMC → gateway / `8.8.8.8` | 0% loss |
| Node → WAN conduit bytes | 11 KB over a 10 s iperf (was 243 MB) — ASIC switched |
| Node → WAN throughput | **207 Mbit/s — not line rate, still open** |

**Dead ends — do not re-try:**

- *Disabling learning on lag members.* Did not help; CPU-tagged TX already
  sets `LEARN_DIS` in the tag. Leaves the ASIC unable to learn uplink MACs,
  so all node→WAN unicast floods and a benchmark can look fast while being
  wrong.
- *Pinning the conduit MAC on a lag member instead of the CPU port.* Replies
  entering on that member are dropped (ingress == egress) and replies on the
  other member are sent back out the uplink. DHCP stops completely.
- *Blaming the `0003`/`0004`/`0005` patch split, tag/mark policy, or dumb
  mode* for the LACP RX failure. None were involved.

**Still unproven:** the conduit MAC pin (`rtl8365mb_lag_pin_conduit_mac`) has
been present in every run, including all failing ones, so it has never been
tested in isolation. Removing it is a one-line experiment.

**Open — 207 Mbit/s cap.** Pre-dates this work (the same ~209 Mbit/s appears
in earlier logs and *was* genuine ASIC offload). Not explained by a gigabit
switch with a 2×1G trunk. Isolate with node→node iperf (stays inside the
ASIC, no trunk) versus node→WAN, plus `/sys/class/net/*/speed`. Note
`ethtool` is **not** in the image; add `BR2_PACKAGE_ETHTOOL=y` before
debugging PHY/pause/counters.

### Adoption checklist (run when series appears in `git tag v6.x`)

1. `kernel-history-tool.sh` / manual: confirm files in `drivers/net/dsa/realtek/`, `net/dsa/tag_rtl8_4.c` match series.
2. Bump `BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE` to that release.
3. **Remove** local `net-dsa/0001-net-dsa-realtek-rtl8365mb-backport-bridge-fdb-vlan-offload.patch`.
4. **Keep** local `net-dsa/0002` until `chip_id == 0x6368` probe works without it.
5. Confirm `tag_rtl8_4` REASON/forward logic is in-tree before removing the backport.
6. Rebuild; run regression: switch probe, `br0`, inter-node throughput (HW hairpin vs CPU), VLAN if used.
7. Update **Monitor log** below with merge commit / kernel version.

### Monitor log (append on check)

| Date | Kernel / tree | Series version | In mainline? | Local action |
|------|---------------|----------------|--------------|--------------|
| 2026-08-31 | 6.18.38 | Mode 2 LACP data plane (`net-dsa/0003`–`0005`) | **No** | LACP RMA trap + VLAN filtering guard; dropped `offload_fwd_mark` clear-all (CPU hairpin). Node→WAN ASIC switched; 207 Mbit/s cap open |
| 2026-07-04 | 6.18.33 | HW LAG offload (`net-dsa/0003`) | **No** | `port_lag_*` + RTL8367C trunk tables for `ge0`+`ge1` bond |
| 2026-07-03 | 6.18.33 | `realtek_forward` merged in net-next through `660a9e399ab0` | **No** | Backported locally as `net-dsa/0001`; old minimal `0005` dropped |
| 2026-07-02 | 6.18.33 | `realtek_forward` v13 on net-next | **No** | Production SMI migration merged; keep `net-dsa/0001`+`0005` until upstream lands |

**Next review:** when bumping past 6.18.x — grep upstream `rtl8365mb` for `port_bridge_join`, `rtl8365mb_l2.c`, `max_num_bridges`.

```bash
# Quick check in a linux.git clone
git fetch origin tag v6.19  # or current target
git log v6.18.33..v6.19 --oneline -- drivers/net/dsa/realtek/ net/dsa/tag_rtl8_4.c
git grep -l port_bridge_join v6.19 -- drivers/net/dsa/realtek/
```

---

## Implementation order (production SMI) — **completed**

1. ~~**Phase B**~~ — smi-mux merged into `sun8i-t113s-turing-pi2.dtsi`; `@5c` switch removed.
2. ~~**Phase A**~~ — `linux_defconfig` + `tp2bmc_defconfig` patch path.
3. ~~**Phase D**~~ — dropped `net-dsa` 0002, 0004, 0006; dropped `i2c` 0002–0005 (kept 0001).
4. ~~**Phase C**~~ — single FIT/boot flow; PoC scripts/defconfigs removed.
5. **Bench** (on hardware): EEPROM, RTC, all node ports, `br0` DHCP, cross-node `iperf`, FDB/VLAN lab checks.
6. On next kernel bump: execute **Upstream monitor** adoption checklist below.

---

## Test plan (production image)

- [ ] `dmesg`: arbiter on `2502800.i2c`, RTL8370MB-CG found, DSA tree setup
- [ ] No PE12 pin conflict; no `pm_runtime` underflow
- [ ] `hexdump` EEPROM MAC matches `br0`
- [ ] `hwclock -r` sane after reboot
- [ ] Per-node: power on → `carrier==1` → link in `dmesg`
- [ ] `br0` DHCP; `ge1` / uplink as today
- [ ] (Optional) `iperf` node↔node — baseline before upstream offload merge
