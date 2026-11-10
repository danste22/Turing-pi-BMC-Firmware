# Phase 4 — kernel patch audit

Compare **two patched products** (not the mixed fork `patches/linux` tree):

| Profile | Vanilla | Patches |
|---------|---------|---------|
| **HIVE** | 6.12.109 | excavador `hive` — six flat root patches |
| **TARGET** | 6.18.62 | `IdeaProjects/BMC-Firmware/tp2bmc/patches/linux` (production layout) |

Apply order:

- **HIVE:** `kernel-patch-tool.sh list-order-hive` (Buildroot `LC_COLLATE` on flat names).
- **TARGET:** `kernel-patch-tool.sh list-order` — `generic/i2c` → … → `tp2/tpi-smi-mux` (matches `series.manifest` / `KERNEL_UPGRADE_LOG.md`). Buildroot applies via six `BR2_LINUX_KERNEL_PATCH` directories (no top-level `series` — avoids duplicate apply on linux-headers re-patch).

## Run locally

```bash
cd ~/IdeaProjects/excavador-turing
# TARGET 6.18 needs PATCH_FUZZ=3 for the audit (see APPLY_STATUS.md).
PATCH_FUZZ=3 ./docs/kernel-audit/run-audit.sh
```

`../BMC-Firmware/scripts/` has **no** kernel patch order — only `configure.sh` (buildroot_patches). Kernel order = this tool + `KERNEL_UPGRADE_LOG.md`.

Trees land under `tmp/kernel-audit/` (gitignored). Logs from apply go to your terminal; capture if needed:

```bash
./docs/kernel-audit/run-audit.sh 2>&1 | tee docs/kernel-audit/apply.log
```

## Outputs

- [`FUNCTIONALITY_MATRIX.md`](FUNCTIONALITY_MATRIX.md) — feature rows for your sign-off
- [`SYMBOL_NOTES.md`](SYMBOL_NOTES.md) — codebase-memory traces (after index)

## Index (codebase-memory)

Post-patch trees:

- `tmp/kernel-audit/linux-6.12.109-hive`
- `tmp/kernel-audit/linux-6.18.62-target`

Project names: `tp2-linux-hive-612`, `tp2-linux-target-618`.
