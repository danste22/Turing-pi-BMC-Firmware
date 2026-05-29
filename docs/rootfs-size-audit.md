# Rootfs / libc size audit (Item 5)

Planning baseline for **`feat/buildroot-2026.02`**. Assumes **128 MiB SPI NAND** for budgeting (v2.3 / v2.4 class); notes **256 MiB** where the tree already diverges (v2.5.2).

**PR / GitHub issue closes:** deferred until PR (Item 1). **Python [#160](https://github.com/turing-machines/BMC-Firmware/issues/160):** after this audit (Item 3). **U-Boot U1:** after this audit (Item 4).

---

## 1. Current image (today)

| Item | Value |
|------|--------|
| **libc** | **glibc** (`BR2_TOOLCHAIN_BUILDROOT_GLIBC=y` in generated `.config`) |
| **Rootfs format** | **EROFS** + LZ4HC (`BR2_TARGET_ROOTFS_EROFS_LZ4HC`) |
| **OTA / NAND root slot** | **370 LEBs** ≈ **45880 KiB** (`genimage.cfg`, `osupdate` `NEWVOL_LEBS=370`) |
| **Python 3** | **Not** in `tp2bmc_defconfig` (README cites ~15 MiB under `usr/lib/python3.*` alone) |
| **Rust apps** | **`bmcd`**, **`tpi`** built for **`armv7_unknown_linux_gnueabi`** (glibc ABI) |

After a full `git build`, record sizes on the build host:

```sh
cd buildroot
du -sh output/target
ls -lh output/images/rootfs.erofs
# largest dirs on unstaged rootfs:
du -h output/target/usr output/target/lib 2>/dev/null | sort -hr | head -20
# libc footprint:
du -sh output/target/lib/libc.so* output/target/lib/ld-linux*.so* 2>/dev/null
```

On a flashed BMC (optional):

```sh
df -h /
mount | grep -E 'erofs|ubifs|overlay'
dmesg | grep -i 'spi-nand'   # 128 vs 256 MiB chip
```

---

## 2. NAND / UBI budget (128 MiB assumption)

SPI layout (from boot log + tree):

| Region | Typical size | Notes |
|--------|----------------|--------|
| **boot** (raw) | 1 MiB | SPL + U-Boot (`genimage` offset 8K) |
| **ubi** (remainder) | ~127 MiB on **128 MiB** NAND | `mount_overlay` uses `mtd_size ≤ 133169152` → **230 LEB** overlay cap |
| **rootfs** UBI volume | **370 LEBs** (~45 MiB) | Must fit **compressed EROFS** image + metadata |
| **rootfs_prev** | same class | A/B OTA |
| **overlay** (UBI) | **230 LEBs** on 128 MiB (~28 MiB) | `mount_overlay` `UBI_SIZE2_4` |
| **overlay** on 256 MiB NAND | **1250 LEBs** | `UBI_SIZE2_5` — v2.5.2 class only |

**SD card image** (`genimage.cfg`) is separate: **45880K** EROFS partition + optional **128 MiB** `bmc-logs` — not the SPI NAND limit, but the same **370 LEB** root slot size is used for OTA payloads.

**Headroom rule:** `rootfs.erofs` must stay **below ~45880 KiB** with margin for `ubiupdatevol` and factory tooling. If `output/target` unstaged size grows, watch EROFS output first.

---

## 3. musl vs glibc (feasibility)

### Typical savings

Moving Buildroot from **glibc** to **internal musl** often saves on the order of **~1–3 MiB** on the final compressed rootfs (varies with C++ and pthread use). It is **not** a substitute for dropping **Python (~15 MiB)** or large debug stacks.

### Blockers on this product

| Component | musl impact |
|-----------|----------------|
| **`bmcd`** | Hard-pins **`armv7_unknown_linux_gnueabi`** and `CC_armv7_unknown_linux_gnueabi` in `bmcd.mk` — needs **musl Rust target**, full Cargo rebuild, HW regression |
| **`tpi`** | `cargo-package` / same ARM gnueabi toolchain — same retarget |
| **C stack** | OpenSSL, Avahi, Collectd, OpenSSH, GDB, libcurl — must be rebuilt for musl; usually works but needs full image QA |
| **C++** | `BR2_TOOLCHAIN_BUILDROOT_CXX=y` — supported on musl in Buildroot, still test everything linking `libstdc++` |

### Recommendation

| NAND | musl |
|------|------|
| **128 MiB** (planning) | **Defer** unless you accept a **dedicated musl migration** (Rust triple + full bench). Prefer **package trims** and **no Python** first |
| **256 MiB** (v2.5.2 hardware) | **Optional** later; more overlay/root headroom reduces urgency |

**Trial (build host only, do not ship without Rust retarget):**

```sh
cd buildroot
make BR2_EXTERNAL=../tp2bmc tp2bmc_defconfig
# menuconfig: Toolchain → C library → musl; save
make toolchain
# Expect bmcd/tpi to fail until bmcd.mk / tpi target triple updated
```

---

## 4. Python 3 ([#160](https://github.com/turing-machines/BMC-Firmware/issues/160))

| Scenario | Verdict |
|----------|---------|
| **128 MiB NAND**, **370 LEB** root | **Does not fit** a full CPython 3 stack without removing other payload (README ~15 MiB; often more with stdlib modules) |
| **256 MiB NAND** | **Maybe** — more UBI overlay space; still measure `rootfs.erofs` after enable |
| **Alternatives** | Micropython subset, host-side tooling only, or **bmcd** feature instead of on-device Python |

**Decision gate:** run section **1** commands on a current image, then add `BR2_PACKAGE_PYTHON3=y` in a **throwaway branch** and compare `rootfs.erofs` size vs **45880K** cap.

---

## 5. Phase 1 trims (in tree — no musl)

Applied on **`feat/buildroot-2026.02`** to save space / build time before a musl experiment:

| Change | Rationale |
|--------|-----------|
| **`BR2_PACKAGE_GDB_SERVER=y`**, drop target **`gdb`** client | Remote debug from host; target **`gdb`** multi‑MiB |
| **`# BR2_TARGET_ROOTFS_TAR_GZIP`** | OTA ships **EROFS** only; tar.gz unused in `post_image.sh` |
| **Duplicate `E2FSPROGS` line** removed | Defconfig hygiene |
| **`post_build.sh`** → `usr/share/doc/turing-pi-bmc/rootfs-staged-size.txt` | Per-build size snapshot for this audit |
| **OpenSSL B+C+D** in `tp2bmc_defconfig` | Drop legacy ciphers, weak SSL, engines, QUIC/CMP, debug hooks; keep modern TLS + `openssl` CLI. **Not** FIPS 140-3 certified. **collectd** kept. |

After `git build`, read that file and `ls -lh output/images/rootfs.erofs` against the **45880 KiB** cap.

Further trims (product decision, not done yet):

- **Collectd** / **Avahi** if lab-only
- **evtest**, **tree**, **nano** if unused in production
- Split **debug** vs **release** defconfig fragments

---

## 6. Outcomes / next steps

| Item | Action |
|------|--------|
| **Item 5 (this doc)** | Fill in measured `rootfs.erofs` + `du` after your post-validation `git build` |
| **Item 3 (#160)** | Only if section 1 shows headroom or you scope a **slim** runtime |
| **Item 4 (U1)** | U-Boot EEPROM MAC — independent of libc; schedule after sizes known |
| **Item 2 (E3)** | **Done in tree** (`cleanup_stale_by_tpi_links`); optional USB mdev hook only if you require **immediate** symlink removal after `normal` without another MSD event |
| **Item 1 (GitHub)** | At PR time |
| **Item 6 (PR)** | Last |

---

## 7. E3 (#225)

Stale **`/dev/disk/by-tpi/nodeN`** links are cleared on block mdev events and on **USB remove** for internal hub ports **`1-1.[1-4]`** / **`2-1.[1-4]`** (see `post_build.sh` mdev.conf lines). Retest: `tpi advanced msd -nN` → `tpi advanced normal -nN` → `ls /dev/disk/by-tpi/nodeN` should fail when `/sys/block/sdX` is gone.
