# Cameras

| | Sensor | I²C | Resolution | Notes |
|---|---|---|---|---|
| Rear | OV13B10 | cci0 bus0 `0x10` | 4200×3120 | VCM `dw9719` (`0x0c`, `focus_absolute` 0…1023) |
| Front | S5K4H7 | cci1 bus1 `0x10` | 3256×2448 | 4 data lanes, MCLK 24 MHz |

The sensor drivers (`ov13b10`, `s5k4h7`), `qcom_camss`/`cci` and the VCM come from the kernel port. The
user-space side is **libcamera** ("simple" pipeline, uncalibrated IPA).

## Checking

```bash
cam -l                                    # list cameras
cam -c 1 --capture=3 --file=/tmp/f.ppm    # indices change between boots — always read cam -l
```

`/dev/video12` is the Venus decoder (H.264/VP9/HEVC), `/dev/video13` the encoder.

## libcamera patch (required for exposure)

Without it the log says:

```
WARN IPASoft soft_simple.cpp:104 IPASoft: Failed to create camera sensor helper for ov13b10
```

and frames come out black or very dark: the soft IPA has no way to drive exposure and gain. The patch
`libcamera/libcamera-ov13b10-s5k4h7.patch` adds two helpers to
`src/ipa/libipa/camera_sensor_helper.cpp`, using the constants from the sensor drivers:

```cpp
/* OV13B10: gain 0x80 == 1x, step 1/128 */
gain_ = AnalogueGainLinear{ 1, 0, 0, 128 };  blackLevel_ = 1024;
/* S5K4H7: gain 0x20 == 1x, step 1/32 */
gain_ = AnalogueGainLinear{ 1, 0, 0, 32 };   blackLevel_ = 1024;
```

Building (on the tablet, ~15 minutes at `-j4`; at `-j8` KWin is starved and the screen goes black):

```bash
git clone --depth 1 --branch v0.7.2 https://github.com/libcamera-org/libcamera.git
cd libcamera && patch -p1 < /path/to/libcamera-ov13b10-s5k4h7.patch
meson setup build --buildtype=release -Dpipelines=simple,uvcvideo -Dipas=simple \
  -Dcam=enabled -Dqcam=disabled -Dgstreamer=disabled -Dpycamera=disabled \
  -Dtest=false -Dlc-compliance=disabled -Ddocumentation=disabled -Dv4l2=enabled \
  -Dandroid=disabled -Dcpp_args="-Wno-error -Wno-array-bounds"
nice -n 19 ionice -c3 ninja -C build -j4
meson install -C build --destdir /tmp/lcstage
# replace /usr/lib/libcamera.so.0.7.2, libcamera-base.so.0.7.2 and libcamera/ipa/ipa_soft_simple.so
```

(With a current GCC the build fails on `-Werror=array-bounds` in `log.cpp` — hence `-Wno-error`.)

## Front camera orientation

The DT marked the sensor as `rotation = <270>` (taken from the stock `sensor-position-roll`), but the
stream from this module already arrives upright, so applications rotated it a second time and the preview
was sideways. Patch 0004 sets `rotation = <0>`.

## Rear camera: no autofocus

- libcamera's simple pipeline implements no AF, so the actuator is never touched.
- The VCM is reachable manually: the `/dev/v4l-subdev*` named `dw9719`, control `focus_absolute` (0…1023).
- The actuator is **only powered while streaming**: outside a stream writes fail with
  `dw9719: Error writing reg 0x0002: -6`, so focus sweeps must happen inside one stream.
- A contrast sweep inside a stream peaks around **focus ≈ 384**, but the picture stays soft — either the
  subject is outside the lens travel or the module is simply soft. Metric used: mean |second derivative|
  over a central crop, normalised by brightness.
- GUI: `plasma-camera` (KDE, libcamera based).

## Known limitations

- The greenish colour cast comes from the uncalibrated IPA (there are no tuning files for these sensors);
  it needs tuning data, not settings.
- The rear camera manages 4–7 fps at 13 MP (that is the pipeline throughput), the front one 30 fps.
