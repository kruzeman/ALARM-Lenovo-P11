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
  mesa plasma-meta plasma-login-manager bluez bluez-utils upower zram-generator \
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
`j606f-hid-resume`, `j606f-sensor-proxy`, `upower`, `bluetooth` and `plasmalogin`.

## Optional: desktop tuning

`rootfs/usr/local/bin/j606f-kde-tune.sh` (run as the desktop user) disables the heavy KWin effects and
the Baloo indexer; see `docs/performance.md` for measurements.

## If it does not boot

Symptoms: black screen, garbled text, reboot loop. What to do:

1. Power off (hold Power ~15 s), enter fastboot (Volume Down + Power).
2. Flash the last known-good image: `fastboot flash boot_b good.img && fastboot reboot`.
3. Never "wait out" a reboot loop — restore the image.

A proven debugging order: boot with a working DT first, then change one node at a time and compare
`dtc -I dtb -O dts` output of the old and new tree (see `tools/patch_dts.py`).

## Login screen (Plasma Login Manager, autologin)

`plasma-login-manager` (service `plasmalogin`) replaces SDDM. SDDM is gone because its Wayland greeter was
unstable here: `kwin_wayland` started as the `sddm` user logged
`kwin_core: Failed to take control of ... session. Maybe another compositor is running?`, crashed with `SEGV`,
and left stale sessions holding the DRM master, so the next login hung after the password
(`startplasma-wayland` started, `plasmashell` never appeared). The workaround was an Xorg greeter with
`xrandr` rotation; with plasmalogin there is no greeter to fight — the device autologins straight into the
Wayland session and the rotation comes from the saved output configuration.

`rootfs/etc/plasmalogin.conf.d/10-autologin.conf`:

```ini
[Autologin]
User=user
Session=plasma.desktop
Relogin=false
```

Then:

```bash
systemctl disable sddm
systemctl enable plasmalogin      # moves the display-manager.service symlink
```

Verified after a reboot: `plasmalogin` active, `sddm` inactive, the user session on tty1, `kwin_wayland`
running with rotation and auto-brightness intact, Wi-Fi associated. The old SDDM pieces
(`rootfs/etc/sddm.conf.d/20-x11.conf` and `rootfs/usr/local/bin/sddm-x11-rotate.sh`) are kept only as the way
back: `xorg-xrandr` is the package they need.

## Pogo dock: keyboard and touchpad

The Lenovo Keyboard Pack exposes two independent HID-over-I2C clients: the keyboard at `i2c1` 0x61
(`17EF:6103`) and the Elan touchpad at `i2c0` 0x60 (`04F3:3164`, handled by `hid-multitouch`). The
keyboard comes up with `post-power-on-delay-ms = <100>`, but the touchpad needs longer: with 100 ms the
kernel reads a corrupt report descriptor (`unknown main item tag 0x0`, `collection stack underflow`,
`item 0 0 0 12 parsing failed`, `probe with driver hid-multitouch failed with error -22`), no input device
appears, and the MCU then idles so a later unbind/bind answers `GPI transfer failed: -5`. 400 ms in the
`touchpad@60` node is enough and the touchpad works. If the touchpad ever goes silent, reseat the dock and
reboot — the descriptor is read once, at probe.

## Wi-Fi watchdog

`ath10k_snoc` (WCN3990) can lose `wlan0` not only at boot but during a session: the interface disappears
entirely and does not come back by itself. `j606f-wifi-reprobe` only covers boot, so
`j606f-wifi-watchdog.timer` runs `j606f-wifi-watchdog.sh` every minute: if a wireless interface exists it
just brings a `down` link up, and if there is none it stops NetworkManager, re-probes the driver
(three reload attempts), and starts NetworkManager again.
