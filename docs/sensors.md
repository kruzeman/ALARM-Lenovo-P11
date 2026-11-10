# Sensors, auto-rotate, ambient light

## How SSC (Snapdragon Sensor Core) comes up

The sensors live in the ADSP and are exposed through SSC:

1. ADSP firmware and the sensor registry live in `/usr/share/qcom/sm6115/LENOVO/J606F/` (`dsp/adsp`,
   `sensors/config`, `sensors/registry`, `socinfo`) and come from the stock `persist` (`/dev/sda2`) and
   `dsp_b` (`/dev/sde29`) partitions — never wipe those.
2. `hexagonrpcd` (AUR) with drop-ins for `hexagonrpcd-adsp-rootpd` and `hexagonrpcd-adsp-sensorspd`
   (`-f /dev/fastrpc-adsp -d adsp -R $RPC`); firmware path in `/etc/conf.d/hexagonrpcd-*`.
3. Verify:

   ```bash
   ssccli --sensor accelerometer --timeout 5
   ssccli --sensor light --timeout 5          # ~15 lux indoors
   monitor-sensor                            # iio-sensor-proxy: HasAmbientLight = true
   ```

## Auto-rotate

`iio-sensor-proxy` never sees the accelerometer through SSC, so rotation is driven by a small daemon,
`j606f-autorotate` (a user systemd unit): it reads `ssccli --sensor accelerometer` and calls
`kscreen-doctor output.DSI-1.rotation.<normal|left|inverted|right>`.

Calibration anchors (tilt angle in degrees → screen rotation):

```
(3.5, 90), (93.5, 180), (183.5, 270), (273.5, 0)
```

The panel is mounted upside down (`rotation = <180>` in the DT) while the touchscreen reports chassis
coordinates — that is why panel orientation and auto-rotate are independent.

`kscreen-doctor` needs the right socket:

```bash
export XDG_RUNTIME_DIR=/run/user/1001 WAYLAND_DISPLAY=wayland-1 \
       DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus
```

## Ambient light and backlight

- Sensor: **Lite-On LTR578** through SSC (`ssccli --sensor light`), works out of the box.
- Backlight: `/sys/class/backlight/5e94000.dsi.0` (0…4095), a plain sysfs device.
- KDE auto-brightness: PowerDevil 6.8 has no ambient-light support, so adaptive brightness needs a small
  daemon (lux → brightness with hysteresis). Sensor and backlight are already available for it.

## Automatic brightness (Plasma 6.6+)

KWin 6.8 has native auto-brightness and reports `Automatic brightness: supported, enabled` for
`DSI-1`, but `iio-sensor-proxy` 3.9 with `libssc` 0.4.x only *finds* the LTR578 — it never
receives a sample (same as the accelerometer), so KWin had nothing to follow and the brightness
curve stayed a single point.

Fix: `j606f-sensor-proxy` owns the `net.hadess.SensorProxy` bus name itself and publishes
`HasAmbientLight` / `LightLevel` / `LightLevelUnit`, polling the sensor through `ssccli`, which
does work. To KWin this is an ordinary sensor, so the stock checkbox keeps working and KWin
computes the curve, hysteresis and animations — no custom brightness daemon is needed.

The curve is learned, not configured: set brightness manually once in the dark and once in bright
light (`kscreen-doctor output.DSI-1.brightness.NN`) and KWin stores points in
`~/.config/kwinoutputconfig.json` (`autoBrightnessCurve`). After that it interpolates on its own
(measured: 108 lux -> 80%, covered sensor at 0.37 lux -> 40%, both animated).

The bridge is installed but **not enabled** by default: on this device the sensor PD map (`adsps.jsn`) makes the
ADSP fall into `Handover signaled, but it already happened` once per second, which eventually takes Wi-Fi, audio
and the whole userspace down.

`iio-sensor-proxy` must stay **masked** (`systemctl mask iio-sensor-proxy`): plain `disable` is not
enough, because KWin activates it over D-Bus, it grabs `net.hadess.SensorProxy` first and then
delivers nothing.
`j606f-als-brightness` (the previous script-based daemon) is kept in the repo as a fallback but is
disabled.

### Only the sensor PD map is needed, and `pd-mapper` must stay off

The light sensor needs exactly one map file — `adsps.jsn` (`sensor_pd`) — in
`/lib/firmware/qcom/sm6115/LENOVO/J606F/`; `pd-mapper` itself stays disabled. Without that file `ssccli --sensor
light` fails and the bridge publishes 0 lux (auto-brightness dies silently); with the other three maps
(`adspr`, `adspua`, `cdspr`) plus `pd-mapper` running, the ADSP drops into `Handover signaled, but it already
happened` and takes Wi-Fi with it. Getting the file: `mount /dev/disk/by-partlabel/modem_a /mnt/fw`, copy
`/mnt/fw/image/adsps.jsn`, `umount`, then `systemctl restart hexagonrpcd-adsp-sensorspd j606f-sensor-proxy`.

### Auto-brightness: KWin must see the sensor before the session starts

Measured with the default KWin curve on 2026-11-10: 0 lux -> 30 %, ~10 lux -> 30 %, 84 lux -> 80 %,
116 lux -> 80 % (saturated). So the default curve already behaves sanely; a custom `autoBrightnessCurve` is optional.

The failure mode to know about: **KWin checks for `net.hadess.SensorProxy` once, when it starts.** On this device the
SSC sensor service appears ~40 s after boot, so if Plasma comes up first, KWin caches "no light sensor" and
auto-brightness stays dead for the whole session even though the proxy reports `HasAmbientLight=true` and correct lux
values afterwards. Restarting `plasma-kwin_wayland` fixes it instantly, which is what `j606f-sensor-proxy` now does by
itself: on the first successful reading it restarts the compositor once per boot (marker file
`/run/j606f-sensor-proxy.kwin-nudged`). Ordering the units differently would be cleaner, but the sensor lives on the
ADSP and its readiness is not something systemd can express.
