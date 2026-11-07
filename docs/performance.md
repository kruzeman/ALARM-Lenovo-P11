# Storage and application launch performance

Measured on the tablet with `fio` 3.42 and a small launch-timing helper; the storage is a **Kioxia
KM5V8001DM-B622** (UFS 2.1) behind the mainline `ufshcd-qcom` driver (`4804000.ufshc`), root filesystem on
`/dev/sda15` (ext4, `relatime`).

## Raw storage

| Test | Result |
|---|---|
| Sequential read, 4 M blocks, `direct=1` | **425–490 MB/s** |
| Sequential write, 4 M blocks, `direct=1` | **~172 MB/s** |
| 4K random read, 1 thread, queue depth 1 | **7 500 IOPS**, 128 µs |
| 4K random read, 4 threads × queue depth 16 | **29 000 IOPS** (~110 MB/s) |
| 4K random write, queue depth 1 | **~4 000 IOPS**, 243 µs |

Notes:

- Sequential read is roughly half of what Android gets on the same hardware (700–900 MB/s); that is the
  mainline driver, not the chip.
- I/O scheduler: `none` measured **worse** (6 000 IOPS at QD1) than the default `mq-deadline` (7 500), so the
  default stays.
- UFS devfreq switches between 50 and 200 MHz (`simple_ondemand`); forcing `performance` changed nothing for
  sequential throughput, so the clock is not the limit.
- Read-ahead is already 1 MiB; swap (zram) is never touched in normal use.

## Application start-up

Method: drop the page cache, launch the app in the running Plasma session, wait until the process tree stops
burning CPU and reading disk, and report wall time, CPU time and bytes read.

| Application | Cold start | Warm start | CPU (warm) | Read from disk |
|---|---|---|---|---|
| `kwrite` | ~3.3 s | **1.8 s** | 1.6 s | 0 MB |
| `dolphin` | 6.7 s | **3.0–4.0 s** | 2.4–3.2 s | 0 MB |
| `systemsettings` | 17 s | **10–12.5 s** | 9–9.7 s | 0 MB |

Start-up is **CPU bound, not I/O bound**: with warm caches the applications read nothing from disk yet still
spend 9 seconds of CPU. Rendering is not the problem either — the apps open `/dev/dri/renderD128` and use Mesa
(freedreno); CPU frequencies are correct (Cortex-A73 up to 2.0 GHz, `schedutil`), there is no thermal
throttling (35 °C), no D-Bus timeouts and no QML disk cache to warm up (KDE ships precompiled QML).

`systemsettings` is the worst offender because it loads dozens of KCM plugins on start. Lighter apps
(`kwrite`, `kate`) start in under two seconds.

## Tuning applied

`rootfs/usr/local/bin/j606f-kde-tune.sh`:

- disables the heavy KWin effects (`blur`, `contrast`, `diminutive`, popup/maximise animations, translucency)
  and halves the remaining animation duration — this matters for the Adreno 610 and for general smoothness;
- disables the Baloo file indexer (`balooctl6 disable`) — it keeps the disk and CPU idle when nothing needs
  searching.

Effect on measurements was small (dolphin 3.7–5.5 s → 3.0–4.0 s, `systemsettings` 12.8 s → 10–12.5 s), because
start-up cost is inside the applications themselves, but the desktop feels smoother without blur.

If more responsiveness is needed, the remaining lever is a lighter desktop session (LXQt/XFCE) or lighter
applications — not the storage.
