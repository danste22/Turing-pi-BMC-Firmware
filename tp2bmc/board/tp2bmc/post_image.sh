#!/bin/bash

set -euo pipefail
BOARD_DIR="$(cd "$(dirname "$0")" && pwd)"
TP2BMC_DIR="$(cd "${BOARD_DIR}/../.." && pwd)"
# shellcheck source=uboot_build_dir.sh
source "${BOARD_DIR}/uboot_build_dir.sh"

cd "${BINARIES_DIR}"

pin="$(tp2bmc_uboot_pin "${TP2BMC_DIR}/configs/tp2bmc_defconfig")"
if ! uboot_build="$(tp2bmc_uboot_resolve_dir "${BUILD_DIR}" "${pin}")"; then
	echo "${uboot_build}" >&2
	exit 1
fi
if [[ -n "${uboot_build}" ]]; then
	BUILD_DIR="${BUILD_DIR}" UBOOT_DIR="${uboot_build}" \
		"${TP2BMC_DIR}/scripts/validate_spi_boot_stack.sh" \
		"${BINARIES_DIR}/u-boot-sunxi-with-spl.bin"
fi

sdcard_img="${BINARIES_DIR}/tp2-bmc-firmware-sdcard.img"
if [[ -f "${sdcard_img}" ]]; then
	"${TP2BMC_DIR}/scripts/check_sdcard_install_image.sh" "${sdcard_img}"
else
	echo "WARN: missing ${sdcard_img} — SD install image not validated"
fi

create_sdcard() {
    rootpath=$(mktemp -d)
    gencfg="$1"
    bootscript="$2"

    mkdir -p "$rootpath"/boot
    mkimage -A arm -T script -d "$bootscript" "$rootpath"/boot/boot.scr.uimg
    mkimage -A arm -T ramdisk -d installer.cpio.gz "$rootpath"/boot/install.img
    if [ ! -f turing-pi2.itb ]; then
        echo "error: turing-pi2.itb missing from BINARIES_DIR (post_build.sh should copy it)" >&2
        exit 1
    fi
    cp turing-pi2.itb "$rootpath"/boot/turing-pi2.itb
    cp -r $BOARD_DIR/sdcard_overlay/* "$rootpath"/

    chmod -R 755 "$rootpath"

    # Generate the SD image
    [ -d tmp/ ] && rm -fr tmp/
    genimage --inputpath . --outputpath . --rootpath "$rootpath" \
        --config "$gencfg"

    rm -rf "$rootpath"
}

factory_sdcard() {
    # prepare factory overlay partition
    cp -r "$BOARD_DIR"/factory_overlay .

    # Git doesnt support c nodes, manually create them from a .txt file
    while IFS= read -r line
    do
        dest="factory_overlay/upper/${line}"
        echo "deleting ${line} in factory overlay"
        rm -f "$dest"
        mknod  "$dest" c 0 0
        chmod 000 "$dest"
    done < "factory_overlay/files_to_delete.txt"

    # add an additional ext4 partition to the sdcard image in which
    # 'factory_overlay' gets copied into
    cp "$BOARD_DIR/genimage.cfg" factory-genimage.cfg
    patch -p1 < "$BOARD_DIR/factory_overlay_conf.diff"
    create_sdcard  "factory-genimage.cfg" "$BOARD_DIR/factory_install.scr"
}

# Prepare the installer initramfs image
INITRAMFS_DIR=$STAGING_DIR/initramfs/install
(cd $INITRAMFS_DIR && find .) |\
    cpio -oH newc -D $INITRAMFS_DIR |\
    gzip > installer.cpio.gz

create_sdcard  "$BOARD_DIR/genimage.cfg" "$BOARD_DIR/install.scr"
factory_sdcard
