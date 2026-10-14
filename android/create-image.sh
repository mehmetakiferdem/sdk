#!/usr/bin/env bash
# T3 Foundation Gemstone Project [t3gemstone.org]
# SPDX-License-Identifier: Apache-2.0
#
# Creates a raw Android disk image from pre-built partition images.
# No root/sudo required — uses dd with byte offsets instead of loop devices.
#
# Output files:
#   android-<board>.img       → write to SD card (/dev/sdX) or eMMC (/dev/mmcblk0)
#   android-<board>-boot1.img → write to eMMC boot1 hw partition (/dev/mmcblk0boot1)
#
# The optional 4th argument is the image size (default 7G). Growing it only
# grows userdata — the added space is zeroes, so the xz-compressed image barely
# changes: 7G -> 16G costs 1.35 MB of download and yields 11.21 GiB of /data.

set -euo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin:$PATH

ANDROID_DIR="${1:?Usage: create-image.sh <android_dir> <output_dir> <board> [size]}"
OUTPUT_DIR="${2:?Usage: create-image.sh <android_dir> <output_dir> <board> [size]}"
BOARD="${3:-am67a-t3-gem-o1}"
IMG_SIZE="${4:-7G}"

IMG_FILE="$OUTPUT_DIR/android-$BOARD.img"
BOOT1_FILE="$OUTPUT_DIR/android-$BOARD-boot1.img"

mkdir -p "$OUTPUT_DIR"

# ── Dependency check ────────────────────────────────────────────────────────
for tool in sfdisk mkfs.vfat mcopy simg2img python3; do
    command -v "$tool" &>/dev/null || {
        echo "ERROR: missing tool: $tool"
        echo "  Install: sudo apt install dosfstools mtools android-sdk-libsparse-utils python3"
        exit 1
    }
done

echo "=== Android Image Creator ==="
echo "Board  : $BOARD"
echo "Source : $ANDROID_DIR"
echo "Output : $IMG_FILE"
echo ""

# ── Sparse image (size from $IMG_SIZE) ─────────────────────────────────────
echo ">>> [1/4] Creating $IMG_SIZE image..."
truncate -s "$IMG_SIZE" "$IMG_FILE"

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

# ── Parse partition byte offsets from sfdisk JSON ───────────────────────────
echo ">>> [3/4] Writing partition images..."

eval "$(sfdisk -J "$IMG_FILE" | python3 -c "
import sys, json
d = json.load(sys.stdin)
ss = d['partitiontable'].get('sectorsize', 512)
for i, p in enumerate(d['partitiontable']['partitions'], 1):
    print(f'PSTART_{i}={p[\"start\"] * ss}')
    print(f'PNAME_{i}={p.get(\"name\", \"p\" + str(i))}')
")"

# Write a raw image file at a partition's byte offset
write_raw() {
    local partnum=$1 src="$ANDROID_DIR/$2"
    [ -f "$src" ] || { echo "  p$partnum — $2 not found, skipping"; return 0; }
    local offset_var="PSTART_${partnum}" name_var="PNAME_${partnum}"
    local offset=${!offset_var} name=${!name_var}
    local bs=4096
    if (( offset % bs != 0 )); then bs=512; fi
    echo "  p$partnum ($name) ← $2"
    dd if="$src" of="$IMG_FILE" bs=$bs seek=$((offset / bs)) conv=notrunc status=none
}

# Write an Android sparse image (simg2img expands it first)
write_sparse() {
    local partnum=$1 src="$ANDROID_DIR/$2"
    [ -f "$src" ] || { echo "  p$partnum — $2 not found, skipping"; return 0; }
    local offset_var="PSTART_${partnum}" name_var="PNAME_${partnum}"
    local offset=${!offset_var} name=${!name_var}
    echo "  p$partnum ($name) ← $2 (sparse→raw)"
    local tmp
    tmp=$(mktemp "$OUTPUT_DIR/.sparse_XXXXXX")
    simg2img "$src" "$tmp"
    dd if="$tmp" of="$IMG_FILE" bs=4096 seek=$((offset / 4096)) conv=notrunc status=none
    rm -f "$tmp"
}

