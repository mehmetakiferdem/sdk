#!/usr/bin/env bash
# T3 Foundation Gemstone Project [t3gemstone.org]
# SPDX-License-Identifier: Apache-2.0
#
# Creates a raw Android disk image that can be written to SD card or eMMC with dd or Gemstone Imager.
# Output files:
#   android-<board>.img       → write to /dev/sdX or /dev/mmcblk0  (tiboot3 embedded at 4MiB raw offset)
#   android-<board>-boot1.img → write to /dev/mmcblk0boot1         (optional, eMMC boot1 hw partition)

set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin:$PATH

ANDROID_DIR="${1:?Usage: create-image.sh <android_dir> <output_dir> <board>}"
OUTPUT_DIR="${2:?Usage: create-image.sh <android_dir> <output_dir> <board>}"
BOARD="${3:-am67a-t3-gem-o1}"

IMG_FILE="$OUTPUT_DIR/android-$BOARD.img"
BOOT1_FILE="$OUTPUT_DIR/android-$BOARD-boot1.img"

mkdir -p "$OUTPUT_DIR"

# ── Dependency check ────────────────────────────────────────────────────────
for tool in sfdisk losetup mkfs.vfat mcopy simg2img dd; do
    command -v "$tool" &>/dev/null || {
        echo "ERROR: missing tool: $tool"
        echo "  sudo apt install dosfstools mtools android-sdk-libsparse-utils util-linux"
        exit 1
    }
done

echo "=== Android Image Creator ==="
echo "Board  : $BOARD"
echo "Source : $ANDROID_DIR"
echo "Output : $OUTPUT_DIR"
echo ""

# ── 7 GiB sparse image (super=4.5G, rest~300MB, userdata=remainder ~2.2G) ──
echo ">>> [1/4] Creating 7 GiB image..."
truncate -s 7G "$IMG_FILE"

# ── GPT — matches t3-gem-o1.env Android partition layout ────────────────────
echo ">>> [2/4] Writing GPT partition table..."
sfdisk --quiet "$IMG_FILE" << 'SFDISK'
label: gpt
name=bootloader,          start=5120KiB,  size=8192KiB
name=misc,                start=13824KiB, size=512KiB
name=frp,                                 size=512KiB
name=boot_a,                              size=40960KiB
name=boot_b,                              size=40960KiB
name=vendor_boot_a,                       size=32768KiB
name=vendor_boot_b,                       size=32768KiB
name=init_boot_a,                         size=8192KiB
name=init_boot_b,                         size=8192KiB
name=dtbo_a,                              size=8192KiB
name=dtbo_b,                              size=8192KiB
name=vbmeta_a,                            size=64KiB
name=vbmeta_b,                            size=64KiB
name=vbmeta_vendor_dlkm_a,                size=64KiB
name=vbmeta_vendor_dlkm_b,                size=64KiB
name=vbmeta_system_dlkm_a,                size=64KiB
name=vbmeta_system_dlkm_b,                size=64KiB
name=super,                               size=4718592KiB
name=metadata,                            size=65536KiB
name=persist,                             size=32768KiB
name=userdata
SFDISK

# ── Loop device ─────────────────────────────────────────────────────────────
echo ">>> [3/4] Writing partition images..."
LODEV=$(losetup -fP --show "$IMG_FILE")

cleanup() {
    losetup -d "$LODEV" 2>/dev/null || true
}
trap cleanup EXIT

sleep 1

# Write a raw image to a partition
write_part() {
    local partnum=$1 src=$2
    local srcpath="$ANDROID_DIR/$src"
    if [ -f "$srcpath" ]; then
        echo "  p$partnum ← $src"
        dd if="$srcpath" of="${LODEV}p${partnum}" bs=4M conv=notrunc,fsync status=none
    else
        echo "  p$partnum — $src not found, skipping"
    fi
}

# Write an Android sparse image to a partition (simg2img expands it)
write_sparse() {
    local partnum=$1 src=$2
    local srcpath="$ANDROID_DIR/$src"
    if [ -f "$srcpath" ]; then
        echo "  p$partnum ← $src (sparse→raw)"
        simg2img "$srcpath" "${LODEV}p${partnum}"
    else
        echo "  p$partnum — $src not found, skipping"
    fi
}

