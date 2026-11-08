#!/usr/bin/env bash
# Document expected U-Boot `ubi info` after a successful BMC-Installer run.
# Use at the U-Boot prompt when debugging (not run on host).
cat <<'EOF'
After full installer [+] DONE, expect at U-Boot:
  ubi part ubi
  ubi info
    user volumes: 2 (uboot-env + rootfs)
    available PEBs: ~250-350 (NOT ~627 — that means rootfs missing)

  ubinfo -a
    Volume name: uboot-env   (~1 LEB)
    Volume name: rootfs      (~370 LEBs / ~45 MiB)

If available PEBs ~627 with no rootfs volume: installer did not write rootfs.
Verify SD image: tp2bmc/scripts/check_sdcard_install_image.sh output/images/tp2-bmc-firmware-sdcard.img

Linux "two LEBs with same sequence number" after install: UBI on NAND is corrupt
(often from earlier installs or mixed layouts). Re-run full SD install to format UBI.
U-Boot may still boot (127 MiB ubi view from embedded v2.4 DT) while Linux attach
over the full 256 MiB ubi partition fails on the same flash.

Split "volume missing on flash" vs "lookup bug" at U-Boot prompt:
  ubi part ubi
  ubi info
  ubi read 0x41000000 rootfs 0x1000
If ubi read succeeds but "Scanning ubi 0:rootfs" fails: rebuild U-Boot with
patch 0005-ubi-find-volume-dev-by-suffix (reference 7164231 behavior).

U-Boot acceptance (reference feat/buildroot2025.11 boot layout):
  - SPL loads from SPI, devicetree: embed, no initr_dm failure
  - Scanning ubi 0:rootfs finds boot.scr.uimg
EOF