# p1: bootloader — FAT with tiboot3 + tispl + u-boot
BOOTFAT=$(mktemp --suffix=.fat)
truncate -s 8M "$BOOTFAT"
mkfs.vfat -n bootloader "$BOOTFAT" > /dev/null
mcopy -i "$BOOTFAT" "$ANDROID_DIR/tiboot3-$BOARD-hsfs.bin" ::tiboot3.bin
mcopy -i "$BOOTFAT" "$ANDROID_DIR/tispl-$BOARD.bin"         ::tispl.bin
mcopy -i "$BOOTFAT" "$ANDROID_DIR/u-boot-$BOARD.img"        ::u-boot.img
echo "  p1 (bootloader) ← FAT [tiboot3 + tispl + u-boot]"
dd if="$BOOTFAT" of="$IMG_FILE" bs=4096 seek=$((PSTART_1 / 4096)) conv=notrunc status=none
rm -f "$BOOTFAT"

# p2 (misc), p3 (frp): Android initialises on first boot
write_raw     4  boot.img
write_raw     5  boot.img                  # boot_b
write_raw     6  vendor_boot.img
write_raw     7  vendor_boot.img           # vendor_boot_b
write_raw     8  init_boot.img
write_raw     9  init_boot.img             # init_boot_b
write_raw    10  dtbo.img
write_raw    11  dtbo.img                  # dtbo_b
write_raw    12  vbmeta.img
write_raw    13  vbmeta.img                # vbmeta_b
write_raw    14  vbmeta_vendor_dlkm.img
write_raw    15  vbmeta_vendor_dlkm.img    # vbmeta_vendor_dlkm_b
write_raw    16  vbmeta_system_dlkm.img
write_raw    17  vbmeta_system_dlkm.img    # vbmeta_system_dlkm_b
write_sparse 18  super.img
write_raw    19  metadata.img
write_raw    20  persist.img
# p21 (userdata): left empty — Android formats with f2fs on first boot

# ── tiboot3 at raw 4 MiB offset (TI ROM boot path for SD/eMMC) ─────────────
echo ""
echo ">>> Embedding tiboot3 at raw 4 MiB offset..."
TIBOOT3="$ANDROID_DIR/tiboot3-$BOARD-hsfs.bin"
if [ -f "$TIBOOT3" ]; then
    dd if="$TIBOOT3" of="$IMG_FILE" bs=512 seek=8192 conv=notrunc status=none
    echo "  tiboot3 written at 4 MiB (sector 8192)"
fi

# ── eMMC boot1 image (separate hardware partition) ──────────────────────────
echo ""
echo ">>> [4/4] Creating eMMC boot1 image..."
if [ -f "$TIBOOT3" ]; then
    dd if=/dev/zero  of="$BOOT1_FILE" bs=512 count=10240 status=none
    dd if="$TIBOOT3" of="$BOOT1_FILE" bs=512 conv=notrunc status=none
    echo "  $BOOT1_FILE"
fi

# ── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "=== Done! ==="
echo ""
ls -lh "$IMG_FILE"
[ -f "$BOOT1_FILE" ] && ls -lh "$BOOT1_FILE"
echo ""
echo "Flash to SD card:"
echo "  sudo dd if=$(basename "$IMG_FILE") of=/dev/sdX bs=4M status=progress conv=fsync"
echo ""
echo "Flash to eMMC (via Gemstone Imager or dd):"
echo "  sudo dd if=$(basename "$IMG_FILE") of=/dev/mmcblk0 bs=4M status=progress conv=fsync"
[ -f "$BOOT1_FILE" ] && echo "  echo 0 | sudo tee /sys/block/mmcblk0boot1/force_ro"
[ -f "$BOOT1_FILE" ] && echo "  sudo dd if=$(basename "$BOOT1_FILE") of=/dev/mmcblk0boot1 bs=512 status=progress"
