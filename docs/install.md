# Installation

Everything was done on the tablet itself (Arch ARM is installed into the `userdata` partition); the boot
loader is the stock ABL. `boot_b` holds our boot image, Android is not required.

## 1. Partitions

| Partition | Device | Contents |
|---|---|---|
| `userdata` | `/dev/sda15` (label `archroot`) | Arch Linux ARM root, ext4 |
| `boot_b` | `/dev/disk/by-partlabel/boot_b` | our boot image (Android v2) |
| `persist` | `/dev/sda2` | sensors/calibration — **do not touch** |
| `dsp_b` | `/dev/sde29` | ADSP firmware — **do not touch** |

Always keep a backup of `boot_b` before experimenting: fastboot is the only way back if an image does not
boot.

## 2. Root filesystem

```bash
# on the tablet, from a recovery/fastboot-booted environment or another host
mkfs.ext4 -L archroot /dev/sda15
mount /dev/sda15 /mnt
tar -xpf ArchLinuxARM-aarch64-latest.tar.gz -C /mnt
```

Then a normal Arch setup (pacman keys, `NetworkManager`, `openssh`, a user, `sudo`), plus the packages the
hardware needs:

```bash
pacman -S --needed base-devel openssh networkmanager sudo nano vim htop \
  mesa plasma-meta sddm bluez bluez-utils upower zram-generator \
  libcamera libcamera-tools plasma-camera epiphany \
  gst-plugins-base gst-plugins-good gst-plugins-bad gst-libav
# AUR: qrtr rmtfs tqftpserv pd-mapper hexagonrpcd
```

`qrtr`, `rmtfs`, `tqftpserv` and `pd-mapper` are mandatory: without them Wi-Fi, the touchscreen and part of
the ADSP peripherals never come up.

## 3. Kernel

```bash
git clone --depth 1 --branch v7.2.3-r0 https://codeberg.org/sm61x5-mainline/linux.git
cd linux
for p in /path/to/repo/kernel/patches/*.patch; do git apply "$p"; done
cp /path/to/repo/kernel/config-nura-qcom-sm61x5.aarch64 .config
make ARCH=arm64 LLVM=1 olddefconfig
make ARCH=arm64 LLVM=1 KERNELRELEASE=7.2.3-sm61x5-hermes -j$(nproc) Image.gz modules dtbs
make ARCH=arm64 LLVM=1 KERNELRELEASE=7.2.3-sm61x5-hermes modules_install
depmod -a 7.2.3-sm61x5-hermes
```

`KERNELRELEASE` makes the module directory match `uname -r` (it overrides the localversion in `.config`).

## 4. initramfs and boot image

The initramfs is a static busybox that mounts the root and does `switch_root` (`boot/mininit-init`):

```
mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev
mount /dev/sda15 /newroot
exec switch_root /newroot /sbin/init
```

The image is built by `boot/mkboot.py` (Android boot image v2), or simply:

```bash
./boot/build-boot.sh arch/arm64/boot/Image.gz \
  arch/arm64/boot/dts/qcom/sm6115p-lenovo-j606f-hx83102p.dtb
```

Flashing (from a laptop, tablet in fastboot — hold Power ~15 s, then Volume Down + Power):

```bash
fastboot flash boot_b boot-arch.img
fastboot reboot
```

## 5. After the first boot

```bash
cd /path/to/repo && ./rootfs/install.sh
```

That installs the services and configuration files and enables `j606f-touch`, `j606f-lid`,
`j606f-hid-resume`, `upower`, `bluetooth` and `sddm`.

## If it does not boot

Symptoms: black screen, garbled text, reboot loop. What to do:

1. Power off (hold Power ~15 s), enter fastboot (Volume Down + Power).
2. Flash the last known-good image: `fastboot flash boot_b good.img && fastboot reboot`.
3. Never "wait out" a reboot loop — restore the image.

A proven debugging order: boot with a working DT first, then change one node at a time and compare
`dtc -I dtb -O dts` output of the old and new tree (see `tools/patch_dts.py`).
