# Kernel / Buildroot 2026.02 upgrade — validation (PR sign-off)

Branch **`feat/buildroot-2026.02`**: Buildroot **2024.05.1 → 2026.02.1**, Linux **6.8.12 → 6.18.27**.

Hardware sign-off on **Turing Pi 2 v2.5.x** BMC (**2026-05-29**). Automated checks: [`scripts/hw-validate.sh`](../scripts/hw-validate.sh) on a flashed unit.

## Summary

| Area | Status | Notes |
|------|--------|--------|
| A — Image / `tpi` | **PASS** | Kernel **6.18.27** |
| B — UART / keys | **PASS** | B2 `screen` manual OK |
| C — Network / MAC | **PASS** | Factory EEPROM on `br0` (`c4:ff:84:…`); C2 static IP OK |
| D — Boot noise / kconfig | **PASS** | Expected CCU↔RTC cycles only |
| E1/E2 — MSD add | **PASS** | `by-tpi/nodeN` → `/dev/sdX`, RockUSB on `usb…/1-1.N` |
| E3 — MSD `normal` | **FIX** | Stale symlink after RockUSB teardown — `mdev-tpi-msd-symlink` cleanup |
| E5 — MSD stress | **OPEN** | BMC reset; **not** a kernel-upgrade blocker (see below) |
| F — DSA / RTL8370 | **PASS** | Switch + bridge ports up |

**Release recommendation:** sign off **kernel 6.18.27 / Buildroot 2026.02** for this line. Ship **E3** overlay fix; track **E5** under bmcd/tpi (upstream).

---

## E — MSD (#225)

### E3 — stale `/dev/disk/by-tpi/nodeN`

After `tpi advanced normal -nN`, `/sys/block/sdX` is gone but the symlink may remain (RockUSB often skips mdev `remove`).

**Fix (overlay):** `cleanup_stale_by_tpi_links()` in `usr/bin/mdev-tpi-msd-symlink` — run on add/remove and before creating a new link.

**Runtime workaround:**

```sh
for n in 1 2 3 4; do
  link=/dev/disk/by-tpi/node$n
  [ -L "$link" ] || continue
  b=$(basename "$(readlink "$link")")
  [ -d "/sys/block/$b" ] || rm -f "$link"
done
```

### E5 — BMC reset on repeated MSD (out of kernel scope)

**Repro:** `power off`, then `advanced msd`, `advanced normal`, then **`advanced msd` again** (same node). First cycle completes (`tpi` exit 0); reset to **U-Boot SPL** when the **second** `advanced msd` starts or during that enumeration.

**Kernel capture (`dmesg -c` poll to `/var/log/msd-stress.log`):** normal `usb 1-1.2` → `rockusb` → `sda` attach; **no** `Oops`, `panic`, `BUG`, or watchdog bark in the drained log.

**Suggested upstream one-liner** (bmcd / `tpi` / GitHub issue):

> BMC resets to SPL when repeating `tpi advanced msd -nN` after `power off` + `msd` + `normal`; first cycle OK; kernel shows normal RockUSB on `usb1/1-1.2`, no oops.

**Capture notes (BusyBox BMC):**

- `/dev/kmsg` read fails; use a **`dmesg -c` loop** (every 2s) into persistent `/var/log`.
- `tpi` prints `ok` on **stdout**; log per command with `sync`, not a single `tee` pipeline (reset before flush).
- Piped `tee` after `&&` only captures the **last** command unless wrapped: `( tpi … && tpi … ) 2>&1 | tee …`.

---

## Related docs

- [`tp2bmc/patches/linux/IMPROVEMENTS.md`](../tp2bmc/patches/linux/IMPROVEMENTS.md) — L1 MAC (addressed in tree), further kernel backlog
- [`tp2bmc/patches/uboot/IMPROVEMENTS.md`](../tp2bmc/patches/uboot/IMPROVEMENTS.md) — U1 EEPROM `ethaddr` in U-Boot
- [`node1-rk1-bmc-debug.md`](node1-rk1-bmc-debug.md) — bmcd / UART / USB flash
