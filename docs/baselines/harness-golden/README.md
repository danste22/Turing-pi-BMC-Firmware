# Harness golden

Captured on the **Phase 3** image: same Hive userspace pins as stock, plus `hw-validate` overlay. Kernel must still be **6.12.109**.

**6.18 TARGET (Phase 6/7):** see [`618-phase6-7-review.md`](618-phase6-7-review.md) and `hw-validate-6.18.62-*.log`. Port sign-off is **F1/F5/G + A1**, not necessarily zero harness FAILs until overlay hygiene is ported.

| File | How |
|------|-----|
| `hw-validate.log` | On board: `hw-validate.sh --mode 1 --mac …` (6.12 stock golden) |
| `api-smoke.log` | Host: `tests/board-api-smoke.sh` |
| `playwright.log` | Host: `cd tests/ui-e2e && npm run test:log` |

Commit redacted logs after capture. No passwords in git.
