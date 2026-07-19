#!/usr/bin/env bash
# SD installer image must carry a valid EROFS rootfs on partition 2 (mmcblk0p2).
# BMC-Installer @ eef33d0 reads /dev/mmcblk0p2 and writes it to UBI volume "rootfs".
set -euo pipefail

IMG="${1:-}"
if [[ -z "$IMG" || ! -f "$IMG" ]]; then
	cat >&2 <<'EOF'
usage: check_sdcard_install_image.sh <tp2-bmc-firmware-sdcard.img> [rootfs_part] [rootfs.erofs]

Validates the SD installer's rootfs partition (default p2). When rootfs.erofs is
given (or found beside the .img), verifies the embedded EROFS is byte-identical
to the build output — the same blob OTA would ship and the installer flashes to NAND.

Optional env:
  TP2_SD_KERNEL_STRING   if set, require this string in the embedded rootfs (e.g. patched kernel)
EOF
	exit 2
fi

ROOTFS_PART="${2:-2}"
ROOTFS_REF="${3:-}"
if [[ -z "$ROOTFS_REF" ]]; then
	ROOTFS_REF="$(dirname "$IMG")/rootfs.erofs"
fi

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

read -r magic erofs_bytes < <(python3 -c "
import struct,sys,os
off=int(sys.argv[1])+${EROFS_SUPER}
img=sys.argv[2]
ref=sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] else ''
with open(img,'rb') as f:
    f.seek(off)
    magic=f.read(4)
    sb=f.read(128)
    # erofs 1.8+ superblock: blkszbits @12, blocks_lo @36 (sb+32 after magic).
    # bytes @14-15 are rootnid_2b OR blocks_hi (union) — do not treat as blocks_hi
    # unless 48-bit block count is enabled (not used on BMC images).
    blks_lo=struct.unpack_from('<I', sb, 32)[0]
    bits=sb[8]
    sb_bytes=blks_lo << bits
if ref and os.path.isfile(ref):
    erofs_bytes=os.path.getsize(ref)
else:
    erofs_bytes=sb_bytes
print(struct.unpack('<I', magic)[0], erofs_bytes)
" "$part_start" "$IMG" "$ROOTFS_REF")

printf "file:           %s\n" "$IMG"
printf "rootfs part:    p%s @ byte 0x%x\n" "$ROOTFS_PART" "$part_start"
printf "erofs magic:    0x%08x (expect %s)\n" "$magic" "$EROFS_MAGIC"

fail=0
if [[ "$(printf '%08x' "$magic")" != "$EROFS_MAGIC" ]]; then
	echo "FAIL: partition ${ROOTFS_PART} is not EROFS — installer cannot create UBI volume rootfs"
	fail=1
else
	echo "erofs size:     $erofs_bytes bytes"
	if (( erofs_bytes < 20 * 1024 * 1024 )); then
		echo "FAIL: EROFS smaller than 20 MiB — rootfs image likely empty or wrong partition"
		fail=1
	else
		echo "OK: SD card carries installable rootfs (mmcblk0p${ROOTFS_PART})"
	fi
fi

if (( fail == 0 )) && [[ -f "$ROOTFS_REF" ]]; then
	ref_bytes=$(stat -f%z "$ROOTFS_REF" 2>/dev/null || stat -c%s "$ROOTFS_REF")
	if (( ref_bytes != erofs_bytes )); then
		echo "FAIL: rootfs.erofs size ${ref_bytes} != SD embedded ${erofs_bytes}"
		fail=1
	else
		embedded_sha=$(python3 -c "
import hashlib,sys
off, size = int(sys.argv[1]), int(sys.argv[2])
h=hashlib.sha256()
with open(sys.argv[3],'rb') as f:
    f.seek(off)
    remain=size
    while remain:
        chunk=f.read(min(remain, 1<<20))
        if not chunk:
            break
        h.update(chunk)
        remain -= len(chunk)
print(h.hexdigest())
" "$part_start" "$erofs_bytes" "$IMG")
		ref_sha=$(sha256sum "$ROOTFS_REF" 2>/dev/null | awk '{print $1}')
		if [[ -z "$ref_sha" ]]; then
			ref_sha=$(shasum -a 256 "$ROOTFS_REF" | awk '{print $1}')
		fi
		printf "rootfs ref:     %s\n" "$ROOTFS_REF"
		printf "sha256:         %s\n" "$embedded_sha"
		if [[ "$embedded_sha" != "$ref_sha" ]]; then
			echo "FAIL: SD rootfs partition differs from ${ROOTFS_REF}"
			fail=1
		else
			echo "OK: SD rootfs partition matches build output (same as OTA)"
		fi
	fi
elif (( fail == 0 )); then
	echo "WARN: no reference rootfs at ${ROOTFS_REF} — skipping byte-identity check"
fi

if (( fail == 0 )) && [[ -n "${TP2_SD_KERNEL_STRING:-}" ]]; then
	if python3 -c "
import sys
off, size, needle = int(sys.argv[1]), int(sys.argv[2]), sys.argv[4].encode()
with open(sys.argv[3],'rb') as f:
    f.seek(off)
    blob=f.read(size)
sys.exit(0 if needle in blob else 1)
" "$part_start" "$erofs_bytes" "$IMG" "$TP2_SD_KERNEL_STRING"; then
		printf "OK: embedded rootfs contains kernel marker: %s\n" "$TP2_SD_KERNEL_STRING"
	else
		echo "FAIL: embedded rootfs missing kernel marker: ${TP2_SD_KERNEL_STRING}"
		fail=1
	fi
fi

exit $fail
