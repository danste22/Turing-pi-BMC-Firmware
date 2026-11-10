# Symbol / path notes (post-patch trees)

Codebase-memory index **succeeded** for `tp2-linux-hive-612` and `tp2-linux-target-618` (post-patch trees, `fast` mode). Matrix is unchanged; this file adds symbol-level confirmation.

Below combines tree inspection + graph index.

## HIVE — switch path (I2C)

| Symbol / file | Role |
|---------------|------|
| `drivers/net/dsa/realtek/realtek-i2c.c` | RTK-style regmap over I2C |
| `realtek_i2c_probe` / `rtl8365mb_i2c_driver` | Switch probed as I2C device, not SMI GPIO |
| `drivers/net/dsa/realtek/rtl8365mb.c` | Monolithic driver + `port_vlan_*` + bridge hooks |
| No `tpi-i2c-smi-arbiter.c` | Bus arbiter absent |

## TARGET — switch path (SMI + arbiter)

| Symbol / file | Role |
|---------------|------|
| `drivers/i2c/busses/tpi-i2c-smi-arbiter.c` | PE12/PE13 mux between I2C and SMI |
| `tpi_smi_arb_begin` / `tpi_smi_arb_end` | Called from `realtek-smi.c` around MDIO bitbang |
| `drivers/net/dsa/realtek/rtl8365mb_main.c` | Chip table includes **RTL8370MB-CG** `0x6368` |
| `rtl8365mb_lag.c` | HW LAG (`port_lag_*`) — hive has no equivalent |
| `rtl8365mb_vlan.c` + `rtl83xx.c` | VLAN/bridge offload split across files |

## Shared platform (both audits apply)

| Area | HIVE | TARGET |
|------|------|--------|
| `gpio-aggregator` `turing,pi2-nodes` | root patch | `tp2/gpio/0001` |
| `preserve-boot-state` | root patch | `tp2/power/0001` |
| PWM sun20i | monolith | `generic/pwm/*` |
| gpio-latch shadow | — | `tp2/power/0002` |

## Suggested `trace_path` after index succeeds

- TARGET: `tpi_smi_arb_begin` → callers (expect `realtek_smi_*`)
- TARGET: `rtl8365mb_port_lag_join` → DSA ops table
- HIVE: `realtek_i2c_probe` → `dsa_switch` registration
