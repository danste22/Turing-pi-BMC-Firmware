# TP2 BMC — kernel patch log & production migration

Maintainer notes for Linux **6.18.33** (Buildroot `tp2bmc_defconfig`).  
Patch inventory: `scripts/kernel-patch-tool.sh inventory`.

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
| `BR2_LINUX_KERNEL_PATCH` | no `tpi-smi-mux` | include `tpi-smi-mux` | **MERGE** |

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

#### `patches/linux/tpi-smi-mux/` (0001–0006)

| Patch | Purpose | Production |
|-------|---------|------------|
| 0001 | DT binding arbiter | **KEEP** (until upstream binding) |
| 0002 | arbiter driver | **KEEP** (TP2-specific) |
| 0003 | realtek-smi bracket | **KEEP** |
| 0004 | shared-pin probe order | **KEEP** |
| 0005 | ctl_dev = I²C platform parent | **KEEP** |
| 0006 | release I²C pins before GPIO | **KEEP** |

Add directory to `BR2_LINUX_KERNEL_PATCH` in `tp2bmc_defconfig`.  
Long-term: **SUBMIT** arbiter + binding upstream (optional).

#### `patches/linux/net-dsa/`

| Patch | Purpose | Now (6.18.33 prod) | After `realtek_forward` merge |
|-------|---------|-------------------|------------------------------|
| 0001 | `tag_rtl8_4` REASON codes | **KEEP** | **REPLACE** — tag part accepted upstream separately (see monitor log) |
| 0002 | `i2c_addr` in variant | **DROP** with I²C switch | **DROP** |
| 0003 | RTL8370MB-CG `0x6368/0x0010` | **KEEP** | **KEEP** until upstream adds chip row · **SUBMIT** |
| 0004 | `realtek-smi-i2c` transport | **DROP** with I²C switch | **DROP** |
| 0005 | bridge offload (Turing minimal) | **KEEP** | **REPLACE** by upstream series (see below) |
| 0006 | NOSTART doc for smi-i2c | **DROP** with 0004 | **DROP** |

#### `patches/linux/i2c/` (mv64xxx)

| Patch | Purpose | Production SMI |
|-------|---------|----------------|
| 0001 | clear bus errors before xfer | **KEEP** — EEPROM/RTC robustness |
| 0002 | clean up private struct | **DROP** if only needed for 0003–0005 chain |
| 0003 | FSM refactor | **DROP** if only needed for NOSTART |
| 0004 | continue after read | **DROP** if only needed for NOSTART |
| 0005 | `I2C_FUNC_NOSTART` / EFR | **DROP** — only for RTK-over-I²C switch |

**Target:** retain **0001** only unless bench shows regressions without 0002–0004.

#### Unchanged patch sets

`power/`, `gpio/`, `pwm/` — **KEEP** as today.

---

## Upstream monitor — `realtek_forward` (bridge / VLAN / FDB offload)

**Watch this series.** When it lands in a kernel version we ship, adopt it and drop local **0005** (and likely **0001**).

| Field | Value |
|-------|--------|
| Series name | `realtek_forward` |
| Subject | `net: dsa: realtek: rtl8365mb: bridge offloading and VLAN support` |
| Author | Luiz Angelo Daros de Luca (based on Alvin Šipraga) |
| v1 Message-ID | `20260331-realtek_forward-v1-0-44fb63033b7e@gmail.com` |
| v1 link | https://patch.msgid.link/20260331-realtek_forward-v1-0-44fb63033b7e@gmail.com |
| Latest tracked | **v13** (2026-06-06) |
| LWN summary | https://lwn.net/Articles/1076755/ |
| Target tree | `linux-net-next` → expect **6.19+** (not in 6.18.33 mainline) |
| change-id | `20260323-realtek_forward-1bac3a77c664` |

### What upstream adds (vs our `net-dsa/0005`)

- `port_bridge_{join,leave}` via **isolation masks + EFID** (no dot1x trap hack)
- HW **FDB** + `fdb_isolation`, assisted learning on CPU port
- HW **VLAN** filtering / PVID offload
- Bridge port flags; driver split (`rtl8365mb_main/l2/vlan/table.c`, `rtl83xx` ops)
- `tag_rtl8_4` updates (v2 changelog: tag patches submitted/accepted on their own)

### What upstream does **not** include (still ours)

- **RTL8370MB-CG** chip table row (`0x6368` / `0x0010`) — keep **`net-dsa/0003`** or submit separately
- **`tpi-i2c-smi-arbiter`** / shared PE12/PE13 — TP2-only
- **`realtek-smi-i2c`** — we are dropping this path

### Adoption checklist (run when series appears in `git tag v6.x`)

1. `kernel-history-tool.sh` / manual: confirm files in `drivers/net/dsa/realtek/`, `net/dsa/tag_rtl8_4.c` match series.
2. Bump `BR2_LINUX_KERNEL_CUSTOM_VERSION_VALUE` to that release.
3. **Remove** `net-dsa/0005-net-dsa-rtl8365mb-implement-bridge-offload.patch`.
4. **Remove** `net-dsa/0001-...` if `tag_rtl8_4` REASON/forward logic is in-tree.
5. **Keep** `net-dsa/0003` until `chip_id == 0x6368` probe works without it.
6. Rebuild; run regression: switch probe, `br0`, inter-node throughput (HW hairpin vs CPU), VLAN if used.
7. Update **Monitor log** below with merge commit / kernel version.

### Monitor log (append on check)

| Date | Kernel / tree | Series version | In mainline? | Local action |
|------|---------------|----------------|--------------|--------------|
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
5. **Bench** (on hardware): EEPROM, RTC, all node ports, `br0` DHCP, optional cross-node `iperf` (CPU hairpin until `realtek_forward` merges).
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