# p1: bootloader — FAT with tiboot3 + tispl + u-boot (TI ROM reads from here on SD/eMMC)
echo "  p1  ← bootloader FAT"
mkfs.vfat -n bootloader "${LODEV}p1" > /dev/null
mcopy -i "${LODEV}p1" "$ANDROID_DIR/tiboot3-$BOARD-hsfs.bin" ::tiboot3.bin
mcopy -i "${LODEV}p1" "$ANDROID_DIR/tispl-$BOARD.bin"         ::tispl.bin
mcopy -i "${LODEV}p1" "$ANDROID_DIR/u-boot-$BOARD.img"        ::u-boot.img

# p2 (misc), p3 (frp): no pre-built image, Android initialises these on first boot
write_part  4  boot.img
write_part  5  boot.img              # boot_b
write_part  6  vendor_boot.img
write_part  7  vendor_boot.img       # vendor_boot_b
write_part  8  init_boot.img
write_part  9  init_boot.img         # init_boot_b
write_part 10  dtbo.img
write_part 11  dtbo.img              # dtbo_b
write_part 12  vbmeta.img
write_part 13  vbmeta.img            # vbmeta_b
write_part 14  vbmeta_vendor_dlkm.img
write_part 15  vbmeta_vendor_dlkm.img
write_part 16  vbmeta_system_dlkm.img
write_part 17  vbmeta_system_dlkm.img
write_sparse 18 super.img            # 4.5 GiB sparse → must use simg2img
write_part   19 metadata.img
write_part   20 persist.img
# p21 (userdata): left empty; Android formats it with f2fs on first boot

losetup -d "$LODEV"
trap - EXIT

# ── tiboot3 at raw 4MiB offset (SD card + eMMC UDA boot) ────────────────────
# TI ROM checks this sector on SD card; eMMC falls back to UDA if boot1 is empty
echo ""
echo ">>> Embedding tiboot3 at raw 4MiB offset..."
TIBOOT3_RAW="$ANDROID_DIR/tiboot3-$BOARD-hsfs.bin"
if [ -f "$TIBOOT3_RAW" ]; then
    dd if="$TIBOOT3_RAW" of="$IMG_FILE" bs=512 seek=8192 conv=notrunc status=none
    echo "  tiboot3 written at 4MiB offset"
fi

# ── eMMC boot1 image (tiboot3 raw, separate hardware partition) ──────────────
echo ""
echo ">>> [4/4] Creating eMMC boot1 image (tiboot3 raw)..."
TIBOOT3="$ANDROID_DIR/tiboot3-$BOARD-hsfs.bin"
if [ -f "$TIBOOT3" ]; then
    dd if=/dev/zero  of="$BOOT1_FILE" bs=512 count=10240 status=none
    dd if="$TIBOOT3" of="$BOOT1_FILE" bs=512 conv=notrunc status=none
    echo "  tiboot3 written to $BOOT1_FILE"
else
    echo "  tiboot3-$BOARD-hsfs.bin not found — boot1 image skipped"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Done! ==="
echo ""
echo "Output files:"
echo "  $IMG_FILE"
[ -f "$BOOT1_FILE" ] && echo "  $BOOT1_FILE"
echo ""
echo "Flash with dd or Gemstone Imager:"
echo ""
echo "  # SD card:"
echo "  sudo dd if=$(basename "$IMG_FILE") of=/dev/sdX bs=4M status=progress conv=fsync"
echo ""
echo "  # eMMC (main image):"
echo "  sudo dd if=$(basename "$IMG_FILE") of=/dev/mmcblk0 bs=4M status=progress conv=fsync"
echo ""
echo "  # eMMC boot1 (optional — only if boot1 hw partition needs explicit tiboot3):"
[ -f "$BOOT1_FILE" ] && echo "  echo 0 | sudo tee /sys/block/mmcblk0boot1/force_ro"
[ -f "$BOOT1_FILE" ] && echo "  sudo dd if=$(basename "$BOOT1_FILE") of=/dev/mmcblk0boot1 bs=512 status=progress"
echo "  sync"
