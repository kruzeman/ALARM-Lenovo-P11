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

### Desktop boots without battery and brightness

`upowerd` enumerates `/sys/class/power_supply` on start, and the fuel gauge lives on the same
flaky GENI-I²C bus. Early in the boot that read blocks past the default 90 s
`TimeoutStartSec`, systemd kills the unit — and `plasmashell` and `powerdevil` die with it,
so KDE shows no battery and no working brightness slider until both come back by themselves
(a couple of minutes). `rootfs/etc/systemd/system/upower.service.d/10-j606f-timeout.conf`
raises the timeout to 300 s and restarts the unit on failure.

Brightness itself is restored by `systemd-backlight@backlight:5e94000.dsi.0` from
`/var/lib/systemd/backlight/`; if the saved value is a dim one from a previous session the
panel comes up almost black — write a sane value once (`echo 1400 > /sys/class/backlight/*/brightness`)
and it is what gets saved.

### The real culprit: stale touch input devices

`upowerd` dies with a kernel fault in `input_dev_uevent → vsnprintf → string`, and
`plasmashell`/`powerdevil` fall with it. The cause is the vendor touch driver: its remove path
called `input_free_device()` on **already registered** devices, so every
`modprobe -r himax_hx83102e` (which `j606f-touch.service` does on each boot) left a freed
input device in `/sys/class/input` with its name pointing at freed memory. Reading that
device's `uevent` — exactly what udev and upower do — dereferences the dangling pointer.

`kernel/patches/himax-input-unregister.patch` tracks registration and calls
`input_unregister_device()` for registered devices (and `input_free_device()` only for
unregistered ones). After it, one boot has a single `himax-touchscreen`/`himax-pen` pair and
upower, battery and the brightness slider come up normally.

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

## USB PD / fast charging: what the experiment showed

Enabling PD in the DT (`pd-disable` removed, `sink-pdos` 5 V/3 A + 9 V/2 A, `op-sink-microwatt`
18 W, plus `source-pdos` 5 V/1.5 A because the port is `power-role = "dual"` and tcpm requires it)
does negotiate: `tcpm-source-psy` reports `voltage_now = 9000000`, `current_now = 2000000` with a 65 W
PD charger. **But the tablet does not charge in that state**: `pmi632-charger` shows
`input_current_limit = 0` and `status = Not charging`, the battery keeps discharging, and the desktop
says "discharging" even though the cable is in.

The reason is the charger driver, not the DT: `drivers/power/supply/qcom_pmi632_charger.c` is
read-only (no `set_property`, no register writes), so nothing configures the SMB5 HVDCP path when VBUS
goes to 9 V and the input stays closed. Fast charging therefore needs the driver work (ICL/FCC/HVDCP
register programming from the CAF SMB5 map) *before* PD is enabled in the DT — enabling PD alone only
breaks charging.

Rolled back to the image without PD; charging returns to `DCP`, `ICL = 1.5 A` at 5 V (≈7.5 W input).

### Charging: the driver can now set the input limit (2026-11-10)

Up to now `qcom_pmi632_charger` was read-only, which is why enabling PD left `ICL = 0` and nothing charged. It now has
`set_property` + `property_is_writeable` for `INPUT_CURRENT_LIMIT` (register `USBIN_ICL_CFG 0x370`) and
`CONSTANT_CHARGE_CURRENT` (`CHGR_FCC_CFG 0x061`), 50 mA per step, plus automatic configuration in the poll work:
on plug-in it reads the APSD result and opens the input to 3 A for DCP/CDP, 500 mA for SDP.

Measured on the IdeaPad 3 65 W USB-C adapter, battery at 80 %:

| state | effective ICL (`0x107`) | current into the battery |
|---|---|---|
| before (read-only driver) | 950 mA | +0.69 A with a game running |
| after, game running | 2.5 A | +0.69 A |
| after, load stopped | 2.35 A | +1.2…1.3 A |

`dmesg` shows the write landing: `set 0x370: want 3000000 uA -> step 60, readback 60, effective 53` — the config
register takes 3 A, AICL then settles around 2.35–2.65 A. So at 5 V the port now pulls ~12 W instead of ~5 W.

### 9 V (PD) — prepared, not yet tested

