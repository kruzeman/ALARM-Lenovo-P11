# Power, suspend, memory

## Suspend

Only **s2idle** is available:

```bash
cat /sys/power/mem_sleep        # [s2idle]
systemctl suspend               # wake with the Power button
dmesg | tail                    # PM: suspend entry / exit
```

Wi-Fi, audio and the touchscreen survive; the pogo HID is re-bound by `j606f-hid-resume`
(`rootfs/usr/local/bin/j606f-hid-rebind.sh`).

## Cover (Hall sensor)

The sensor is `gpiochip0`, line **36**, active low. `j606f-lid.service` runs `gpiomon` and suspends the
tablet when the cover is closed:

```
j606f-lid.service: ExecStart=/usr/bin/gpiomon -c gpiochip0 -e both 36
```

Wake-on-cover-open does not work yet (the GPIO node in the DT would need `wakeup-source`); the tablet wakes
with the Power button only.

## Battery

`mm8013` (I²C) does not auto-load, so it is listed in `/etc/modules-load.d/j606f.conf`:

```
mm8013
```

`upower` provides the KDE indicator:

```bash
upower -i /org/freedesktop/UPower/devices/battery_mm8013 | grep -E "percentage|capacity"
```

## Memory (zram)

4 GB is tight for KDE, so zram with zstd is enabled:

`/etc/systemd/zram-generator.conf`

```ini
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
```

`/etc/sysctl.d/99-zram.conf`

```ini
vm.swappiness = 180
vm.page-cluster = 0
```

Check with `zramctl` (`/dev/zram0` ~1.8 GiB) and `swapon --show`.

## Performance notes

- Compiling on all 8 cores (`ninja -j8`) starves KWin: the screen goes black and touch events lag
  (`client bug: event processing lagging behind`). Build with `nice -n 19 ionice -c3` and `-j4`.
- This kernel occasionally raises `Internal error: Oops - CFI` in `power_supply_changed_work`
  (battery/charger, `qcom_pmi632_charger`/`mm8013`). The system usually survives but can wedge; a reboot
  clears it. It is unrelated to audio or cameras.
