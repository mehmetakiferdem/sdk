# T3 Gemstone O1 — Android 16 Portu: Sıfırdan Kurulum ve Derleme

Bu belge, boş bir makineden başlayıp T3 Gem O1 kartında çalışan bir Android 16
imajına ulaşmanın tam yolunu anlatır. `android/README.md` "hazır imajı nasıl
yakarım"ı anlatır; bu belge ise **kaynaktan nasıl buraya gelindiğini** ve portun
neden bu şekilde kurulduğunu anlatır.

**Doğrulama tarihi:** 25 Ağustos 2026; 5, 6, 12 ve 13. bölümler 23 Eylül 2026'da
güncellendi. Komutların çoğu bu makinedeki ağaç üzerinde teyit edildi; teyit
edilemeyen adımlar açıkça "doğrulanmadı" diye işaretlendi.

> ### Başlamadan önce: iki blokaj
>
> Bugün sıfırdan `repo sync` + `m` yapan biri **derleme hatası alır**. İkisi de
> Adım 2'de ele alınıyor, ama önden bilmek zaman kazandırır:
>
> 1. **`android-am62x-kernel-t3-gem` deposu boş.** Manifest `device/ti/am62x-kernel`
>    yolunu bu depoya bağlıyor, ama depo şu an sıfır byte (GitHub API: `isEmpty: true`,
>    son push 20 Mayıs 2026). `repo sync` bu projeyi TI'nin kendi deposundan çekiyor.
> 2. **Sonuç olarak `k3-am67a-t3-gem-o1.dtb` ağaçta yok.** `build/tasks/dtimages.mk`
>    bu dosyayı `DTB_FILES` listesinde şart koşuyor, dolayısıyla `m` `dtb.img`
>    üretirken durur. Aynı sebeple RTW88 (WiFi) modülleri de eksiktir.

---

## 1. Kart ve boot zinciri

