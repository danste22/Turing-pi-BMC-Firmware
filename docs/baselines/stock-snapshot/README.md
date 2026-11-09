# Stock snapshot

Record of the board on an unmodified **Hive line** image before the kernel 6.18 port.

**Valid when:** `kernel-release.log` is `6.12.109` and the image matches excavador hive pins (no harness overlay, no custom kernel branch flashed yet).

## Files

| File | Contents |
|------|-----------|
| `kernel-release.log` | `uname -r` |
| `uname.log` | `uname -a` |
| `ip-link.log` | `ip -br link` |
| `proc-version.log` | optional ` /proc/version` |
| `captured-at.txt` | capture timestamp (ISO-8601) |

Do not commit passwords, cookies, or Playwright traces. Board MAC in these logs is expected.

## Re-capture

On the BMC:

```sh
mkdir -p /tmp/stock-snapshot && cd /tmp/stock-snapshot
uname -a        > uname.log
uname -r        > kernel-release.log
ip -br link     > ip-link.log
date -Iseconds  > captured-at.txt
```

Copy to this directory from your workstation, then commit.
