# Linux improvement backlog (Turing Pi 2 BMC)

Cross-cutting kernel / DT / init issues on the **feat/buildroot-2026.02** line.

## Current baseline

- **Kernel:** 6.18.27 (`tp2bmc/configs/tp2bmc_defconfig`)
- **EMAC:** `dwmac-sun8i` + `nvmem-cells` → `eeprom@50` / `mac-address@2c` in
  `sun8i-t113s-turing-pi2.dtsi`
- **Management netdev:** `eth0` renamed to **`dsa`** (`S00dsa`); **`br0`** inherits
  that MAC for DHCP

---

### L1 — Apply EEPROM MAC (`c4:ff:84:…`) to `dsa` / `br0`

**Problem (confirmed 2026-05 on v2.5.2):**

| Source | Value |
|--------|--------|
| EEPROM bytes @ **0x2C** | **`c4:ff:84:10:00:ba`** |
| `dsa` / `br0` | **`02:00:b5:7e:67:9e`** |
| `/etc/tpi.cfg` `mac=` | *(empty)* |
| U-Boot `eth0` | `de:ad:be:ef:00:01` *(see [U1](../uboot/IMPROVEMENTS.md))* |

`02:00:…` is a **locally administered** address — typical of **`eth_random_addr()`**
in **`stmmac_check_ether_addr()`** when:

1. `netdev->dev_addr` is still invalid after `of_get_mac_address()` (NVMEM path did
   not populate it), **and**
2. Reading slot 0 from the EMAC hardware also yields no valid address.

There is **no** `device MAC address …` line in dmesg, which suggests either the
message was missed on an older image or `dev_addr` was already considered valid
from a prior partial setup — on 6.18.stmmac the usual failure mode is
`eth_hw_addr_random()` after NVMEM + hardware reads both fail.

**Boot order note:** `at24 0-0050` probes **before** `dwmac-sun8i` in dmesg, so this
is not a simple “EEPROM too late” ordering bug.

**DT / Kconfig (confirmed on unit):**

- `…/ethernet@4500000/nvmem-cells` exists in live DT.
- `CONFIG_NVMEM=y`, `CONFIG_NVMEM_SYSFS=y`, `CONFIG_EEPROM_AT24=y`.
- EEPROM @ 0x2C = `c4:ff:84:10:00:ba` (valid unicast; **not** rejected by
  `is_valid_ether_addr()`).

**Root cause (confirmed on hardware with `nvmem-layout` DT):**

NVMEM is **fully wired** — cell `mac-address@2c,0` reads `c4:ff:84:10:00:ba`,
phandle **0x17** points at the correct node, `nvmem-cell-names` is `mac-address`.
The gap is **`of_get_mac_address()` at `dwmac-sun8i` probe**, which checks (in order):

1. DT property **`mac-address`** on `ethernet@4500000`
2. **`local-mac-address`**
3. **`address`**
4. Only then NVMEM (`nvmem_get_mac_address` → `nvmem_cell_get`)

If U-Boot or the base Allwinner DTS sets a **valid** LA address (e.g. `02:00:…`)
in (1) or (2), the kernel **never reads the EEPROM cell**. `stmmac_check_ether_addr()`
then sees an already-valid `dev_addr` and **does not** log `device MAC address …`.

**Bench — check for a blocking DT property:**

```sh
for p in mac-address local-mac-address address; do
  f=/sys/firmware/devicetree/base/soc/ethernet@4500000/$p
  [ -f "$f" ] && echo -n "$p: " && hexdump -Cv "$f"
done
```

**DTS fix (in tree):** `/delete-property/ mac-address` and `local-mac-address` on
`&emac` so NVMEM is used. **Init safety net:** `apply_bmc_mac.sh` (S00dsa + br0
`pre-up`) reads the NVMEM cell sysfs path above.

**Historical note (pre-`nvmem-layout` DT):** bare `mac-address@2c` under `eeprom@50`
was not registered by at24 on 6.18; that is fixed by `fixed-layout` in DTS.

EEPROM sysfs (`/sys/bus/i2c/devices/0-0050/eeprom`) still works. An NVMEM
provider **`0-00504`** appears under `/sys/bus/nvmem/devices/`, but without
**`nvmem-layout`** the **`mac-address@2c` cell is not registered** for
`of_get_mac_address()` on `&emac`.

**Check NVMEM providers** (list the *devices* subdirectory, not only the bus):

```sh
ls -la /sys/bus/nvmem/devices/
# expect e.g. 0-0050 — if empty, nvmem_register failed (check dmesg for at24)
```

**Proposed DT fix** (`sun8i-t113s-turing-pi2.dtsi`):

```dts
eeprom@50 {
	/* ... */
	nvmem-layout {
		compatible = "fixed-layout";
		#address-cells = <1>;
		#size-cells = <1>;

		mac_address: mac-address@2c {
			reg = <0x2c 0x06>;
		};
	};
};
```

Remove the old bare `mac-address@2c` sibling outside `nvmem-layout`. Keep
`&emac { nvmem-cells = <&mac_address>; … }` unchanged.

**Bench after DT fix + rebuild:**

```sh
ls /sys/bus/nvmem/devices/
cat /sys/class/net/dsa/address    # expect c4:ff:84:10:00:ba
ip link show br0
dmesg | grep -i 'device MAC address'
```

**Note on `ip link set dsa address …`:** `br0` keeps its **own** MAC once the
bridge is up; changing `dsa` alone does not update `br0`. For a manual test use
`ip link set dev br0 address c4:ff:84:10:00:ba` (until reboot).

**Implementation directions:**

1. Apply **`nvmem-layout` / `fixed-layout`** in DTS (above) — primary fix *(in tree)*.
2. Rebuild kernel/DTB, flash, verify `dsa`/`br0` == EEPROM @ 0x2C.
3. **Safety net (in tree):** `set_br0_mac_pre_dhcp.sh` reads EEPROM @ 0x2C when
   `/etc/tpi.cfg` has no `mac=` — sets **`dsa`** and **`br0`** before DHCP.
4. U-Boot [U1](../uboot/IMPROVEMENTS.md) still needed for pre-Linux `ethaddr`.

**Related:** U-Boot [U1](../uboot/IMPROVEMENTS.md) for the same bytes before Linux.

---

## How to use this file

Add **L2**, **L3**, … for further kernel/DT/init backlog items.