| Bileşen | Detay |
|---|---|
| SoC | TI AM67A (J722S) — Cortex-A53 ×4 + R5F + C7x DSP |
| RAM | 4 GB LPDDR |
| Depolama | eMMC (`sdhci0`, `fa10000.mmc`) + microSD (`sdhci1`, `fa00000.mmc`) |
| Ekran | HDMI, SiI9022 köprüsü (`main_i2c0` @ 0x3b, Linux'ta `i2c-5`) |
| WiFi/BT | Realtek RTL8822CS (SDIO) |
| Ethernet | TI DP83867 PHY |
| PMIC | TI TPS65219 (`wkup_i2c0`) |
| DT uyumluluk | `obsidian,am67a-t3-gem-o1`, `ti,j722s` |

Boot zinciri, hangi adımın hangi ikiliden geldiğini bilmek açısından önemlidir:

```
ROM
 └─ tiboot3.bin          R5 SPL + DM firmware        (raw, 4 MiB offset)
     └─ tispl.bin        A53 SPL + BL31 + OP-TEE     (FAT bootloader bölümü)
         └─ u-boot.img   Android bootmeth            (FAT bootloader bölümü)
             └─ A/B slot seçimi + AVB doğrulaması
                 └─ boot.img + vendor_boot.img       (kernel, DTB, vendor ramdisk)
                     └─ init first stage             (fstab, super.img mount)
                         └─ Android
```

`tiboot3.bin` ve `tispl.bin`/`u-boot.img` **AOSP derlemesinden gelmez** —
ayrı bir bootloader ağacından derlenir (Adım 5).

---

## 2. Depo haritası

| Depo | Dal | Ağaçtaki yeri / rolü |
|---|---|---|
| `mehmetakiferdem/android-manifest-t3-gem` | `main` | `repo init` hedefi. `default.xml` (AOSP), `bootloaders.xml`, `kernel-6.12.xml` |
| `mehmetakiferdem/android-t3-gem` | `t3-gem-o1` | `device/ti/am62x` — cihaz ağacı, portun kalbi |
| `mehmetakiferdem/android-am62x-kernel-t3-gem` | `t3-gem-o1` | `device/ti/am62x-kernel` — kernel'in **derlenmiş çıktısı**. **Şu an boş** |
| `mehmetakiferdem/android-kernel-t3-gem` | `t3-gem-o1` | T3 **DTS yaması** — yalnızca 3 dosya. **Bayat, kullanmayın** (Adım 2) |
| `mehmetakiferdem/linux` | `v6.12.24-ti-arm64-r43-t3-gem-o1` | T3 DTS'inin **güncel** kaynağı — Linux SDK ile paylaşılan |
| `mehmetakiferdem/u-boot` | `t3-gem-o1-android-v1` | Android U-Boot |
| `mehmetakiferdem/sdk` | `android-build` | Disk imajı üretimi + flash otomasyonu |

Manifest'in içindeki kritik satırlar (`default.xml`):

```xml
<remote name="t3gemstone" fetch="https://github.com/mehmetakiferdem/" />
<default revision="refs/tags/android-16.0.0_r2" remote="aosp" sync-j="4" />
...
<project path="device/ti/am62x"        name="android-t3-gem"              remote="t3gemstone" revision="t3-gem-o1" />
<project path="device/ti/am62x-kernel" name="android-am62x-kernel-t3-gem"  remote="t3gemstone" revision="t3-gem-o1" />
<project path="hardware/ti/am62x"      name="android/hardware-ti-am62x"    remote="git-ti-com" revision="d-android16-release" />
<project path="vendor/ti/am62x"        name="android/vendor-ti-am62x"      remote="git-ti-com" revision="d-android16-release" />
```

`t3gemstone` remote adı aslında kişisel hesaba bakıyor — depolar organizasyona
taşınırken düzeltilmesi gereken bir tuzak.

---

## 3. Derleme makinesi

| Kaynak | Asgari | Not |
|---|---|---|
| OS | Ubuntu 22.04 LTS x86_64 | Pardus üzerinde de çalışıyor |
| Disk | 300 GB boş | `.repo` tek başına ~128 GB, `out/` ~150 GB |
| RAM | 16 GB | **32 GB önerilir**, aşağıya bakın |
| CPU | 8+ çekirdek | |

**Bellek tuzağı (yaşandı, iki kez donma):** Soong'un analiz aşaması tek başına
≥15 GB istiyor. 31 GB'lık bir makinede tarayıcı (~8 GB) açıkken derleme sistemi
kilitliyor. Çare, derlemeyi bir cgroup kafesine almak:

```bash
# 1. Oturuma tavan koy (reboot'ta sıfırlanır)
sudo systemctl set-property --runtime session-1.scope MemoryHigh=10G

# 2. Derlemeyi kafeste çalıştır
systemd-run --user --scope -p MemoryHigh=15G -p MemoryMax=20G \
    bash --norc -c '...m ... -j8'

# 3. Bittikten sonra geri al
sudo systemctl set-property --runtime session-1.scope MemoryHigh=infinity
```

`earlyoom` kuruluysa (`-r 3600 -m 8 -s 95`), derleme sırasında bir süreç
"Terminated" ile ölerse sebebi büyük ihtimalle odur — derleyici hatası değil.

Bağımlılıklar:

```bash
sudo apt-get install -y git curl python3 python-is-python3 \
    openjdk-17-jdk build-essential zip unzip libncurses5-dev \
    libssl-dev flex bison rsync lz4 bc cpio libelf-dev libdw-dev

mkdir -p ~/bin
curl https://storage.googleapis.com/git-repo-downloads/repo > ~/bin/repo
chmod a+x ~/bin/repo
export PATH=~/bin:$PATH
```

`libelf-dev` ve `libdw-dev`, kernel modülü derlemek gerekirse (Adım 3) şart —
yoksa BPF/BTF host araçları `libelf.h` bulamaz.

---

## 4. Adım 1 — AOSP kaynağını indir

```bash
mkdir -p ~/android-t3 && cd ~/android-t3
repo init -u https://github.com/mehmetakiferdem/android-manifest-t3-gem -b main
repo sync -j$(nproc) --no-tags
```

Yaklaşık 100 GB iner. `.repo` dizini başka bir diske taşınabilir; ağaç içinde
sembolik bağ bırakmak yeterlidir (bu makinede `.repo → /mnt/hdd/aosp/.repo`),
derlemeyi etkilemez.

Ağaç bir kez indikten sonra ağsız kurtarma mümkündür: `repo sync -l` yalnızca
yerel git nesnelerinden çalışma kopyalarını yeniden yazar.

---

## 5. Adım 2 — Prebuilt kernel ve T3 DTB'si

### Önce: neden "iki kernel deposu" var?

İki kernel yok — bir kernel var, iki depo onun **kaynağını** ve **derlenmiş
çıktısını** ayrı ayrı taşıyor. AOSP'nin GKI modelinde AOSP ağacı kernel'i hiç
derlemez; kernel başka bir ağaçta derlenir ve ikilileri AOSP'ye commit'lenir.

| Depo | Ne içerir | Nerede durur | Ne zaman dokunulur |
|---|---|---|---|
| `android-am62x-kernel-t3-gem` | `Image`, 200+ `.ko`, DTB'ler, `Module.symvers`, header'lar | `device/ti/am62x-kernel` — normal `repo sync` ile gelir | Hiç elle derlenmez; her AOSP derlemesi buradan **tüketir** |
| `android-kernel-t3-gem` | Yalnızca 3 dosya: `k3-am67a-t3-gem-o1.dts`, `-pinmux.dtsi` ve düzenlenmiş `arch/arm64/boot/dts/ti/Makefile` (toplam 13 KB) | Ayrı kernel ağacında `ti-linux-kernel/` — `kernel-6.12.xml` manifest'i ile, normal sync'e **dahil değil** | ⚠ Mayıs 2026'dan beri güncellenmedi; Eylül 2026'daki kernel TI'nin tam `ti-linux-kernel` ağacından derlendi, bu depodan değil (bkz. 13. bölüm) |

Akış tek yönlü:

```
android-kernel-t3-gem (DTS)
   └─ kernel kaynak ağacında derlenir  →  k3-am67a-t3-gem-o1.dtb
        └─ android-am62x-kernel-t3-gem'e commit'lenir
             └─ repo sync → device/ti/am62x-kernel
                  └─ m → dtb.img / vendor_boot.img
```

> **İsimlendirme tuzağı:** `android-kernel-t3-gem` bir kernel değil, bir DTS
> yaması. Depolar organizasyona taşınırken adının (örn. `android-dts-t3-gem`)
> düzeltilmesi karışıklığı bitirir.
>
> **Manifest tuzağı:** `kernel-6.12.xml` bu depoyu `ti-linux-kernel/` yoluna,
> gerçek kernel kaynağının (`common/`, TI'nin `ti-linux-kernel/ti-linux-kernel`
> deposu, `android16-6.12.y`) **yanına** bağlıyor. Yani dosyalar kernel kaynağının
> içine kendiliğinden girmez; derlemeden önce elle kopyalanmaları gerekir.

### Prebuilt kernel'in içeriği

AOSP ağacı kernel'i derlemez, `device/ti/am62x-kernel` altındaki hazır ikilileri
tüketir. Bu ikililer TI'nin yayımladığı prebuilt'ten gelmiyor artık; T3 için ayrı
bir kernel ağacında (kleaf/bazel) derlenip bu depoya commit'leniyor:

```
device/ti/am62x-kernel/kernel/6.12/
├── Image, Image.lz4, vmlinux, System.map
├── kernel_aarch64_dot_config          ← GKI .config
├── kernel_aarch64_Module.symvers      ← yalnızca GKI sembolleri
├── k3-*.dtb                           ← kart DTB'leri
├── vendor_dlkm/                       ← 89 adet .ko
├── ramdisk/, system_dlkm/
└── kernel-headers.tar.gz
```

Kernel sürümü: `6.12.23-android16-5-4k`.

### Depo artık dolu — bu adım geçmişte kaldı (Eylül 2026)

Ağustos 2026'da `android-am62x-kernel-t3-gem` boştu; `repo sync` TI'nin deposundan
T3 DTB'si ve RTW88 modülleri olmayan bir prebuilt getiriyordu, bu yüzden aşağıdaki
"DTS'i elle derle, modülleri ağaç dışı üret" yolları gerekiyordu. **Artık gerekmiyor.**

Depo `t3-gem-o1` dalında dolu ve her şeyi tek bir kleaf (bazel) derlemesinden
alıyor: kernel, T3 DTB'si, 453 modül, `vendor_dlkm`/`system_dlkm` imajları. Manifest
zaten oraya bakıyor, yani sıfırdan `repo sync` yapan doğru içeriği alır ve bu bölümü
hiç okumak zorunda kalmaz.

```bash
ls device/ti/am62x-kernel/kernel/6.12/ | grep t3-gem     # k3-am67a-t3-gem-o1.dtb
ls device/ti/am62x-kernel/kernel/6.12/vendor_dlkm | grep rtw   # 4 modül
```

Kernel sürümü: `6.12.23-android16-5-4k`.

### DTB index'i — hâlâ geçerli kural

`device/ti/am62x/build/tasks/dtimages.mk`:

```make
DTB_FILES := \
	$(LOCAL_DTB)/k3-am625-sk.dtb \
	$(LOCAL_DTB)/k3-am62-lp-sk.dtb \
	$(LOCAL_DTB)/k3-am625-beagleplay.dtb \
	$(LOCAL_DTB)/k3-am62p5-sk.dtb \
	$(LOCAL_DTB)/k3-j722s-evm.dtb \
	$(LOCAL_DTB)/k3-am67a-beagley-ai.dtb \
	$(LOCAL_DTB)/k3-am67a-t3-gem-o1.dtb      ← index 6
```

**Bu listedeki sıra sabittir.** U-Boot DTB'yi indeksle seçiyor (`adtb_idx=6`), yani
listeye yalnızca sondan eklenebilir; araya girmek çalışan kartları bozar.

### Prebuilt'i yeniden üretmek gerekirse

Kernel kaynağı ayrı bir `repo` ağacında durur (`kernel-6.12.xml`): `ti-linux-kernel/`
gerçek kaynak, `common/` GKI tarafı. T3 değişiklikleri:

| Ağaç | Commit | Ne |
|---|---|---|
| `ti-linux-kernel` | `6279a632` | T3 Gemstone O1 DTS + pinmux |
| `ti-linux-kernel` | `c437c31e` | `sii902x`: TMDS'i probe'da aç (HDMI'ın çalışması için şart) |
| `ti-linux-kernel` | `0b7efc19`, `7e0045e0` | DTS'i Linux SDK'sıyla senkronla, i2c1 GPIO recovery'yi koru |
| `common` | `d33ca763` | GKI TI sembol listesine `sdio_align_size`, `sdio_readl`, `sdio_writel` |

```bash
cd <kernel-6.12 ağacı>
export LC_ALL=C.UTF-8
tools/bazel --output_user_root=/mnt/nvme/bazel-kernel \
    build --config=ti //private/devices/ti/am6x:ti_dist
tools/bazel --output_user_root=/mnt/nvme/bazel-kernel \
    run --config=ti //private/devices/ti/am6x:ti_dist -- --destdir /tmp/ti-dist
```

> **`--config=ti` şart.** Onsuz `target_kernel_build` tanımsız kalır ve analiz
> `'//:undefined_filegroup' does not have mandatory providers` ile patlar.
> Temiz derleme ~14 dk. Çıkan dosyalar `device/ti/am62x-kernel/kernel/6.12/`
> altına birebir kopyalanır; dist her modülü hem kökte hem `ramdisk/` altında
> tutar, ikisi aynıdır.

> **`maybe-dirty` vermagic normaldir.** Kleaf sandbox'ta `.git` olmadığı için
> sürümü damgalayamıyor; ağaçlar temizken de böyle görünür. `MODVERSIONS` açık
> olduğundan yükleme sırasında bu dize karşılaştırılmıyor.
---

## 6. Adım 3 — RTW88 (WiFi) modülleri

Kart RTL8822CS taşıyor (SDIO ID `sdio:c07v024CdC822`). **Modüller artık derleme
hattından geliyor**, elle bir şey yapmak gerekmiyor: `rtw88_core`, `rtw88_8822c`,
`rtw88_sdio` ve `rtw88_8822cs` prebuilt deposunda hazır ve `vendor_dlkm`'in yükleme
listesinde doğru sırada duruyor.

Hattın çalışması için iki kapının açılmış olması gerekti; prebuilt'i yeniden
üretecekseniz bunlar yerinde olmalı:

* `private/devices/ti/am6x/ti.fragment` → `CONFIG_WLAN_VENDOR_REALTEK=y` ve 5 RTW88
  config'i. GKI `gki_defconfig` bunu `# CONFIG_WLAN_VENDOR_REALTEK is not set`
  diyerek kapatıyor; kapı açılmadan RTW88 sembolleri hiç oluşmuyor.
* `common` ağacında GKI TI sembol listesine `sdio_align_size`, `sdio_readl`,
  `sdio_writel` (commit `d33ca763`). Bunlar olmadan `rtw88_sdio` bağlanamıyor.

Kartta beklenen bağlanma zinciri:

```
rtw88_8822cs → rtw88_sdio + rtw88_8822c → rtw88_core → mac80211 / cfg80211
```

> **Tarihçe:** Mayıs–Ağustos 2026'da bu modüller AOSP ağacının dışında elle
> derleniyordu, çünkü hatta hiç bağlı değillerdi. Elle derlenen modüller kernel
> her değiştiğinde kırılıyordu; aynı desen `sii902x`'te kernel'i düşürmeye kadar
> gitti. Ağaç dışı derleme yolu bilerek kaldırıldı — modül eksikse çözüm onu
> hatta bağlamaktır, yanına elle bir `.ko` koymak değil.

Firmware tarafı cihaz ağacında hazır: `device/ti/am62x/firmware/rtw88/` ve
`firmware/rtl_bt/` altındaki dosyalar `am67a/device.mk` üzerinden `/vendor/firmware/`
altına kopyalanıyor (`linux_firmware_rtw88-rtw8822c` Soong modülü + `PRODUCT_COPY_FILES`).
Firmware'in `/tmp` gibi bir yolda durması SELinux nedeniyle çalışmaz.
---

## 7. Adım 4 — AOSP'yi derle

```bash
cd ~/android-t3
bash --norc -c '
  source build/envsetup.sh
  lunch am67a-bp2a-userdebug
  TARGET_SDCARD_BOOT=true m -j$(nproc)
'
```

Bu satırda üç ayrı tuzak var, üçü de sert:

**`bash --norc` şart.** Normal kabuk ortamında `source build/envsetup.sh && lunch`
`release-config failed: Missing config trunk_staging` hatası veriyor. Kullanıcının
bashrc'si envsetup'ı bozuyor.

**Lunch hedefi `am67a-bp2a-userdebug`.** `am67a-t3-gem-o1-bp2a-userdebug`
`AndroidProducts.mk` içindeki `COMMON_LUNCH_CHOICES` listesinde görünüyor ama
release-config hatasıyla çalışmıyor. T3'e özgü ayarlar `TARGET_SDCARD_BOOT`
override'ı üzerinden geliyor.

**`TARGET_SDCARD_BOOT=true` unutulmamalı.** Unutulursa `vendor-bootconfig`
`fstab_suffix=am62.mmc.avb` + `boot_devices=fa10000.mmc` ile üretilir; SD karttan
boot eden bir imaj first-stage mount'ta ölür. Doğru çıktı
`fstab_suffix=am62.sdcard.avb` + `boot_devices=fa00000.mmc` olmalı.

Çıktılar `out/target/product/am67a/` altında. Tek tek hedefler de alınabilir:
`m vendorbootimage vbmetaimage vendordlkmimage superimage`.

**vbmeta uyumu:** `system`/`vendor` imajları yeniden derlendiyse `vbmeta.img` de
yeniden derlenmeli, yoksa kart dm-verity "corrupted" / "Invalid hash size" ile durur.
Ve `vbmetaimage` **aynı** `TARGET_SDCARD_BOOT` bayrağıyla derlenmelidir.

---

## 8. Adım 5 — Bootloader

Bootloader ayrı bir `repo` ağacıdır ve AOSP ile birlikte inmez:

```bash
mkdir -p ~/android-t3/bootloader && cd ~/android-t3/bootloader
repo init -u https://git.ti.com/git/android/manifest.git \
    -b android16-release -m bootloaders.xml
repo sync -j$(nproc)
```

> `repo init`'i **TI'nin manifest deposundan** yapın, fork'tan değil:
> `bootloaders.xml` içinde `<remote name="git-ti-com" fetch=".."/>` göreli bir
> adres kullanıyor; GitHub üzerinden init edilirse TI projelerini
> `github.com/mehmetakiferdem/android/...` altında aramaya kalkar ve patlar.

Bu ağaç şunları getirir: `u-boot` (ti-u-boot-2025.01), `arm-trusted-firmware`,
`optee-os` 4.7.0, `ti-linux-firmware` 11.01.17, toolchain'ler.

### T3 U-Boot'una geç

TI'nin U-Boot'unda T3 Gem O1 kart desteği yoktur:

```bash
cd ~/android-t3/bootloader/u-boot
git remote add t3 https://github.com/mehmetakiferdem/u-boot.git
git fetch t3 t3-gem-o1-android-v1
git checkout t3-gem-o1-android-v1
```

Bu dal şunları ekliyor:

- `board/t3/t3-gem-o1/` — board C dosyası, `.env`, `Kconfig`, `MAINTAINERS`,
  5 adet `*-cfg.yaml` (board/pm/rm/sec/tifs-rm)
- `configs/am67a_t3_gem_o1_r5_defconfig` — R5 SPL, DFU gadget'lı
- `configs/am67a_t3_gem_o1_a53_defconfig` — A53, Android'e özgü:
  `BOOTMETH_ANDROID`, `ANDROID_AB`, `AVB_VERIFY`, `CMD_AB_SELECT`, `CMD_ADTIMG`,
  fastboot tamponu `0xC0000000`, PMIC `TPS65219`, TypeC `TPS6598X`
- `arch/arm/mach-k3/j722s/Kconfig` — `TARGET_J722S_{A53,R5}_T3_GEM_O1` hedefleri

### Üç kritik ayar — kontrol edin

Bu üçü olmadan kart SD karttan boot etmez. Dalda mevcut olup olmadıklarını
**derlemeden önce doğrulayın** (fork'ta bir dönem commit'siz duruyorlardı):

| Dosya | Değişiklik | Neden |
|---|---|---|
| `board/t3/t3-gem-o1/t3-gem-o1.env` | `adtb_idx=6` | 4, `j722s-evm` DTB'sini seçer; o DTB'de `sdhci2` kapalı olduğu için WiFi hiç görünmez ve kart yanlış model olarak açılır |
| `board/t3/t3-gem-o1/t3-gem-o1.env` | `boot_targets=mmc1 mmc0` | mmc1 = SD. Sıra ters olursa U-Boot karta hiç bakmadan eMMC'dekini açar |
| `arch/arm/dts/k3-am67a-t3-gem-o1-u-boot.dtsi` | `main_gpio1` düğümüne `bootph-all` | `vdd_sd_dv` (tlv71033) vqmmc regülatörü `main_gpio1` pin 49'dan sürülüyor; bu olmadan GPIO denetleyicisi SPL'de gelmiyor ve SD'nin 3.3 V geçişi başarısız oluyor |

Ayrıca `board/t3/t3-gem-o1/t3-gem-o1.c` içinde `board_late_init()` başında
`hdmi_reset_pulse()` çağrılıyor: `sil,sii9022` düğümünü `ofnode_by_compatible` ile
bulup `reset-gpios`'u 10 ms basılı tutuyor, bırakıyor, 20 ms bekliyor. HDMI'ın
çalışması buna bağlı.

### Derle

```bash
cd ~/android-t3/bootloader
./build/run_build_all.sh     # shyaml PATH'te olmalı
```

Çıktılar `out/am67a-t3-gem-o1/release/` altında:
`tiboot3-release-hsfs.bin`, `tispl-release.bin`, `u-boot-release.img`,
`bl31-release.bin`, `tee-release.bin`.

Sonradan yalnızca A53 U-Boot'unu tazelemek için SDK'da hazır task var — host'ta
çalışır, konteyner içinde değil (BL31/OP-TEE ikililerine ve toolchain'e ihtiyacı var):

```bash
task android:uboot:build MACHINE=t3-gem-o1 BOOTLOADER_DIR=~/android-t3/bootloader
```

`tiboot3` (R5 SPL) bu task'a dahil değil; ayrı bir `arm-none-eabi-` toolchain
istediği için yalnızca `run_build_all.sh` üretiyor.

---

## 9. Adım 6 — Flash'lanabilir disk imajı

İki ağacın çıktısı SDK'nın `build/android/` dizininde buluşur:

```bash
SDK=/path/to/sdk
AOSP_OUT=~/android-t3/out/target/product/am67a
BL_OUT=~/android-t3/bootloader/out/am67a-t3-gem-o1/release
mkdir -p $SDK/build/android

cp $AOSP_OUT/{boot,super,vendor_boot,init_boot,dtbo,metadata,persist,userdata}.img $SDK/build/android/
cp $AOSP_OUT/vbmeta*.img          $SDK/build/android/
cp $BL_OUT/tiboot3-release-hsfs.bin $SDK/build/android/tiboot3-am67a-t3-gem-o1-hsfs.bin
cp $BL_OUT/tispl-release.bin        $SDK/build/android/tispl-am67a-t3-gem-o1.bin
cp $BL_OUT/u-boot-release.img       $SDK/build/android/u-boot-am67a-t3-gem-o1.img
```

Sonra imajı üret:

```bash
cd $SDK
devbox shell
task box                                        # distrobox konteynerine gir
task android:build MACHINE=t3-gem-o1 WORKDIR=$PWD
```

`task android:build` **AOSP derlemez.** `android/android.yaml` (debos tarifi) önce
GitHub Release'ten hazır bölüm imajlarını indirir, sonra `create-image.sh` ile
GPT'li bir disk imajı kurar. Kritik ayrıntı: indirme adımı **var olan dosyanın
üstüne yazmaz** (`✓ name (cached)` der ve geçer). Yani kendi derlediğiniz imajları
`build/android/` içine koyduysanız release'e hiç dokunmadan test edebilirsiniz.

Çıktılar:

- `android-am67a-t3-gem-o1.img` — 7.5 GB, GPT'li tam disk (SD veya eMMC)
- `android-am67a-t3-gem-o1-boot1.img` — 5 MB, eMMC `boot1` donanım bölümü

Bölüm yerleşimi (`create-image.sh`): `tiboot3.bin` raw olarak 4 MiB offset'te
(TI ROM buradan okur), ardından FAT `bootloader` bölümü (`tispl.bin` + `u-boot.img`),
sonra Android'in A/B bölümleri, `super` (4.5 GB dinamik), `metadata`, `persist`,
`userdata`.

> `vendor_dlkm` diye ayrı bir bölüm **yoktur** — `super` içinde dinamik bölümdür,
> `dd` ile yazılamaz. Çalışan kartta `adb root && adb remount` ile
> `/vendor_dlkm/lib/modules/` yazılabilir hale gelir.

---

## 10. Adım 7 — Karta yaz

**SD kart (en basit):**

```bash
lsblk                    # cihazı doğrulayın!
sudo dd if=build/android/android-am67a-t3-gem-o1.img of=/dev/sdX \
        bs=4M status=progress conv=fsync
```

**eMMC (dd ile):**

```bash
sudo dd if=android-am67a-t3-gem-o1.img of=/dev/mmcblk0 bs=4M status=progress conv=fsync
echo 0 | sudo tee /sys/block/mmcblk0boot1/force_ro
sudo dd if=android-am67a-t3-gem-o1-boot1.img of=/dev/mmcblk0boot1 bs=512 status=progress
```

**DFU + fastboot:** Kartı DFU moduna alın (BOOT tuşu basılıyken güç verin), sonra:

```bash
task android:flash MACHINE=t3-gem-o1 WORKDIR=$PWD
# veya elle: cd build/android && sudo ./flashall.sh --board am67a-t3-gem-o1
```

`flashall.sh` T3'ü `hsfs` imza tipiyle tanır; DFU tarafı
`config/dfu/am67a-t3-gem-o1-hsfs.yaml` ile eşlenir. `tispl`'nin ayrıca raw
flash'lanması gerekebilir: `fastboot flash tispl tispl-am67a-t3-gem-o1.bin`.

Yazma sırasında SD kartın bölüm önbelleği takılıyorsa raw diske `oflag=direct`
ile yazın.

---

## 11. Doğrulama

Seri konsol: 115200 8N1 (`sudo picocom -b 115200 /dev/ttyACM1`).

Beklenen boot dizisi:

```
U-Boot SPL → Trying to boot from MMC1
U-Boot → Scanning bootdev 'mmc@fa00000.bootdev' → ANDROID: slot a
→ Starting kernel → init: first stage mount → /system mount OK
→ boot animation
```

Açıldıktan sonra:

```bash
adb shell cat /proc/device-tree/model      # "T3 Gemstone O1" olmalı,
                                            # "Texas Instruments J722S EVM" ise adtb_idx yanlış
adb shell lsmod | wc -l                     # ~45 modül
adb shell ls /sys/class/drm                 # card0 → GPU (pvrsrvkm_am62p)
adb shell ip link | grep wlan               # WiFi arayüzü
adb shell dmesg | grep -E 'sii902x|drm|bridge'
```

---

## 12. Portun anatomisi — hangi değişiklik neden

Cihaz ağacındaki (`device/ti/am62x`) beş commit, portun tamamını taşıyor:

| Commit | Ne yapıyor |
|---|---|
| `3a2c8df` | `am67a-t3-gem-o1` ürün hedefi + lunch seçenekleri, T3 DTB'sini `dtb.img`'e ekler, DFU yapılandırması, `flashall.sh` desteği |
| `8910623` | RTL8822CS WiFi + BT firmware'i ve derleme kuralları |
| `c46e11a` | `TARGET_SDCARD_BOOT := true` — varsayılan boot ortamını SD yapar |
| `2024443` | Boot-cihazından bağımsız fstab varyantı (yalnızca altyapı, henüz seçilmiyor) |
| `7b23f0d` | T3 Gemstone varsayılan duvar kâğıdı (üç yoğunluk) |

`TARGET_SDCARD_BOOT` bayrağı `BoardConfig-common.mk`'de üç şeyi birden çeviriyor:

```make
ifeq ($(TARGET_SDCARD_BOOT), true)
BOARD_BOOTCONFIG += androidboot.fstab_suffix=am62.sdcard.avb
BOARD_BOOTCONFIG += androidboot.boot_devices=bus@f0000/fa00000.mmc
else
BOARD_BOOTCONFIG += androidboot.fstab_suffix=am62.mmc.avb
BOARD_BOOTCONFIG += androidboot.boot_devices=bus@f0000/fa10000.mmc
endif
```

Ayrıca `sepolicy/sdcard/` (`fa00000.mmc` etiketleri) devreye giriyor — `sepolicy/mmc/`
eMMC karşılığı.

### HDMI

SiI9022 köprüsü **güç-kapalı modda açılıyor** (`i2cget -y 5 0x3b 0x1A` → `0x10`).
HDMI pin 18'de +5 V olmadığı için monitör HPD veremiyor, DRM köprüsü hiç
etkinleşmiyor. İki taraflı çözüm:

1. U-Boot `board_late_init()` içinde köprünün `reset-gpios`'unu darbeliyor.
2. Kernel DTS'inde SiI9022 kesmesi `EDGE_FALLING` olarak tanımlı (`LEVEL_LOW` değil).

Sürücü tarafındaki kalıcı düzeltme, `sii902x_init()` içinde `drm_bridge_add()`
çağrısından **önce** TMDS'i uyandırmaktır:

```c
regmap_update_bits(sii902x->regmap, SII902X_SYS_CTRL_DATA,
                   SII902X_SYS_CTRL_PWR_DWN, 0);
```

Bu yama Eylül 2026'da kernel kaynağına girdi (`ti-linux-kernel` `c437c31e`) ve
modül artık hatta derleniyor. Kartta ölçülen sonuç: konnektör `connected`, EDID
256 bayt, HPD kesmesi tetikleniyor, SurfaceFlinger monitörü adıyla görüyor.

> **Yamayı ağaç dışı derlemeyin.** Bir dönem bu modül elle derlenip prebuilt'in
> yanına kopyalanıyordu; yüklendiğinde kernel'i düşürüyordu (muhtemelen kCFI).
> Ayrıca Android'in `CONFIG_EXTENDED_MODVERSIONS` özelliği yüzünden vermagic +
> `__version_ext_crcs` + `__version_ext_names` bölümlerini elle taşımak gerekiyor.
> Doğru yol yamayı kaynağa koyup hattan geçirmektir.

Geriye tek sorun kaldı: **açılış yarışı.** `drm_hwcomposer` `/dev/dri/card*`'ı bir
kez tarıyor ve bir daha bakmıyor; `sii902x` ikinci aşama modülü olduğu için o an
DRM cihazı henüz yok, composer "ekran yok" deyip headless moda düşüyor. Elle
toparlama:

```bash
adb shell setprop ctl.restart vendor.hwcomposer-3
adb shell setprop ctl.restart surfaceflinger
```

Kalıcı çözüm olarak `init.am62x.rc`'ye `on early-boot` + `wait /dev/dri/card1 10`
(ve `vendor_init`'e `dri_device:chr_file getattr` izni) eklendi; imaja girdi ama
**henüz kartta boot edilmedi**.

---

## 13. Açık işler

| # | Konu | Durum |
|---|---|---|
| 1 | ~~`android-am62x-kernel-t3-gem` deposu boş~~ | **Kapandı** (Eylül 2026). Depo `t3-gem-o1` dalında dolu: kleaf derlemesinden çıkan kernel, T3 DTB'si, 453 modül ve dlkm imajları |
| 1b | Kernel kaynağı hiçbir yere push'lanmadı | **Yeni blokaj, en kritiği.** `sii902x` yaması, DTS senkronu ve GKI sembol eklemeleri yalnızca derleme makinesindeki `kernel-6.12` ağacında duruyor (`ti-linux-kernel` `7e0045e0`, `common` `d33ca763`, `private/devices/ti/am6x` ise git dışı). Bu makine giderse prebuilt'i kimse yeniden üretemez |
| 1c | `android-kernel-t3-gem` içindeki DTS bayat | Mayıs 2026'dan kalma 3 dosya; Eylül derlemesi bu depodan değil TI'nin tam ağacından yapıldı, yani manifest ile gerçek artık uyuşmuyor. Depo ya güncel kaynakla değiştirilmeli ya da kaldırılıp manifest gerçek kernel ağacına bağlanmalı |
| 2 | Tek imajla SD + eMMC boot | Yarım. `fstab.in.bootdevice.avb` var ama `BoardConfig-common.mk` hâlâ `am62.sdcard.avb`/`am62.mmc.avb` seçiyor. Ayrıca dosya `/dev/block/bootdevice/by-name/` yolunu kullanıyor — **Android 16 init bu sembolik bağı artık oluşturmuyor** (`system/core/init/devices.cpp:488-545` yalnızca `/dev/block/<type>/<dev>/by-name/` ve boot cihazı için `/dev/block/by-name/` üretiyor). Doğru yol düz `/dev/block/by-name/`. Kalıcı çözüm için Android 16'nın `androidboot.boot_part_uuid` mekanizması uygun görünüyor (`devices.cpp:665-700`), ama U-Boot'un PARTUUID'yi bootargs'a eklemesi gerekiyor |
| 3 | HDMI açılışta gelmiyor | Sürücü yaması ağaca girdi ve HDMI kartta çalışıyor; kalan sorun `hwcomposer`'ın erken başlaması. `wait /dev/dri/card1` düzeltmesi yazıldı, **kartta doğrulanmadı** (12. bölüm) |
| 3b | Sensörler | LPS22DF ve HDC2010 IIO'ya bağlanmadı (config eksik), ICM-20948'in bu kernel'de sürücüsü yok. Android'de `android.hardware.sensors` HAL'i hiç yok → uygulamalar hiçbir sensörü göremiyor |
| 3c | `remoteproc2/3: bad phdr` | DSP/R5F firmware'i yüklenmiyor; ayrı iş |
| 4 | Dokümantasyon `t3gemstone/docs`'a taşınmadı | Android sayfası (tr + en) yazıldı, fork'ta `android-docs` dalında duruyor; org'a PR açılmadı. Sayfa `t3gemstone/sdk -b android-build` diyor, o dal da henüz yalnızca fork'ta |
| 5 | Depolar kişisel hesapta | `t3gemstone` organizasyonuna taşınırken manifest'teki `t3gemstone` remote adresi de düzeltilmeli |

---

## 14. Sorun giderme

| Belirti | Sebep | Çözüm |
|---|---|---|
| `No rule to make target '...k3-am67a-t3-gem-o1.dtb'` | Prebuilt kernel deposu boş | Adım 2 |
| `release-config failed: Missing config trunk_staging` | Kullanıcı bashrc'si envsetup'ı bozuyor | `bash --norc` ile çalıştırın |
| `lunch am67a-t3-gem-o1-bp2a-userdebug` hata veriyor | Ürün release-config'i eksik | `am67a-bp2a-userdebug` + `TARGET_SDCARD_BOOT=true` |
| Derleme sırasında süreç "Terminated" | earlyoom RAM'i kurtarıyor | Bölüm 3'teki cgroup reçetesi |
| `/proc/device-tree/model` → "J722S EVM" | `adtb_idx=4` | U-Boot env'inde `adtb_idx=6` |
| SD kart hiç okunmuyor, eMMC açılıyor | `boot_targets` sırası | `boot_targets=mmc1 mmc0` |
| SPL'de SD 3.3 V geçişi başarısız | `main_gpio1` SPL'de yok | `k3-am67a-t3-gem-o1-u-boot.dtsi`'ye `bootph-all` |
| dm-verity "corrupted" / "Invalid hash size" | `vbmeta.img` diğer imajlarla uyumsuz | `TARGET_SDCARD_BOOT=true m vbmetaimage` |
| first-stage mount başarısız | `fstab_suffix`/`boot_devices` yanlış ortamı gösteriyor | `TARGET_SDCARD_BOOT` bayrağını kontrol edin |
| WiFi arayüzü yok, `/sys/bus/sdio/devices/` boş | Yanlış DTB (sdhci2 kapalı) | `adtb_idx=6` |
| Modül `insmod`'da vermagic hatası | Ağaç dışı derleme kernel sürümüyle uyuşmuyor | Vermagic'i `6.12.23-android16-5-ge9a61e5d3676-4k` ile eşleyin |
| HDMI karanlık | SiI9022 güç-kapalı modda | `i2cset -y 5 0x3b 0x1A 0x00` (geçici) |
