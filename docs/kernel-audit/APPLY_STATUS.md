# Patch apply status (audit run)

Method: vanilla tarballs + `kernel-patch-tool.sh` order (see README).  
HIVE uses `patch -F0` (matches Buildroot). TARGET on 6.18.62 uses `PATCH_FUZZ=3` because `net-dsa/0001` line context drifts vs upstream split `rtl8365mb*.c` (Buildroot still uses `-F0`; see risk row in matrix).

## HIVE — `linux-6.12.109` + excavador `hive` (6 patches)

| Patch | Result |
|-------|--------|
| `0001-regulator-fixed-perserve-boot-state.patch` | OK |
| `0002-gpio-aggregator-…` | OK |
| `Add-support-for-Allwinner-PWM-…` | OK |
| `i2c.patch` | OK |
| `realtek-switch.patch` | OK |
| `rtl8370-vlan-support.patch` | OK |

Tree: `tmp/kernel-audit/linux-6.12.109-hive`

## TARGET — `linux-6.18.62` + `IdeaProjects/BMC-Firmware/.../patches/linux` (16 patches)

| Patch | Result | Notes |
|-------|--------|-------|
| `generic/i2c/0001` | OK | |
| `generic/pwm/0001–0003` | OK | |
| `net-dsa/0001` | **PARTIAL** | 1 hunk reject on `drivers/net/dsa/realtek/rtl8365mb.c` (legacy monolith); other hunks applied (`rtl8365mb_main.c`, `rtl83xx.c`, `tag_rtl8_4.c`, …). Upstream 6.18 already split the driver. |
| `net-dsa/0002–0006` | OK | 8370 chip row, LAG, VLAN/FDB fixups present in tree |
| `tp2/gpio`, `tp2/power` | OK | |
| `tp2/tpi-smi-mux/0001–0003` | OK | arbiter + SMI bracket in `realtek-smi.c` |

Full log: [`apply-target.log`](apply-target.log)

Tree: `tmp/kernel-audit/linux-6.18.62-target` (1× `.rej` left from 0001 — do not ship as-is; refresh 0001 hunk or drop obsolete file hunk before `-F0` build).

## `BMC-Firmware/scripts/`

No kernel patch list there. `configure.sh` only applies `buildroot_patches/`. Kernel order = **`KERNEL_UPGRADE_LOG.md`** + **`tp2bmc/patches/linux/scripts/kernel-patch-tool.sh`** (updated in this audit).
