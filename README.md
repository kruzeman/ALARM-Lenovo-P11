# Arch Linux ARM on the Lenovo Tab P11 (TB-J606F)

A custom setup that runs **Arch Linux ARM** on the **Lenovo Tab P11 TB-J606F**
(Qualcomm Snapdragon 662 / SM6115 "bengal", 4 GB RAM, 1200×2000 panel, pogo keyboard dock).

Built on top of the mainline port [sm61x5-mainline/linux](https://codeberg.org/sm61x5-mainline/linux)
(tag `v7.2.3-r0`) and [Yar1klamer/j606f-postmarketos](https://github.com/Yar1klamer/j606f-postmarketos).
This repository holds everything done on top: own kernel patches, an ES7210 codec driver, device-tree
fixes, a libcamera patch for the cameras, a minimal initramfs and the Arch-side configuration.

*Русская версия: [README.ru.md](README.ru.md), документация: [docs/ru/](docs/ru/).*

## Status

| Device | State | Notes |
|---|---|---|
| Boot (A/B, `boot_b`) | ✅ | custom kernel `7.2.3-sm61x5-hermes`, minimal initramfs |
| Display (Himax HX83102P, DSI) | ✅ | brightness via `/sys/class/backlight`, panel mounted upside down (`rotation = 180`) |
| Touchscreen (Himax HX83102E) | ✅ | needs `rmtfs`, `tqftpserv`, `pd-mapper`; `j606f-touch` service |
| Pogo dock: keyboard + touchpad | ✅ | `hid-over-i2c`, IRQs on GPIO 93/96; `j606f-hid-resume` re-binds them after suspend |
| Wi-Fi (WCN3990 / ath10k_snoc) | ✅ | needs `qrtr`, `rmtfs`, `tqftpserv`, `pd-mapper` |
| Bluetooth (QCA) | ✅ | stable BD address comes from the device tree (`local-bd-address`) |
| Speakers (4× AW88258) | ✅ | PRIMARY_TDM_RX_0, stereo, UCM profile |
| USB-C / headset | ⚠️ | WCD937x + SoundWire come up, but the analogue path goes through an FSA4480 switch — not implemented |
| Cameras (OV13B10 + S5K4H7) | ⚠️ | both capture; front orientation fixed in DT, rear has no autofocus |
| Built-in microphones (ES7210) | ❌ | codec driver is ready, the DSP rejects the TDM-TX port (`-22`), see `docs/audio.md` |
| Suspend (`s2idle`) | ✅ | wake with Power; lid-close suspend via `j606f-lid` (Hall sensor, gpiochip0 line 36) |
| Auto-rotate | ✅ | `j606f-autorotate` daemon on top of `ssccli` (SSC/ADSP) |
| Login screen | ✅ | SDDM greeter on Xorg (rotate via `xrandr`), Plasma session on Wayland |
| Ambient light | ✅ | LTR578 through SSC, `iio-sensor-proxy` reports `HasAmbientLight` |
| Battery | ✅ | `mm8013` + `upower` |
| zram | ✅ | `zram-generator`, zstd, `ram / 2` |

## Prebuilt image

[Releases](../../releases) contain a tested boot image (`boot-arch-j606f-good.img`): sound (speakers),
Wi-Fi, Bluetooth, touch, pogo dock, cameras, suspend and auto-rotate work; the ES7210 microphones are
disabled. Flash it with:

```bash
fastboot flash boot_b boot-arch-j606f-good.img
```

## Layout

```
kernel/patches/     patches against sm61x5-mainline/linux (v7.2.3-r0)
  0001-…            DT: audio (ES7210 + TDM TX) and Bluetooth BD address
  0002-…            sm8250.c: capture link on PRIMARY_TDM_TX_0
  0003-…            ES7210 codec driver (sound/soc/codecs/es7210.c)
  0004-…            DT: front camera rotation
boot/               boot image builder (mkboot.py) and the minimal initramfs
rootfs/             system files: systemd services, UCM, WirePlumber/zram configs,
                    scripts (auto-rotate, HID re-bind, microphone test)
libcamera/          libcamera 0.7.2 patch: sensor helpers for OV13B10 and S5K4H7
tools/              device-tree helpers: patch_dts.py, fdtread.py
docs/               per-device notes (English; Russian under docs/ru/)
```

## Quick start

1. Read `docs/install.md` — partitioning, image build and first boot.
2. Build the kernel and DTBs:

   ```bash
   git clone --depth 1 --branch v7.2.3-r0 https://codeberg.org/sm61x5-mainline/linux.git
   cd linux
   for p in /path/to/repo/kernel/patches/*.patch; do git apply "$p"; done
   cp /path/to/repo/kernel/config-nura-qcom-sm61x5.aarch64 .config
   make ARCH=arm64 LLVM=1 olddefconfig
   make ARCH=arm64 LLVM=1 KERNELRELEASE=7.2.3-sm61x5-hermes -j$(nproc) Image.gz modules dtbs
   ```

3. Build the boot image with `boot/build-boot.sh`.
4. Copy `rootfs/*` into the system and enable the services (`docs/install.md`).

## Known issues

- **Microphones**: the DSP answers `AFE enable for port 0x9001 failed -22` for every port configuration
  tried (2/4 channels, slot masks `0x3`/`0xF`, with and without a channel map). Next step is to compare
  against the ADSP firmware's AFE port table and to check whether the mics actually sit on the second
  LPASS bus (`lpi_i2s2_*` exists in the stock DT next to the `lpass-tdm1-*` pins used by the speakers).
- **Rear camera**: no autofocus (libcamera's simple pipeline has no AF for this sensor). The `dw9719` VCM
  can be driven by hand through `/dev/v4l-subdev*` (`focus_absolute`), but it is only powered while
  streaming.
- **USB-C analogue audio**: needs an FSA4480 driver.
- **`power_supply` oops**: this kernel occasionally raises `Internal error: Oops - CFI` in
  `power_supply_changed_work` (battery/charger). Unrelated to audio or cameras, but it can wedge the
  system; a reboot clears it.

## Credits

- [sm61x5-mainline](https://codeberg.org/sm61x5-mainline/linux) — mainline port for SM6115/SM4250.
- [Yar1klamer/j606f-postmarketos](https://github.com/Yar1klamer/j606f-postmarketos) — the original port for
  this tablet (DTB, amplifier drivers, hardware notes).
- The libcamera team — for a readable simple pipeline and sensor-helper framework.
