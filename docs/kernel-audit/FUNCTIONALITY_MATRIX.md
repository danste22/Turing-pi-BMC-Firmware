# Functionality matrix — HIVE@6.12 vs TARGET@6.18.62

Evidence: patched trees under `tmp/kernel-audit/` ([`APPLY_STATUS.md`](APPLY_STATUS.md)).  
Patches in git were written for **6.18.50**; audit tarball is **6.18.62** — same line (6.18.y), so apply results match expectations (one stale hunk on pre-split `rtl8365mb.c`, not a 6.12→6.18 port gap).

Kernel tarball only — **DTS**, **`linux_defconfig`**, **U-Boot** are product rows 12–13.

**Legend:** **HIVE** = excavador `hive` on 6.12.109. **TARGET** = IdeaProjects layout on 6.18.62.  
**Ship from** = which side is the source of truth for the excavador fork after merge (not “run both”).

| # | Capability | HIVE @ 6.12 | TARGET @ 6.18 | Parity? | Ship from | Suggested action | Why |
|---|------------|-------------|---------------|---------|-----------|------------------|-----|
| 1 | Switch management (MDIO/SMI vs I2C) | I2C @ `0x5c`: `realtek-i2c.c`, `realtek_i2c_probe`, `rtl8365mb_i2c_driver` | GPIO SMI: `realtek-smi.c`, standard `realtek_smi_probe` | No | **TARGET** | DROP hive `realtek-switch.patch`; KEEP `tp2/tpi-smi-mux` + `CONFIG_NET_DSA_REALTEK_SMI` | HW uses PE12/PE13 bitbang SMI + shared pins with I2C2. Hive I2C stack cannot drive production silicon; IdeaProjects path is bench-validated. |
| 2 | RTL8370MB-CG (`0x6368` / `0x0010`) | `realtek-switch.patch` → monolithic `rtl8365mb.c` chip row | `net-dsa/0002` → `rtl8365mb_main.c` | Yes | **TARGET** | KEEP `net-dsa/0002` only | Same silicon ID; hive folded into Sam’s monolith hack. Target patch is small, maintainable, matches upstream file split. |
| 3 | 802.1Q VLAN (`port_vlan_*`, filtering) | `rtl8370-vlan-support.patch` on monolith | `rtl8365mb_vlan.c` + `net-dsa/0001`, `0006` | Mostly | **TARGET** | KEEP `net-dsa/0001–0006`; rebase 0001 hunk off obsolete `rtl8365mb.c` | Hive VLAN is a fork on I2C driver. Target series matches `hw-validate` VLAN/bridge tests and upstream driver layout. |
| 4 | Bridge join/leave, FDB, tagging | Hive hacks in `rtl8365mb.c` | `rtl83xx.c` + split `rtl8365mb_*` (0001 + 6.18 base) | Mostly | **TARGET** | KEEP 0001–0006; refresh 0001 for `-F0` on 6.18.62 | Bridge offload is how `br0` + node ports work in validator; lives in TARGET/net-dsa, not in hive vlan patch alone. |
| 5 | HW LAG / trunk offload | Not in hive | `rtl8365mb_lag.c` (`0003`–`0005`) | No | **TARGET** | KEEP `0003–0005` | TP2 topology (uplink LAG, node trunks). Hive never had it; dropping loses features IdeaProjects added on purpose. |
| 6 | SMI ↔ I2C arbiter (PE12/13) | Absent | `tpi-i2c-smi-arbiter.c`, `tpi_smi_arb_*` in `realtek-smi.c` | No | **TARGET** | KEEP `tp2/tpi-smi-mux/0001–0003` | Without arbiter, switch SMI races EEPROM/RTC on `i2c2` — known hive pain, fixed on TARGET. |
| 7 | mv64xxx I2C robustness | hive `i2c.patch` (NOSTART / RTK-on-I2C chain) | `generic/i2c/0001` (clear bus errors) | Partial | **TARGET** | KEEP `generic/i2c/0001`; DROP hive `i2c.patch` | After SMI migration, NOSTART chain only served I2C switch; 0001 keeps EEPROM/RTC stable on real HW I2C. |
| 8 | Allwinner PWM (T113) | Root `Add-support-for-Allwinner-PWM-…` | `generic/pwm/0001–0003` | Yes | **TARGET** | DROP hive PWM monolith; KEEP `generic/pwm/*` | Same feature, duplicate paths in fork if both kept; Buildroot lexical order risks double-apply. |
| 9 | Regulator `preserve-boot-state` | Root `0001-regulator-fixed-perserve-boot-state.patch` | `tp2/power/0001` (same text, correct spelling) | Yes | **TARGET** | KEEP `tp2/power/0001`; DROP hive root `0001` | Warm-reboot regulator state; tp2 path is production layout, hive root is duplicate. |
| 10 | gpio-latch SRAM shadow @ `0x0709010c` | Not in hive | `tp2/power/0002` | No | **TARGET** | KEEP `tp2/power/0002` | SPL/U-Boot contract on TP2; hive image never had it; required for full BMC-Firmware stack. |
| 11 | gpio-aggregator `turing,pi2-nodes` | Root `0002-gpio-aggregator…` | `tp2/gpio/0001` | Yes | **TARGET** | KEEP `tp2/gpio/0001`; DROP hive root `0002` | Same compatible string; one copy under `tp2/gpio`. |
| 12 | Kconfig switch options | excavador `linux_defconfig`: `REALTEK_I2C=y`, SMI off | IdeaProjects: `REALTEK_SMI=y`, `REALTEK_I2C` off, `TPI_I2C_SMI_ARBITER=y` | No | **TARGET** | Phase 7: flip defconfig to IdeaProjects | Kconfig must match TARGET drivers; hive I2C options load wrong probe path even if patches are correct. |
| 13 | DT switch + arbiter + `i2c2` pinctrl | Hive DTS: `ethernet-switch@5c` on `&i2c2` | IdeaProjects: `switch@smi`, arbiter, `smi_mode` | No | **TARGET** | Phase 6: merge IdeaProjects DTS into fork | Kernel patches do not replace DT; hive DT boots wrong bus even with TARGET kernel. |
| 14 | Patch tree layout in fork | Mixed: hive root blobs + `generic/` + `net-dsa/` + `tp2/` | Clean TARGET layout only | — | **TARGET** | Phase 5: delete hive root patches; optional `series` | Buildroot applies all `*.patch` recursively — duplicates and I2C+SMI together break builds. |

