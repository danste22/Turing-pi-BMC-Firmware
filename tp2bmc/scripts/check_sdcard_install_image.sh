#!/usr/bin/env bash
# SD installer image must carry a valid EROFS rootfs on partition 2 (mmcblk0p2).
# BMC-Installer @ eef33d0 reads /dev/mmcblk0p2 and writes it to UBI volume "rootfs".
set -euo pipefail

IMG="${1:-}"
if [[ -z "$IMG" || ! -f "$IMG" ]]; then
	echo "usage: $0 <tp2-bmc-firmware-sdcard.img>" >&2
	exit 2
fi

ROOTFS_PART="${2:-2}"
EROFS_MAGIC=e0f5e1e2
EROFS_SUPER=1024

# Locate partition start (bytes) with fdisk/sfdisk; fall back to genimage layout.
part_start=""
if command -v sfdisk >/dev/null 2>&1; then
	part_start=$(sfdisk -J "$IMG" 2>/dev/null | python3 -c "
import json,sys
j=json.load(sys.stdin)
parts=j.get('partitiontable',{}).get('partitions',[])
for p in parts:
    if p.get('node','').endswith('p${ROOTFS_PART}') or p.get('number')==${ROOTFS_PART}:
        print(int(p['start'])*512)
        break
" 2>/dev/null || true)
fi

if [[ -z "$part_start" ]]; then
	# genimage.cfg: boot @ 1M, 16M FAT, then rootfs
	part_start=$((0x100000 + 16 * 1024 * 1024))
	echo "WARN: using genimage fallback rootfs offset 0x$(printf '%x' "$part_start")"
fi

magic=$(python3 -c "
import struct,sys
off=int(sys.argv[1])+${EROFS_SUPER}
with open(sys.argv[2],'rb') as f:
    f.seek(off)
    print(f'{struct.unpack(\"<I\", f.read(4))[0]:08x}')
" "$part_start" "$IMG")

size=$(stat -f%z "$IMG" 2>/dev/null || stat -c%s "$IMG")
echo "file:           $IMG"
printf "rootfs part:    p%s @ byte 0x%x\n" "$ROOTFS_PART" "$part_start"
printf "erofs magic:    0x%s (expect %s)\n" "$magic" "$EROFS_MAGIC"

fail=0
if [[ "$magic" != "$EROFS_MAGIC" ]]; then
	echo "FAIL: partition ${ROOTFS_PART} is not EROFS — installer cannot create UBI volume rootfs"
	fail=1
else
	# Minimal size sanity (~40 MiB image per genimage 45880K)
	erofs_bytes=$(python3 -c "
import struct,sys
off=int(sys.argv[1])+${EROFS_SUPER}
with open(sys.argv[2],'rb') as f:
    f.seek(off)
    sb=f.read(128)
    blks=struct.unpack_from('<I', sb, 36)[0]
    bits=sb[12]
    print(blks << bits)
" "$part_start" "$IMG")
	echo "erofs size:     $erofs_bytes bytes"
	if (( erofs_bytes < 20 * 1024 * 1024 )); then
		echo "FAIL: EROFS smaller than 20 MiB — rootfs image likely empty or wrong partition"
		fail=1
	else
		echo "OK: SD card carries installable rootfs (mmcblk0p${ROOTFS_PART})"
	fi
fi

exit $fail
