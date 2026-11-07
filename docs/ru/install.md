# Установка

Всё делалось на самом планшете (Arch ARM ставится в раздел `userdata`), загрузчик — штатный ABL.
`boot_b` содержит наш boot-образ, Android не нужен.

## 1. Разметка

| Раздел | Устройство | Что там |
|---|---|---|
| `userdata` | `/dev/sda15` (label `archroot`) | корень Arch Linux ARM, ext4 |
| `boot_b` | `/dev/disk/by-partlabel/boot_b` | наш boot-образ (v2) |
| `persist` | `/dev/sda2` | сенсоры/калибровки — **не трогать** |
| `dsp_b` | `/dev/sde29` | прошивка ADSP — **не трогать** |

Резервные копии `boot_b` перед экспериментами обязательны: `fastboot` — единственный способ
восстановиться, если образ не загрузится.

## 2. Корневая система

```bash
# на планшете, из recovery/fastboot-boot окружения или с другого хоста
mkfs.ext4 -L archroot /dev/sda15
mount /dev/sda15 /mnt
tar -xpf ArchLinuxARM-aarch64-latest.tar.gz -C /mnt
```

Дальше — обычная настройка Arch (ключи pacman, `NetworkManager`, `openssh`, пользователь, `sudo`),
плюс пакеты, без которых не работают узлы:

```bash
pacman -S --needed base-devel openssh networkmanager sudo nano vim htop \
  mesa plasma-meta sddm bluez bluez-utils upower zram-generator \
  libcamera libcamera-tools plasma-camera epiphany \
  gst-plugins-base gst-plugins-good gst-plugins-bad gst-libav
# AUR: qrtr rmtfs tqftpserv pd-mapper hexagonrpcd
```

`qrtr`, `rmtfs`, `tqftpserv`, `pd-mapper` обязательны: без них не поднимаются Wi-Fi, тачскрин и часть
ADSP-периферии.

## 3. Ядро

```bash
git clone --depth 1 --branch v7.2.3-r0 https://codeberg.org/sm61x5-mainline/linux.git
cd linux
for p in /path/to/repo/kernel/patches/*.patch; do git apply "$p"; done
cp /path/to/config-nura-qcom-sm61x5.aarch64 .config
make ARCH=arm64 LLVM=1 olddefconfig
make ARCH=arm64 LLVM=1 KERNELRELEASE=7.2.3-sm61x5-hermes -j$(nproc) Image.gz modules dtbs
make ARCH=arm64 LLVM=1 KERNELRELEASE=7.2.3-sm61x5-hermes modules_install
depmod -a 7.2.3-sm61x5-hermes
```

`KERNELRELEASE` нужен, чтобы каталог модулей совпадал с `uname -r` (localversion в `.config` при этом
перекрывается).

## 4. initramfs и boot-образ

Минимальный initramfs — статический busybox, который монтирует корень и делает `switch_root`
(`boot/mininit-init`):

```
mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev
mount /dev/sda15 /newroot
exec switch_root /newroot /sbin/init
```

Образ собирается `boot/mkboot.py` (Android boot image v2):

```bash
python3 boot/mkboot.py --ref stock.img \
  --kernel arch/arm64/boot/Image.gz \
  --ramdisk mininit.img \
  --dtb arch/arm64/boot/dts/qcom/sm6115p-lenovo-j606f-hx83102p.dtb \
  --cmdline "console=tty0 fbcon=rotate:2 clk_ignore_unused pd_ignore_unused root=/dev/sda15 rw loglevel=7" \
  --out boot-arch.img
```

Прошивка (с ноутбука, планшет в fastboot — Power ~15 с, затем Громкость− + Power):

```bash
fastboot flash boot_b boot-arch.img
fastboot reboot
```

## 5. После первого запуска

```bash
# сервисы из rootfs/
install -m644 rootfs/etc/systemd/system/j606f-*.service /etc/systemd/system/
install -m755 rootfs/usr/local/bin/j606f-* /usr/local/bin/
install -Dm644 rootfs/etc/wireplumber/wireplumber.conf.d/51-j606f-nommap.conf \
  /etc/wireplumber/wireplumber.conf.d/51-j606f-nommap.conf
install -Dm644 rootfs/etc/systemd/zram-generator.conf /etc/systemd/zram-generator.conf
install -Dm644 rootfs/etc/sysctl.d/99-zram.conf /etc/sysctl.d/99-zram.conf
install -Dm644 rootfs/etc/modules-load.d/j606f.conf /etc/modules-load.d/j606f.conf
install -Dm644 rootfs/ucm/Lenovo-TB-J606F.conf /usr/share/alsa/ucm2/conf.d/sm4250/Lenovo-TB-J606F.conf
install -Dm644 rootfs/ucm/HiFi.conf /usr/share/alsa/ucm2/Lenovo/TB-J606F/HiFi.conf

systemctl enable j606f-touch j606f-lid j606f-hid-resume upower bluetooth sddm
systemctl set-default graphical.target
```

## Если планшет не загрузился

Симптомы — чёрный экран, «буковки», бесконечная перезагрузка. Действия:

1. Выключить (Power ~15 с), зайти в fastboot (Громкость− + Power).
2. Прошить последний рабочий образ: `fastboot flash boot_b good.img && fastboot reboot`.
3. Не пытаться «переждать» цикл перезагрузок — только возврат образа.

Проверенный порядок отладки: сначала загрузиться с рабочим DTB, потом менять один узел за раз и
сравнивать `dtc -I dtb -O dts` старого и нового дерева (см. `tools/patch_dts.py`).
