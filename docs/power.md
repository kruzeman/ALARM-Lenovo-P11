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

### What breaks suspend (and how it is fixed)

Three devices abort or instantly break s2idle on this machine, so
`rootfs/usr/lib/systemd/system-sleep/50-j606f-resume` detaches them before sleep and
restores them on resume:

| Device | Symptom | Fix in the hook |
| --- | --- | --- |
| pogo dock HID `i2c_hid_of` (`0-0060`, `1-0061`) | `i2c_hid_core_pm_resume ... returns -6`, suspend rolls back after 1 s | unbind / bind |
| USB3 controller `4ef8800.usb` | `dwc3-qcom-legacy ...: port-1 HS-PHY not in L2`, suspend aborts | unbind / bind (charging is on PMIC/tcpm, unaffected) |
| Bluetooth UART `4a8c000.serial` | `pm_wakeup_irq = 114`, wakes ~1 s after entering sleep | `power/wakeup` disabled / enabled |

## Cover (Hall sensor)

The sensor is `gpiochip0`, line **36**, active low. It is exposed as a proper input switch in the
DT (`sm6115p-lenovo-j606f.dts`):

```
key-lid {
    gpios = <&tlmm 36 GPIO_ACTIVE_LOW>;
    linux,input-type = <EV_SW>;
    linux,code = <SW_LID>;
    debounce-interval = <15>;
    wakeup-source;
};
```

`gpio-keys` turns it into `SW_LID` on `/dev/input/event2` and marks the device as a wakeup
source (`/sys/devices/platform/gpio-keys/power/wakeup` → `enabled`), so opening the cover
wakes the tablet.

`logind` must **not** handle the lid itself: `gpio-keys` wakes on *any* edge, so an immediate
suspend on close is woken by the same close event and you get a suspend/wake loop.
`/etc/systemd/logind.conf.d/10-j606f-lid.conf` therefore sets `HandleLidSwitch=ignore`, and
`j606f-lid.service` runs `j606f-lid-daemon.py`, which waits 3 s after the cover is closed
(the line is stable by then, only opening raises an edge) and then suspends:

```bash
journalctl -u j606f-lid -f       # SW_LID -> 1 / cover closed -> suspend / SW_LID -> 0
```

KDE's PowerDevil also acts on the lid by default — `lidAction=0` (No action) must be set for
`AC`, `Battery` and `LowBattery` in `~/.config/powermanagementprofilesrc`, otherwise it issues
its own suspends on top of the daemon's.

## Battery

`mm8013` (I²C) does not auto-load, so it is listed in `/etc/modules-load.d/j606f.conf`:

```
mm8013
```

The GENI I²C controller behind the fuel gauge occasionally times out
(`geni_i2c 4a80000.i2c: geni_i2c_gpi_xfer:I2C timeout`) and a single failed register read made
the power-supply core report `driver failed to report 'present' property: -110` — KDE then
showed "battery missing / 0 %" for a couple of seconds. `kernel/patches/mm8013-i2c-retry.patch`
retries every register read four times (2–4 ms apart) before giving up:

```bash
cd /usr/src/linux && patch -p1 < .../kernel/patches/mm8013-i2c-retry.patch
make ARCH=arm64 LLVM=1 M=drivers/power/supply modules
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
