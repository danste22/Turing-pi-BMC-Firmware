#!/usr/bin/env bash
# Validate u-boot-sunxi-with-spl.bin SPI layout against working references
# (b04fcbf / feat/buildroot2025.11: legacy mkimage @ 0x8000, not SPL FIT).
set -euo pipefail

IMG="${1:-}"
if [[ -z "$IMG" || ! -f "$IMG" ]]; then
	echo "usage: $0 <u-boot-sunxi-with-spl.bin>" >&2
	exit 2
fi

UBOOT_OFFS=32768  # 0x8000

hex_at() {
	xxd -p -l 4 -s "$1" "$IMG" | tr -d '\n'
}

size=$(stat -f%z "$IMG" 2>/dev/null || stat -c%s "$IMG")
egon_len=$(python3 -c "import sys; print(int.from_bytes(open(sys.argv[1],'rb').read()[16:20],'little'))" "$IMG")
load_offs=$egon_len
(( load_offs < UBOOT_OFFS )) && load_offs=$UBOOT_OFFS

magic=$(python3 -c "import struct,sys; d=open(sys.argv[1],'rb').read(); print(f'{struct.unpack_from(\">I\", d, int(sys.argv[2]))[0]:08x}')" "$IMG" "$UBOOT_OFFS")
ih_magic=27051956
fdt_magic=edfe0dd0

echo "file:      $IMG"
echo "size:      $size bytes"
printf "eGON len:  0x%x\n" "$egon_len"
printf "SPL load @ 0x%x (max(eGON, 0x8000))\n" "$load_offs"
printf "magic@8K:  0x%s (image_get_magic / uimage_to_cpu)\n" "$magic"

fail=0
if [[ "$magic" == "27051956" ]]; then
	echo "OK: legacy mkimage @ 0x8000 (feat/buildroot2025.11 / b04fcbf layout)"
elif [[ "$magic" == "$fdt_magic" ]]; then
	echo "FAIL: FIT @ 0x8000 — wrong for working SPI path"
	echo "      Use OF_EMBED and unset CONFIG_SPL_LOAD_FIT in uboot_defconfig."
	fail=1
elif [[ "$magic" == "ffffffff" ]]; then
	echo "FAIL: erased / missing payload @ 0x8000"
	fail=1
else
	echo "FAIL: unknown header @ 0x8000 (expected IH_MAGIC ${ih_magic})"
	fail=1
fi

echo "installer: SD +8192 -> MTD boot +0 (flash[0x8000] = file[0x8000])"
exit $fail