## MCP / index — wait for redo matrix?

**No full redo.** Index `tp2-linux-hive-612` and `tp2-linux-target-618` **finished** (post-patch trees). The matrix above stays the sign-off doc.

Use MCP only to **spot-check** paths/symbols → [`SYMBOL_NOTES.md`](SYMBOL_NOTES.md). Example: on TARGET, `tpi_smi_arb_begin` is called from `realtek-smi.c` SMI bitbang; on HIVE, `realtek_i2c_probe` exists, no arbiter driver file.

If a trace contradicts a row, we patch that row — not regenerate the whole matrix.

## Three different “rtl8365mb” shapes (read this once)

| Layer | Layout | What you have |
|-------|--------|----------------|
| **HIVE @ 6.12** | **Monolith + I2C hack** | One `rtl8365mb.c` (~3.2k lines), Sam `realtek-switch.patch`. No split files. |
| **Vanilla @ 6.18.50 / 6.18.62** | **Monolith (mainline)** | One `rtl8365mb.c` (~2.2k lines), `Makefile` = `obj-… += rtl8365mb.o` only. **Luiz’s file split is not in 6.18.y tarballs** (still on net-next; see links below). |
| **After your `net-dsa/0001`** | **Split (backport)** | Carries Luiz’s **realtek_forward** series: delete monolith, add `rtl8365mb_main.c`, `_vlan.c`, `_l2.c`, … + bridge/FDB/VLAN offload. |

The failed 0001 hunk deletes `rtl8365mb.c` using a **2208-line** “before” file; **6.18.62** tarball has **2222** lines → reject at `-F0`. Split-file hunks still apply, so audit tree can hold **both** `rtl8365mb.c` and `rtl8365mb_main.c` until 0001 is refreshed.

### Where is Luiz’s refactor?

| What | Pointer |
|------|---------|
| Series name | **realtek_forward** (Luiz Angelo Daros de Luca, Alvin Šipraga) |
| Your carry | `net-dsa/0001-…-backport-bridge-fdb-vlan-offload.patch` (header: through net-next `660a9e399ab0`, **not in mainline 6.18.x**) |
| Lore / index | [v1 series intro](https://lore.kernel.org/netdev/20260331-realtek_forward-v1-0-44fb63033b7e@gmail.com/), [msgid](https://patch.msgid.link/20260331-realtek_forward-v1-0-44fb63033b7e@gmail.com/) |
| Split prep commit (example) | “net: dsa: realtek: rtl8365mb: prepare for multiple source files” — renames `rtl8365mb.c` → `rtl8365mb_main.c`, adds `rtl8365mb-objs := …` in Makefile ([OpenWrt backport mirror](https://git.openwrt.org/openwrt/staging/stintel/plain/target/linux/generic/backport-6.18/942-04-7.2-net-dsa-realtek-rtl8365mb-prepare-for-multiple-sourc.patch)) |
| LWN overview | https://lwn.net/Articles/1076755/ |
| Living tree (master) | https://github.com/torvalds/linux/tree/master/drivers/net/dsa/realtek — split layout once series is merged |

**6.18.50 vs 6.18.62:** same driver layout in CDN tarballs (single `rtl8365mb.c`); patch was rebased for **6.18.y**, not for each stable micro bump. Drift between .50 and .62 is small; your reject is **line-count/context** on the delete hunk, not “.62 regressed the split.”

**Ship from TARGET** — before Buildroot (`-F0`): rebase `net-dsa/0001` so (a) matches 6.18.62 baseline (or remove (a) if split is already in the tarball).

## Fork hygiene (Phase 5 prelude)

DELETE from `excavador-turing/tp2bmc/patches/linux/` root (all **HIVE** — do not ship):

`realtek-switch.patch`, `rtl8370-vlan-support.patch`, `i2c.patch`, `0001-regulator-fixed-perserve-boot-state.patch`, `0002-gpio-aggregator-…`, `Add-support-for-Allwinner-PWM-…`

KEEP only **TARGET** tree: `generic/`, `net-dsa/`, `tp2/`.
