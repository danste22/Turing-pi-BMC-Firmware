# Turing Pi BMC — kernel port (danste22 fork)

Language for the hive → 6.18 validation work on branch `kernel-6.18`.

**Execution plan (canonical, sole):** [`docs/PLAN.md`](docs/PLAN.md). No separate Cursor plan.

## Language

**Hive line:**
Firmware track from excavador branch `hive` (kernel 6.12.109, BMC-UI v4.5.0, excavador tpi/bmcd pins).
_Avoid:_ hive (when you mean the branch alone), upstream image.

**Stock snapshot:**
Phase 2 capture on an unmodified Hive line image (`docs/baselines/stock-snapshot/`).
_Avoid:_ baseline.

**Harness golden:**
Phase 3 capture after the test harness is on the image, kernel still 6.12.109 (`docs/baselines/harness-golden/`).
_Avoid:_ baseline, golden log.

**Comparison run:**
Phase 8 capture after the 6.18 image (`docs/baselines/comparison-run/`).
_Avoid:_ baseline.

**Import:**
Copy userspace harness files from IdeaProjects into this fork.
_Avoid:_ port (for shell scripts).

**Rebase:**
Refresh a kernel patch so it applies on the pinned 6.18.y tree.
_Avoid:_ port (for patches).
