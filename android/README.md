# Android for T3 Gemstone

This guide covers two workflows:

- **User**: Flash a pre-built Android image to your T3 Gem O1 board
- **Developer**: Set up an AOSP build environment and build Android from source

## Quick Start — Flash a Pre-built Image

### Prerequisites

- T3 Gem O1 board
- microSD card (8 GB or larger)
- Linux host with [Docker](https://docs.docker.com/engine/install/) and [devbox](https://www.jetify.com/docs/devbox/installing_devbox/) installed

### Steps

```bash
# 1. Clone the SDK and enter the build environment
git clone https://github.com/mehmetakiferdem/sdk.git
cd sdk
devbox shell
task box

# 2. Build the Android SD card image (downloads ~1.9 GB on first run)
task android:build MACHINE=t3-gem-o1

# 3. Exit distrobox, write to SD card (replace /dev/sdX with your device!)
exit
lsblk                      # identify your SD card device
sudo dd if=build/android/android-am67a-t3-gem-o1.img of=/dev/sdX bs=4M status=progress conv=fsync

# 4. Insert SD card into the board, power on
```

> **eMMC boot**: Write the main image to `/dev/mmcblk0` and the boot1 image to `/dev/mmcblk0boot1`.
> See `create-image.sh` output for exact commands.

### Available Tasks

| Task | Description |
|---|---|
| `task android:fetch` | Download partition images from GitHub Release |
| `task android:build` | Download + create flashable disk image |
| `task android:flash` | Flash via DFU + fastboot (board in DFU mode) |
| `task android:clean` | Remove all build artifacts |

All tasks require `MACHINE=t3-gem-o1`. Override the release with `ANDROID_RELEASE=vX.Y.Z`.

---

## Developer Guide — Build Android from Source

### System Requirements

| Resource | Minimum |
|---|---|
| OS | Ubuntu 22.04 LTS (x86_64) |
| Disk | 300 GB free |
| RAM | 16 GB (32 GB recommended) |
| CPU | 8+ cores recommended |

### 1. Install Dependencies

```bash
sudo apt-get install -y git curl python3 python-is-python3 repo \
    openjdk-17-jdk build-essential zip unzip libncurses5-dev \
    libssl-dev flex bison rsync lz4 bc cpio

# Install repo tool (if not available via apt)
mkdir -p ~/bin
curl https://storage.googleapis.com/git-repo-downloads/repo > ~/bin/repo
chmod a+x ~/bin/repo
export PATH=~/bin:$PATH
```

### 2. Download AOSP Source

```bash
mkdir -p ~/android-t3 && cd ~/android-t3

# Initialize with T3 Gemstone manifest
repo init -u https://github.com/mehmetakiferdem/android-manifest-t3-gem -b main
repo sync -j$(nproc) --no-tags
```

This downloads ~100 GB of AOSP + TI BSP + T3 board support.

### 3. Build

```bash
cd ~/android-t3

source build/envsetup.sh
lunch am67a-bp2a-userdebug

# Full build (~2-4 hours on first run)
m -j$(nproc)
```

Build output is in `out/target/product/am67a/`.

> **SD card boot**: Add `TARGET_SDCARD_BOOT=true` before the build command:
> ```bash
> TARGET_SDCARD_BOOT=true m -j$(nproc)
> ```

### 4. Build Bootloader

The bootloader is a **separate repo checkout** from the AOSP tree — it comes from
the `bootloaders.xml` manifest in TI's Android manifest repository and contains
U-Boot, ARM Trusted Firmware, OP-TEE and `ti-linux-firmware`:

```bash
mkdir -p ~/android-t3/bootloader && cd ~/android-t3/bootloader

repo init -u https://git.ti.com/git/android/manifest.git \
    -b android16-release -m bootloaders.xml
repo sync -j$(nproc)

# Build all bootloader components (R5 SPL + A53 U-Boot + ATF + OP-TEE)
./build/run_build_all.sh
```

Output files:
- `out/am67a-t3-gem-o1/release/tiboot3-release-hsfs.bin` — R5 SPL
- `out/am67a-t3-gem-o1/release/tispl-release.bin` — A53 SPL
- `out/am67a-t3-gem-o1/release/u-boot-release.img` — U-Boot
- `out/am67a-t3-gem-o1/release/bl31-release.bin`, `tee-release.bin` — ATF / OP-TEE,
  consumed as inputs when U-Boot is rebuilt on its own

#### Rebuilding only A53 U-Boot

After the first full `run_build_all.sh`, U-Boot alone can be rebuilt and installed
into `build/android/` in one step:

```bash
devbox shell   # brings go-task into PATH
task android:uboot:build MACHINE=t3-gem-o1
```

This task runs on the **host**, not inside the distrobox container, because it needs
the toolchain and the BL31/OP-TEE binaries from the bootloader checkout. It defaults
to `BOOTLOADER_DIR=$HOME/android-t3/bootloader`; override it if your checkout lives
elsewhere:

```bash
task android:uboot:build MACHINE=t3-gem-o1 BOOTLOADER_DIR=/path/to/bootloader
```

It does not rebuild `tiboot3` (R5 SPL) — that needs a separate `arm-none-eabi-`
toolchain and is only produced by `run_build_all.sh`.

### 5. Create SD Card Image

Copy the build outputs to the SDK and use `create-image.sh`:

```bash
# Copy AOSP outputs to SDK
SDK_DIR=/path/to/sdk
AOSP_OUT=~/android-t3/out/target/product/am67a
BL_OUT=~/android-t3/bootloader/out/am67a-t3-gem-o1/release

mkdir -p $SDK_DIR/build/android

cp $AOSP_OUT/{boot,super,vendor_boot,init_boot,dtbo,metadata,persist,userdata}.img $SDK_DIR/build/android/
cp $AOSP_OUT/vbmeta*.img $SDK_DIR/build/android/
cp $BL_OUT/tiboot3-release-hsfs.bin $SDK_DIR/build/android/tiboot3-am67a-t3-gem-o1-hsfs.bin
cp $BL_OUT/tispl-release.bin        $SDK_DIR/build/android/tispl-am67a-t3-gem-o1.bin
cp $BL_OUT/u-boot-release.img       $SDK_DIR/build/android/u-boot-am67a-t3-gem-o1.img

# Create SD card image (inside distrobox, or install deps: dosfstools mtools android-sdk-libsparse-utils)
bash $SDK_DIR/android/create-image.sh $SDK_DIR/build/android $SDK_DIR/build/android am67a-t3-gem-o1
```

### 6. Flash

**Method A — SD card (dd):**
```bash
sudo dd if=build/android/android-am67a-t3-gem-o1.img of=/dev/sdX bs=4M status=progress conv=fsync
```

**Method B — DFU + fastboot (eMMC):**

Put the board into DFU mode (hold BOOT button while powering on), then:
```bash
task android:flash MACHINE=t3-gem-o1
```

Or manually:
```bash
cd build/android
sudo ./flashall.sh --board am67a-t3-gem-o1
```

---

## Repository Structure

| Repository | Description |
|---|---|
| [android-manifest-t3-gem](https://github.com/mehmetakiferdem/android-manifest-t3-gem) | Repo manifest (AOSP + TI + T3) |
| [android-t3-gem](https://github.com/mehmetakiferdem/android-t3-gem) | Device tree (`device/ti/am62x/`) + prebuilt image releases |
| [android-am62x-kernel-t3-gem](https://github.com/mehmetakiferdem/android-am62x-kernel-t3-gem) | Kernel prebuilt + DTB |
| [android-kernel-t3-gem](https://github.com/mehmetakiferdem/android-kernel-t3-gem) | Kernel DTS source |

> These repositories currently live under a personal account and are expected to move
> to the `t3gemstone` organization. Override `ANDROID_REPO` / `ANDROID_RELEASE` if you
> host the partition images somewhere else.

### Upstream references

- [TI Processor SDK for AM67A](https://www.ti.com/tool/PROCESSOR-SDK-AM67A) — upstream Android/Linux SDK for the SoC
- TI Android manifest: `https://git.ti.com/git/android/manifest.git`, branch `android16-release`
  (`releases/RLS_11_00.xml` for AOSP, `bootloaders.xml` for the bootloader tree)

## Hardware

- **SoC**: TI AM67A (J722S) — Cortex-A53 + R5F + C7x DSP
- **RAM**: 4 GB LPDDR
- **Storage**: eMMC + SD card
- **Display**: HDMI (SiI9022 bridge)
- **WiFi/BT**: Realtek RTL8822CS (SDIO)
- **Ethernet**: TI DP83867 PHY

## Troubleshooting

### Build fails with "release-config" error
Use `am67a-bp2a-userdebug` as the lunch target (not `am67a-t3-gem-o1-bp2a-userdebug`).

### SD card doesn't boot
- Check the DTB index in the U-Boot env: `adtb_idx=6` selects the T3 Gem O1 DTB.
  `adtb_idx=4` points at the AM67A `j722s-evm` DTB and will not boot this board.
- `boot_targets` must list `mmc1` (SD) before `mmc0` (eMMC), otherwise U-Boot boots
  whatever is on eMMC without touching the card.
- SPL needs `main_gpio1` tagged `bootph-all`: the `vdd_sd_dv` (tlv71033) vqmmc
  regulator is driven from `main_gpio1` pin 49, and without it the SD 3.3V switch
  fails in SPL.
- Verify vbmeta is flashed with matching build (rebuild with `TARGET_SDCARD_BOOT=true m vbmetaimage`)
- Connect serial console (115200 baud) to see boot logs

### No HDMI output
The SiI9022 bridge powers up in power-down mode and needs two fixes, both already
present in the T3 board support:

1. U-Boot pulses the bridge `reset-gpios` in `board_late_init()` before Linux probes it.
2. The kernel DTS declares the SiI9022 interrupt as `EDGE_FALLING` (not `LEVEL_LOW`).

If you are on an older image and HDMI stays dark, the runtime workaround is:
```bash
adb root
adb shell "i2cset -y 5 0x3b 0x1A 0x00"   # wake up SiI9022
```
