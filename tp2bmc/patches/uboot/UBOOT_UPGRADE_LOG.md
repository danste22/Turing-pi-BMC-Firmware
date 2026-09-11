# TP2 BMC — U-Boot patch log & v2026.07 migration

Maintainer notes for U-Boot **2026.07** (Buildroot `tp2bmc_defconfig`).
Patches live under `tp2bmc/patches/uboot/{sunxi,usb,ubi,i2c,spl,board}/`.

Working copy used to export the series: `../turing-bmc-bootloader` branch
`tp2-v2026.07` (rebased from the old `feat/uboot-2026.04` pin `59b93a5`).

Legend: **KEEP** carry in tree · **DROP** removed · **SUBMIT** candidate for
upstream · **BOARD** Turing Pi 2 only

---

## Classification (31-commit fork delta → 6 patches)

The fork had 31 commits on top of `Prepare v2026.04`. Squashed and rebased
onto **v2026.07**:

| Patch | Origin | Status |
|-------|--------|--------|
| sunxi/0001 SPL SPI NAND + T113/R528 | 7 SPI commits + 2 HACK/some-fixes on `spl_spi_sunxi.c` | **KEEP** (cold SPI contract). Generic sunxi — **SUBMIT** after checkpatch |
| usb/0001 musb UDC/DM gadget | `2add13e` + `7e9d4c` | **KEEP** while `CONFIG_DM_USB_GADGET=y`. Reassess vs later U-Boot |
| ubi/0001 DM UBI + `ubi 0:volname` | `ee566bb`, `b683c41`, `d37762d`, `ea7d0a5` (HACK) | **KEEP**. Upstream UBI block is growing — recheck each bump |
| i2c/0001 mvtwsi early read + i2c2 pinmux | `735fd91` HACK pinctrl + mvtwsi bypass | **KEEP**. SPL_DM_I2C would delete the bypass; not enabled (SPL size) |
| spl/0001 bloblist handoff | `cc54f92` | **KEEP** / possibly **SUBMIT** |
| tools/0001 skip mkeficapsule without p11-kit | v2026.07 `0c716a157be` | **KEEP** until host GnuTLS has PKCS#11 or U-Boot probes it |

Dropped vs the fork (no longer in the series):

| Fork change | Why |
|-------------|-----|
| `env/common.c` `env_set_force()` / `eth_env_set_enetaddr()` `-EEXIST` removal | EEPROM MAC is applied in board code; stock U-Boot env is enough |
| `net/eth-uclass.c` inverted MAC precedence (`// all is oke`) | Same; DT `local-mac-address` + `ethaddr` from EEPROM |
| `sid_ethaddr` rename in `setup_environment()` | Restored upstream `ethaddr`; EEPROM fills it first |
| RTL8370MB isolation via I2C `0x5c` | Kernel uses GPIO SMI. U-Boot only releases reset (PG13 / PG3). Linux DSA owns isolation |
| `uboot.env` `ethsw_*` | Dead; hardcoded PG13 on v2.5+ |

`HACK:` and “some fixes” commits were rewritten with real subjects in the
exported patches.

checkpatch: board/tpi_info help text still uses spaces (pre-existing). Not a
boot blocker. Clean those before a SUBMITs.

---

## MAC policy

1. Valid factory MAC in the 24c02 (bloblist from SPL, else I2C read) → apply
   to EMAC `local-mac-address` (`board_fix_fdt` + `ft_board_setup`) and to
   `ethaddr` if empty. Never write the EEPROM.
2. If EEPROM is missing/unreadable/not a unicast address → sunxi SID
   locally-administered address into `ethaddr` (stock `setup_environment()`).

---

## Switch / SMI

U-Boot does **not** program port isolation. After reset-release the ASIC
default-forwards, which is enough for recovery DHCP. The two RJ45s may be
bridged until Linux DSA comes up. That is the trade for not carrying the
retired RTK-over-I2C personality.

---

## Contracts

- Legacy uImage at flash `0x8000`, not SPL FIT (`CONFIG_SPL_LOAD_FIT` off)
- `CONFIG_OF_EMBED=y`; `OF_SEPARATE` / `OF_BOARD` off
- v2.5+ EEPROM only: `board_init` expands the embedded v2.4 `ubi` `reg` to 255 MiB before UBI env attach. v2.3/v2.4 and missing EEPROM keep the 127 MiB map (128 MiB NAND).
- `CONFIG_OF_BOARD_FIXUP=y` so the control DT gets the EEPROM MAC before EMAC probe
- DRAM timings in `uboot_defconfig`
- UBI env VID offset 2048; `ubi_find_volume_dev` for `ubi 0:rootfs`
- SRAM cookies `0x07090108` / `0x0709010C`

Validate: `tp2bmc/scripts/validate_spi_boot_stack.sh` and
`tp2bmc/scripts/check_spi_boot_image.sh`. Recovery: SD installer, FEL
`mw.l 07090108 5aa5a55a; reset`.

A cold-flash check of `output/images/u-boot-sunxi-with-spl.bin` still needs a
Buildroot run (`scripts/configure.sh` then `scripts/build.sh`); this tree has
no `buildroot/` or `output/` yet. Source-layout checks against
`../turing-bmc-bootloader` (`tp2-v2026.07`) already pass.

---

## Monitor log

| Date | U-Boot | Action |
|------|--------|--------|
| 2026-09-08 | 2026.07 | Switched Buildroot from CUSTOM_GIT `59b93a5` to upstream 2026.07 + in-tree patches |
| 2026-09-08 | 2026.07 | Disable `CONFIG_EFI_LOADER` + `CONFIG_TOOLS_MKEFICAPSULE`; `tools/0001` skips `mkeficapsule` unless host GnuTLS has p11-kit. SD boot + `validate_spi_boot_stack.sh` passed (legacy mkimage @ 0x8000). |
