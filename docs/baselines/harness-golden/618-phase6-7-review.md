# Harness capture — kernel 6.18.62 + Phase 6/7 (2026-11-10)

Image: `2026.11.10-27c8ba11`, board **v2.5.1**, MAC `c4:ff:84:10:00:ba`, Mode 1.

Full log: [`hw-validate-6.18.62-20261110.log`](hw-validate-6.18.62-20261110.log).

Boot evidence: `postupdate` saw `node1`…`node4`; SSH + web UI up; `uname -r` **6.18.62**.

## Pass criterion for this port (not “zero FAIL”)

| Area | Result |
|------|--------|
| **A1** kernel pin | PASS `6.18.62` |
| **F1/F5** SMI arbiter + no I²C switch | PASS |
| **G** DSA + flat `br0` Mode 1 | PASS |
| **H/I** BMC USB + GPIO | PASS |

**51 PASS** — TARGET stack is live on hardware.

## Nine FAILs — triage

| FAIL | Harness expects | On this image | Suggested follow-up |
|------|-----------------|---------------|---------------------|
| **C1** `apply_bmc_mac.sh`, `set_br0_mac_pre_dhcp.sh`, interfaces hook | IdeaProjects #238 overlay | Missing; **br0 MAC still correct** (EEPROM/hive path) | Port MAC scripts from BMC-Firmware overlay **or** narrow harness if hive-only MAC path is intentional |
| **D2** DE dependency-cycle flood | No mixer/tcon/lcd cycles in dmesg | Still present | DT/display cleanup — **defer** (see review backlog) |
| **D4** F2FS + exFAT off | `linux_defconfig` policy | Both still `=y` | Disable in defconfig **or** accept WARN and relax D4 |
| **D5** no GS0 in inittab | OTG via mdev/S11 only | `post_build.sh` still adds GS0 getty | Remove GS0 `sed` **or** update harness if serial-on-GS0 is desired |
| **E** mdev helper + `mdev.conf` | #225 `by-tpi` | Not in image | Port `mdev-tpi-msd-symlink` + `post_build.sh` mdev stanza from IdeaProjects |

None of these blocked staging or networking on this run.

## WARNs worth a quick look

- **B4** `kernel.sysrq = 1` — harness wants `0` on cold boot; check who sets it (Magic SysRq banner vs sysctl).
- **G2** `UPLINK_CONDUIT` — cosmetic; CPU port is DSA conduit, not `eth0`.
- **M** no `/etc/tp2/network.conf` — OK for hive flat `br0`.

---

## Review backlog (boot log noise — not blockers)

Items to revisit when polishing docs, FIT metadata, or kernel config — **do not treat as regressions** for Phase 6/7 sign-off.

1. **`rtl8365mb-smi switch@smi: missing child interrupt-controller` / `no interrupt support`**  
   Binding has no switch IRQ child; driver polls links. Observed: `ge0` 1G up, DSA ports on `br0`.

2. **Duplicate `found an RTL8370MB-CG switch` (two probe lines)**  
   One physical switch; likely double probe path in driver/DT. Harmless if netdev count is correct.

3. **exFAT/F2FS errors on `ubiblock0_1` at boot**  
   Kernel probes FS types on a UBI block that is not exFAT/F2FS (root is elsewhere). Related harness **D3/D4** if we turn those filesystems off.

4. **FIT subimage description `turingpi 6.8.12`**  
   Stale string in `turing-pi2.its` (or equivalent); kernel running is **6.18.62**. Cosmetic only.

5. **U-Boot preboot `ethsw_do_isolate` still I²C @0x5c**  
   By design for this step: isolation is hardcoded in `uboot.env`, independent of Linux `switch@smi`. Future board-C work if recovery DHCP must use SMI.

6. **`/mnt/overlay/upper/etc/network/interfaces does not exist`**  
   First-boot overlay message; network still came up (DHCP on `br0`).

---

## Recommended follow-up PR(s) to maintainer (out of kernel 6.18 / Phase 6–7 scope)

Separate userspace PR(s) on the hive line — **not** bundled with the SMI/6.18 kernel port unless product asks to merge them.

### C1 — Factory MAC on `br0` before DHCP (#238)

**Problem:** Harness expects explicit MAC application; hive relies on DSA bridge inheriting factory MAC from `node1` (EEPROM @ 0x2C). Steady state matches (verified: `br0` = EEPROM = `node1` = `ge0`); risk is **first `udhcpc` DISCOVER** before slaves/MAC are stable.

**Proposed PR (overlay only):**

- Add from BMC-Firmware/IdeaProjects: `etc/network/apply_bmc_mac.sh`, `etc/network/set_br0_mac_pre_dhcp.sh`, `etc/init.d/S39bmc-mac`.
- One line on flat `br0`: `pre-up /etc/network/set_br0_mac_pre_dhcp.sh` in `overlay/etc/network/interfaces` (keep `wait-delay 15`).
- Do **not** replace hive `S00dsa` or `setStaticNet.sh` (`eth0`) in the same PR.

**Ask maintainer:** Is bridge inheritance the supported contract, or is #238 required for all production images?

### E — MSD stable paths `/dev/disk/by-tpi/nodeN` (#225)

**Problem:** Hive has no `mdev-tpi-msd-symlink` or `mdev.conf` hooks; `tpi advanced msd` still exposes `/dev/sd*`. Harness **E** fails; automation/docs that reference `by-tpi` need IdeaProjects plumbing.

**Proposed PR:**

- Add `overlay/usr/bin/mdev-tpi-msd-symlink` (from BMC-Firmware).
- Extend `post_build.sh`: idempotent `mdev.conf` rules for `sd[a-z]` and hub ports `1-1.N` / `2-1.N` (same block as BMC-Firmware ~#225).

**Ask maintainer:** Is `by-tpi` a product requirement on hive, or harness-only / IdeaProjects fork?

### D5 — USB gadget serial (`ttyGS0`) vs inittab respawn

**Problem:** `post_build.sh` adds `GS0::respawn:getty` on `ttyGS0`. With working `S11bmc-otg`, `ttyGS0` exists early and behaviour looks fine; if OTG is disabled or `S11` fails, getty retries every ~10s (`auth.err getty: can't open '/dev/ttyGS0'` in `/var/log/messages` — reproduced on lab board).

**Proposed PR (IdeaProjects pattern, not in current fork tree):**

- `post_build.sh`: `sed -i '/^GS0::/d'` on staged `inittab` (stop adding GS0 line).
- Add `overlay/usr/bin/mdev-ttyGS0-getty` + mdev rule `ttyGS0 … */usr/bin/mdev-ttyGS0-getty`.
- Keep `S11bmc-otg` unchanged for gadget bring-up.

**Ask maintainer:** Keep hive inittab GS0 for compatibility vs adopt mdev-getty to avoid syslog spam when gadget is absent?
