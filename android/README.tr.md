# T3 Gemstone Android

Bu rehber iki kullanım senaryosunu kapsar:

- **Kullanıcı**: Hazır Android imajını T3 Gem O1 kartına yüklemek
- **Geliştirici**: AOSP kaynak kodundan Android derlemek

## Hızlı Başlangıç — Hazır İmaj Yükleme

### Gereksinimler

- T3 Gem O1 kartı
- microSD kart (en az 8 GB)
- Docker ve [devbox](https://www.jetify.com/docs/devbox/installing_devbox/) kurulu bir Linux bilgisayar

### Adımlar

```bash
# 1. SDK'yı indirin ve derleme ortamına girin
# Android desteği şu an android-build dalında bulunuyor
git clone -b android-build https://github.com/mehmetakiferdem/sdk.git
cd sdk
devbox shell
task box

# 2. Android SD kart imajını oluşturun (ilk çalıştırmada ~1.9 GB indirir)
task android:build MACHINE=t3-gem-o1

# 3. Distrobox'tan çıkın, SD karta yazın (/dev/sdX yerine kendi cihazınızı yazın!)
exit
lsblk                      # SD kart cihazınızı belirleyin
sudo dd if=build/android/android-am67a-t3-gem-o1.img of=/dev/sdX bs=4M status=progress conv=fsync

# 4. SD kartı karta takın, gücü verin
```

> **eMMC'ye yükleme**: Ana imajı `/dev/mmcblk0`'a, boot1 imajını `/dev/mmcblk0boot1`'e yazın.
> Komutlar için `create-image.sh` çıktısına bakın.

### Mevcut Görevler

| Görev | Açıklama |
|---|---|
| `task android:fetch` | GitHub Release'den partition imajlarını indir |
| `task android:build` | İndir + flashlanabilir disk imajı oluştur |
| `task android:flash` | DFU + fastboot ile yükle (kart DFU modunda olmalı) |
| `task android:clean` | Tüm derleme çıktılarını sil |

Tüm görevler `MACHINE=t3-gem-o1` gerektirir. Sürümü değiştirmek için: `ANDROID_RELEASE=vX.Y.Z`.

---

## Geliştirici Rehberi — Kaynak Koddan Android Derleme

### Sistem Gereksinimleri

| Kaynak | Minimum |
|---|---|
| İşletim Sistemi | Ubuntu 22.04 LTS (x86_64) |
| Disk | 300 GB boş alan |
| RAM | 16 GB (32 GB önerilen) |
| CPU | 8+ çekirdek önerilen |

### 1. Bağımlılıkları Kurun

```bash
sudo apt-get install -y git curl python3 python-is-python3 repo \
    openjdk-17-jdk build-essential zip unzip libncurses5-dev \
    libssl-dev flex bison rsync lz4 bc cpio

# repo aracı (apt ile gelmediyse)
mkdir -p ~/bin
curl https://storage.googleapis.com/git-repo-downloads/repo > ~/bin/repo
chmod a+x ~/bin/repo
export PATH=~/bin:$PATH
```

### 2. AOSP Kaynak Kodunu İndirin

```bash
mkdir -p ~/android-t3 && cd ~/android-t3

# T3 Gemstone manifest ile başlatma
repo init -u https://github.com/mehmetakiferdem/android-manifest-t3-gem -b main
repo sync -j$(nproc) --no-tags
```

Bu işlem ~100 GB AOSP + TI BSP + T3 kart desteği indirir.

### 3. Derleme

```bash
cd ~/android-t3

source build/envsetup.sh
lunch am67a-bp2a-userdebug

# Tam derleme (ilk seferinde ~2-4 saat)
m -j$(nproc)
```

Derleme çıktısı `out/target/product/am67a/` dizinindedir.

> **SD kart boot**: Derleme komutunun başına `TARGET_SDCARD_BOOT=true` ekleyin:
> ```bash
> TARGET_SDCARD_BOOT=true m -j$(nproc)
> ```

### 4. Bootloader Derleme

Bootloader, AOSP ağacından **ayrı bir repo checkout'udur** — TI'nin Android manifest
deposundaki `bootloaders.xml` manifestinden gelir ve U-Boot, ARM Trusted Firmware,
OP-TEE ile `ti-linux-firmware` bileşenlerini içerir:

```bash
mkdir -p ~/android-t3/bootloader && cd ~/android-t3/bootloader

repo init -u https://git.ti.com/git/android/manifest.git \
    -b android16-release -m bootloaders.xml
repo sync -j$(nproc)

# Tüm bootloader bileşenleri (R5 SPL + A53 U-Boot + ATF + OP-TEE)
./build/run_build_all.sh
```

Çıktı dosyaları:
- `out/am67a-t3-gem-o1/release/tiboot3-release-hsfs.bin` — R5 SPL
- `out/am67a-t3-gem-o1/release/tispl-release.bin` — A53 SPL
- `out/am67a-t3-gem-o1/release/u-boot-release.img` — U-Boot
- `out/am67a-t3-gem-o1/release/bl31-release.bin`, `tee-release.bin` — ATF / OP-TEE;
  U-Boot tek başına yeniden derlenirken girdi olarak kullanılır

#### Sadece A53 U-Boot'u yeniden derleme

İlk tam `run_build_all.sh` çalıştırıldıktan sonra, U-Boot tek başına derlenip
`build/android/` dizinine tek adımda kurulabilir:

```bash
devbox shell   # go-task'ı PATH'e getirir
task android:uboot:build MACHINE=t3-gem-o1
```

Bu task distrobox konteynerinin **içinde değil, host'ta** çalışır; çünkü bootloader
checkout'undaki toolchain ile BL31/OP-TEE ikililerine ihtiyaç duyar. Varsayılanı
`BOOTLOADER_DIR=$HOME/android-t3/bootloader`'dır, farklı bir yerdeyse değiştirin:

```bash
task android:uboot:build MACHINE=t3-gem-o1 BOOTLOADER_DIR=/path/to/bootloader
```

`tiboot3` (R5 SPL) bu task ile üretilmez — onun için ayrı bir `arm-none-eabi-`
toolchain gerekir ve yalnızca `run_build_all.sh` çıkarır.

### 5. SD Kart İmajı Oluşturma

Derleme çıktılarını SDK'ya kopyalayıp `create-image.sh` ile imaj oluşturun:

```bash
# AOSP çıktılarını SDK'ya kopyala
SDK_DIR=/path/to/sdk
AOSP_OUT=~/android-t3/out/target/product/am67a
BL_OUT=~/android-t3/bootloader/out/am67a-t3-gem-o1/release

mkdir -p $SDK_DIR/build/android

cp $AOSP_OUT/{boot,super,vendor_boot,init_boot,dtbo,metadata,persist,userdata}.img $SDK_DIR/build/android/
cp $AOSP_OUT/vbmeta*.img $SDK_DIR/build/android/
cp $BL_OUT/tiboot3-release-hsfs.bin $SDK_DIR/build/android/tiboot3-am67a-t3-gem-o1-hsfs.bin
cp $BL_OUT/tispl-release.bin        $SDK_DIR/build/android/tispl-am67a-t3-gem-o1.bin
cp $BL_OUT/u-boot-release.img       $SDK_DIR/build/android/u-boot-am67a-t3-gem-o1.img

# SD kart imajı oluştur (distrobox içinde veya doğrudan: apt install dosfstools mtools android-sdk-libsparse-utils)
bash $SDK_DIR/android/create-image.sh $SDK_DIR/build/android $SDK_DIR/build/android am67a-t3-gem-o1
```

### 6. Karta Yükleme

**Yöntem A — SD kart (dd):**
```bash
sudo dd if=build/android/android-am67a-t3-gem-o1.img of=/dev/sdX bs=4M status=progress conv=fsync
```

**Yöntem B — DFU + fastboot (eMMC):**

Kartı DFU moduna alın (BOOT düğmesine basılı tutarak gücü verin), sonra:
```bash
task android:flash MACHINE=t3-gem-o1
```

Veya manuel:
```bash
cd build/android
sudo ./flashall.sh --board am67a-t3-gem-o1
```

---

## Repo Yapısı

| Repo | Açıklama |
|---|---|
| [android-manifest-t3-gem](https://github.com/mehmetakiferdem/android-manifest-t3-gem) | Repo manifest (AOSP + TI + T3) |
| [android-t3-gem](https://github.com/mehmetakiferdem/android-t3-gem) | Device tree (`device/ti/am62x/`) + hazır imaj release'leri |
| [android-am62x-kernel-t3-gem](https://github.com/mehmetakiferdem/android-am62x-kernel-t3-gem) | Kernel prebuilt + DTB |
| [android-kernel-t3-gem](https://github.com/mehmetakiferdem/android-kernel-t3-gem) | Kernel DTS kaynağı |

> Bu depolar şu an kişisel bir hesap altındadır ve `t3gemstone` organizasyonuna
> taşınması planlanmaktadır. Partition imajlarını başka bir yerde barındırıyorsanız
> `ANDROID_REPO` / `ANDROID_RELEASE` değişkenlerini geçersiz kılın.

### Üst kaynaklar

- [TI Processor SDK for AM67A](https://www.ti.com/tool/PROCESSOR-SDK-AM67A) — SoC'nin üst kaynak Android/Linux SDK'sı
- TI Android manifest: `https://git.ti.com/git/android/manifest.git`, dal `android16-release`
  (AOSP için `releases/RLS_11_00.xml`, bootloader ağacı için `bootloaders.xml`)

## Donanım

- **SoC**: TI AM67A (J722S) — Cortex-A53 + R5F + C7x DSP
- **RAM**: 4 GB LPDDR
- **Depolama**: eMMC + SD kart
- **Ekran**: HDMI (SiI9022 bridge)
- **WiFi/BT**: Realtek RTL8822CS (SDIO)
- **Ethernet**: TI DP83867 PHY

## Sorun Giderme

### Derleme "release-config" hatası veriyor
Lunch hedefi olarak `am67a-bp2a-userdebug` kullanın (`am67a-t3-gem-o1-bp2a-userdebug` değil).

### SD kart boot etmiyor
- U-Boot env'deki DTB indeksini kontrol edin: T3 Gem O1 DTB'sini `adtb_idx=6` seçer.
  `adtb_idx=4` AM67A `j722s-evm` DTB'sini gösterir ve bu kartı boot etmez.
- `boot_targets` listesinde `mmc1` (SD), `mmc0`'dan (eMMC) önce gelmelidir; aksi halde
  U-Boot karta hiç bakmadan eMMC'deki imajı boot eder.
- SPL'de `main_gpio1` düğümü `bootph-all` ile işaretli olmalıdır: `vdd_sd_dv` (tlv71033)
  vqmmc regülatörü `main_gpio1` pin 49 üzerinden sürülür, bu olmadan SD 3.3V geçişi
  SPL'de başarısız olur.
- vbmeta'nın eşleşen build ile flashlandığını doğrulayın (`TARGET_SDCARD_BOOT=true m vbmetaimage` ile yeniden derleyin)
- Seri konsolu (115200 baud) bağlayarak boot loglarını izleyin

### HDMI çıktısı yok
SiI9022 bridge güç-kapalı (power-down) modda açılır ve iki düzeltmeye ihtiyaç duyar;
ikisi de T3 kart desteğinde mevcuttur:

1. U-Boot, `board_late_init()` içinde bridge'in `reset-gpios` hattına Linux prob
   etmeden önce reset darbesi uygular.
2. Kernel DTS'inde SiI9022 kesmesi `LEVEL_LOW` yerine `EDGE_FALLING` olarak tanımlıdır.

Eski bir imajdaysanız ve HDMI hâlâ karanlıksa, çalışma anındaki geçici çözüm:
```bash
adb root
adb shell "i2cset -y 5 0x3b 0x1A 0x00"   # SiI9022'yi uyandır
```