`boot-pd.img` (DTB 92 364 bytes, sha256 starts `743e75b3`) enables PD in the connector: `pd-disable` removed,
`sink-pdos` 5 V/3 A + 9 V/2 A, `op-sink-microwatt` 18 W, `source-pdos` 5 V/1.5 A (required because `power-role` is
`dual`, otherwise tcpm returns `-EINVAL`). Not flashed yet; the module with the ICL setters is already installed on the
tablet, so the open question is whether a 9 V contract now charges at all — previously the port closed the input
because nobody could program `ICL`. Rollback: `boot-txmac2.img` (release v0.2).

### 9 V (PD) tested on 2026-11-10: the charger latches USBIN over-voltage

With `boot-pd.img` flashed and the IdeaPad 65 W adapter connected, PD negotiates fine — `tcpm-source-psy` reads
`voltage_now = 9000000`, `current_now = 2000000` — but the tablet does not charge: `status = Not charging`,
`input_current_limit` (effective, `0x107`) = 0, battery discharging at ~-0.9 A while the cable is in.

Registers at that moment (our driver's debug print):

```
set 0x370: want 2000000 uA -> step 40, readback 40, effective 0, path 0x13, icl_max 40
usbin_rt=0x18 chgr1=0x46 chgr7=0x0
```

- The config registers accept our values (`0x370 = 40`, `0x106 = 40`) — so `ICL` programming works.
- `usbin_rt = 0x18` has `BIT(3)` set, which in SMB5/PMI632 is **`USBIN_OV_RT_STS`**: the charger sees 9 V as
  over-voltage and shuts the input path down. `chgr1 = 0x46` (status 6 = `CHG_PAUSE`) confirms it.
- Writing `USBIN_ADAPTER_ALLOW_CFG` (`USBIN_BASE + 0x60`, i.e. `0x1360`) — the register CAF uses to permit
  `5V_OR_9V_TO_12V` — does not help: with `0x07` it reads back `0x7` and with `0x0c` it reads back `0x4`, and the OV
  bit stays set, also after unplug/replug.

Why: upstream splits the Type-C/PD stack (`tcpm` + `fusb302`) from the charger driver, so the charger never learns
that PD raised VBUS to 9 V. In CAF's `smb5-lib` the two are coupled — the PD state machine tells the charger which
voltage to expect and the OV/allow configuration is done before the voltage rises. Doing that here means wiring a
`usb_pd` notifier into `qcom_pmi632_charger`, which is a separate piece of work.

Rolled back to the 5 V image (`boot-txmac2.img`): with the new ICL/FCC setters the port pulls ~2.4 A at 5 V, which is
already ~12 W instead of the previous ~5 W.

### Conclusion on 9 V: PMI632 cannot take it from a PD source

Register dump at 9 V (our driver's `reg` debug attribute, offsets relative to `0x1000`):

```
0x308 = 0x8    APSD_DCP, adapter recognised as DCP
0x370 = 0x3c   3 A configured by us
0x106 = 0x3c   3 A accepted as the maximum
0x107 = 0x0    effective input current 0
0x310 = 0x18   USBIN_PLUGIN + USBIN_OV (BIT(3))
0x360 = 0x3    read back after writing 0x07 — the allowance field is masked
0x10b = 0x13   power path sees a valid input
```

Two independent facts settle it:

1. `USBIN_OV` is set and `USBIN_ADAPTER_ALLOW` cannot raise the threshold — the field reads back as `0x3` whatever we write
   (`0x07`, `0x0c`), so the over-voltage comparator is fixed in hardware at a 5 V-style level.
2. Qualcomm's own driver skips the whole PD allowance path for this PMIC:
   `smblib_set_usb_pd_allowed_voltage()` starts with `if (chg->chg_param.smb_version == PMI632_SUBTYPE) return 0;`.

So 5 V is the ceiling for this tablet. Charging power with the new `ICL`/`FCC` controls is ~2.4 A at 5 V (~12 W) instead
of the previous ~5 W; there is no path to 9 V/18 W without different charging hardware. `pd-disable` is back in the DT
and the tablet runs the 5 V image.

### Correction: the tablet supports Quick Charge 3.0, not USB-PD

Lenovo's spec for the TB-J606F says: *"Integrated Li-Polymer 7500 mAh (minimum) / 7700 mAh (typical) battery, supports
Quick Charge 3.0 (charge up to 80 % in 2 hr)"*. That fits the register evidence exactly: PMI632 does speak **HVDCP**
(QC2/QC3) — `CMD_HVDCP_2_REG` with `FORCE_9V` / `FORCE_12V`, and `USBIN_ADAPTER_ALLOW` = `5V_OR_9V_TO_12V` — but that
path requires a *Qualcomm QC adapter* that raises VBUS only after the charger asks for it over D+/D-. Qualcomm's own
driver therefore skips the PD allowance path for this PMIC (`smblib_set_usb_pd_allowed_voltage()` returns 0 for
`PMI632_SUBTYPE`).

Consequence: a **PD-only** adapter (like the IdeaPad 65 W one) raises VBUS to 9 V on its own, the charger sees 9 V
without having enabled HVDCP and trips `USBIN_OV` — that is what we measured. With a **QC3.0 charger** the same 9 V
should be accepted, because the handshake goes through the charger's own state machine.

So 9 V is not closed for good — it needs (a) a QC3.0 adapter to test with, and (b) HVDCP support in
`qcom_pmi632_charger`: set `USBIN_ADAPTER_ALLOW` to `5V_OR_9V_TO_12V`, enable `HVDCP_EN` in `USBIN_OPTIONS_1`, and
request the higher voltage through `CMD_HVDCP_2` (`FORCE_9V`). The `reg` debug attribute added to the driver lets us
try those writes live without rebuilding.

Also note: with the tablet plugged into a **PC** port the chip reports `APSD_SDP` and the driver correctly limits the
input to 500 mA; measured charge from a laptop port is ~0.7 A. The 3 A setting applies to DCP/CDP and to an
undetermined source.

### HVDCP enabled in the driver: charging is now ~2.1-2.6 A

With the Xiaomi MDY-15-ET (Quick Charge 3.0, 67 W) plugged in, the chip reports `0x308 = 0x28` (APSD_DCP +
`QC_2P0`), no OV, and after enabling HVDCP the battery takes **2.1-2.6 A** instead of ~0.7-1.2 A:

```
21:20:17 ICL=2350000 батарея=2136000 Charging
0x308 = 0x28   0x310 = 0x10   0x362 = 0x6c
```

The driver now sets, at probe:

- `USBIN_OPTIONS_1` (`0x362`) bits `HVDCP_AUTH_ALG_EN` (6) | `HVDCP_AUTONOMOUS_EN` (5) | `HVDCP_EN` (2) — the same
  set CAF's `smblib_hvdcp_detect_enable()` / `smblib_hvdcp_hw_inov_enable()` write, which is what opens the input
  beyond the "SDP-like" 500 mA path;
- `USBIN_ADAPTER_ALLOW` (`0x360`) = `5V_OR_9V_TO_12V`.

Measured: effective input limit 2.35 A at 5 V (~11.7 W), battery 2.1-2.6 A (~9-11 W into the cells). That is roughly
double the previous best.

9 V still does not engage with this adapter: writing `CMD_HVDCP_2` (`0x343`) = `FORCE_9V` is accepted and the chip
clears the register after sending the pulse train, but the adapter stays at 5 V (`0x310 = 0x10`, no change in current).
Since we are already at the chip's AICL ceiling (2.35 A) and the battery is in its taper region, 9 V would add little;
if more is needed the next lever is the continuous AICL threshold, not the voltage.

### QC 3.0 is detected; 9 V still does not engage at 83 % SoC

After re-plugging the Xiaomi adapter the chip reports `0x308 = 0x48` — `APSD_DCP | QC_3P0`, i.e. a **Quick Charge 3.0**
adapter, unlike the earlier `0x28` (QC 2.0). Charging is steady at ICL 2.0 A, 2.1 A into the battery, no OV.

Writing `CMD_HVDCP_2` = `FORCE_9V` (and stepping `SINGLE_INCREMENT` four times) is accepted by the chip — it clears the
command register after issuing the pulses — but the adapter stays at 5 V: the effective limit and the battery current do
not move. The plausible reason is the one the operator suggested: at 83 % the charger does not need the extra headroom,
so the QC state machine never steps up. Worth retrying at ~50-60 % SoC, where the demand is higher; the whole test needs
no rebuild — `echo "343 10 10" > .../reg` and read `0x310` / `0x107`.
