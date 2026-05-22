# Node 1 / bmcd / BMC serial — debug notes (resume here)

This file captures investigation done **2026-05-10/11** on Turing Pi 2 v2.5 BMC (kernel **6.18.27**, `bmcd` **v2.3.4**). Goal was to separate **kernel-upgrade regressions** from **bmcd / hardware** behaviour.

---

## 1. Node UARTs (`/dev/ttyS1`–`ttyS4`) — “no I/O after kernel bump”

### Verdict: **not a kernel / DT UART regression**

- Pin mux verified via `devmem`: PB/PD/PG UART functions match DTS (`PB2/3` uart4, `PB4/5` uart5, `PD1/2` uart2, `PG6/7` uart1, `PB6/7` uart3 / console).
- All five UART blocks: `LSR=0x60` (THRE|TEMT), `UART_BGR` @ `0x0200190C` = `0x003E003E` (UART0 gated off; UART1–5 clocked — expected).
- `/proc/tty/driver/serial` showed large **tx/rx** on `ttyS2`–`ttyS4` during stress; **`bmcd` (PID 1124)** holds **fd 10/21/22/23** on `ttyS1`–`ttyS4` and **consumes RX** before `screen` / a direct UART client sees it.
- `fuser /dev/ttyS1` … returned many PIDs; `ps` showed **`/usr/bin/bmcd`** plus orphan shells with stdout redirected to ttyS*.

**Reference:** upstream discussion matches — [BMC-Firmware#200](https://github.com/turing-machines/BMC-Firmware/issues/200).

**Workaround (runtime):** `/etc/init.d/S94bmcd stop`, confirm `fuser` clean, then `screen` via `/usr/bin/node2`, etc. **Proper fix:** bmcd multiplexing / config / release — **out of scope** for kernel-upgrade work.

---

## 2. `bmcd` flash / OS install — `Compute module's USB interface not found or supported`

### Error chain

- String = `UsbBootError::NotSupported` in `tmp/bmcd/src/usb_boot.rs` (`#[error("Compute module's USB interface not found or supported")]`).
- Raised when `NodeDrivers::find_first()` finds **no** device matching **`RpiBoot`** (`0x0a5c:*`) or **`RockusbBoot`** (`0x2207:*`) across `rusb::devices()`.
- Logged as: `bmcd::streaming_data_service: #<id> stopped: Compute module's USB interface not found or supported.`  
  (`tmp/bmcd/src/streaming_data_service.rs` — `tracing::error!("#{} stopped: {:#}.", id, error)`).

### Hardware context

- **Slot 1:** Rockchip **RK1** (RK3588S2, 4 GB) — expect MaskROM/loader as **`2207:…`** when recovery works.
- Flash flow: `BmcApplication::reboot_into_usb` → power off → `configure_usb_internal(Flashing(Node1, Bmc))` → power on → **1 s** sleep → `clear_usb_boot()` → `node_drivers.load_as_stream()` → `find_first()`.

### `lsusb` trace (same session as flash)

- For **~14 s** only root hubs (`1d6b:0001`, `1d6b:0002`).
- Then **`05e3:0608`** (on-board Genesys hub) appeared; **no `2207:*` or `0a5c:*` at any time** during multi-second window.
- **Conclusion:** not only “bmcd gave up too early”; the RK1 **never showed** on the bus in that trace.

### `node1-usbotg-dev` / PD19

- User: **`gpioget` for `node1-usbotg-dev` always 0**; `en=` / `rpiboot=` empty in their trace snippet.
- `devmem` (PD bank base `0x02000090`):  
  - `PD_CFG1` `0x02000094` = `0x1111111111` → PD8–15 including **PD15 (`node1-rpiboot`)** = **GPIO out** (`0x1`).  
  - `PD_CFG2` `0x02000098` = `0x0F510FFF` → **PD19** mux nibble **`0x0`** = **GPIO input** (not driven output).  
  - `PD_DAT` `0x020000A0` = `0x0000F788`.

### Critical **bmcd** behaviour (v2.5 “USB hub” path)

- `PinController::new(has_usb_switch: false)` uses **`UsbHub`**, not **`UsbMuxSwitch`**.
- **`UsbHub::configure_usb` is a no-op** for `Flash` / `Device` (comment: nodes already connected to hub). It does **not** drive `node1-usbotg-dev` … `node4-usbotg-dev` (those are only used in **`UsbMuxSwitch::configure_usb`**).
- v2.5 DTS maps **`node1-usbotg-dev`** to **`&pio 3 19` (PD19)** under `compatible = "turing,pi2-nodes"` (`sun8i-t113s-turing-pi2-v2.5.dts` `nodes` / `gpio-line-names`).

So **bmcd never toggles PD19 on v2.5 hub boards** during flash; PD19 staying input / reading 0 can be **by design** of current bmcd, not proof of a failed “set high” attempt.

**Still open:** whether **hardware** requires PD19 (or PG0/PG1 “node1 source” from `set_node1_usb_route`) to be in a specific state for RK1 MaskROM to reach the BMC’s USB path. **`NODE1_USB_MODE`** / `initialize_usb_mode` sets PG0/PG1 only at boot, not per flash.

---

## 3. Useful commands for next session

```sh
# Who holds node UARTs
fuser /dev/ttyS1 /dev/ttyS2 /dev/ttyS3 /dev/ttyS4 2>&1

# Map line names to gpiochips
for c in /dev/gpiochip*; do
  echo "=== $c ==="
  gpioinfo "$c" 2>/dev/null | grep -E 'node1-usbotg|node1-rpiboot|node1-en'
done

# USB bus during flash (one SSH session; trigger flash from another)
( i=0; while [ $i -lt 120 ]; do date +%H:%M:%S.%3N; lsusb; echo ----; i=$((i+1)); sleep 0.5; done ) | tee /tmp/usb-trace.log

grep -E '2207|0a5c|05e3|1d6b' /tmp/usb-trace.log

# CCU UART bus gating (correct address)
devmem 0x0200190C 32

# PD pad mux (bank base 0x02000090)
devmem 0x02000094 32   # PD_CFG1 (PD8–15)
devmem 0x02000098 32   # PD_CFG2 (PD16–23) — PD19 here
devmem 0x020000A0 32   # PD_DAT