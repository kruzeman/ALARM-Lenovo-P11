# Audio

Sound card: `Lenovo-TB-J606F` (machine driver `snd-soc-sm8250`, compatible `qcom,qrb4210-rb2-sndcard`).

```
/proc/asound/cards
 0 [LenovoTBJ606F]: sm4250 - Lenovo-TB-J606F
```

## What works

- **Speakers** — four AW88258 amplifiers on I²C0 (`0x34–0x37`) on `PRIMARY_TDM_RX_0`, 48 kHz / 4 slots ×
  32 bit, stereo in slots 0/1. The UCM profile enables the route
  `name='PRIMARY_TDM_RX_0 Audio Mixer MultiMedia1'` and sets the amplifier volumes.
- **Headset/USB-C** — WCD937x, SoundWire (rx/tx/va macros) and `pm4125` all probe, MBHC sees the jack, but
  the analogue path goes through an **FSA4480** switch which is not described yet, so there is no sound in
  the connector.
- **ES7210 microphones** — the codec driver exists and works up to the point where a stream is started, see
  below.

WirePlumber: this TDM path needs **S16LE**, otherwise it is digital silence. See
`rootfs/etc/wireplumber/wireplumber.conf.d/51-j606f-nommap.conf`.

## ES7210 microphones (work in progress)

The codec is an Everest ES7210 (4-channel ADC) on I²C1 `0x40`; its data goes into the primary TDM bus, the
same one the speakers use. The driver (`sound/soc/codecs/es7210.c`, patch 0003) initialises the chip and
registers in the card:

```
/sys/kernel/debug/asoc/Lenovo-TB-J606F/es7210.1-0040
```

Device tree link (patch 0001): `builtin-mic-dai-link` → `cpu = <&q6afedai PRIMARY_TDM_TX_0>`.

### What has been established

1. A TDM port **requires its own `&q6afedai` child node** carrying the synchronisation parameters:

   ```dts
   dai@19 {
           reg = <PRIMARY_TDM_TX_0>;
           qcom,tdm-sync-mode  = <0>;
           qcom,tdm-sync-src   = <1>;
           qcom,tdm-data-out   = <0>;
           qcom,tdm-invert-sync = <1>;
           qcom,tdm-data-delay = <0>;
           qcom,tdm-data-align = <0>;
   };
   ```

   Without it `q6afe_tdm_cfg` stays zeroed: earlier that produced an audio-SMMU fault and an ADSP crash
   (reboot loop), now it is a clean error.
2. The machine driver (patch 0002) sets the `IBIT` clock, `set_tdm_slot()` and `set_channel_map()` for
   `PRIMARY_TDM_TX_0`, mirroring the working RX path of the speakers.
3. **Remaining blocker**: `AFE_PORT_CMD_DEVICE_START` for port `0x9001` is rejected by the ADSP firmware —
   `DSP returned error[2]`, `AFE enable for port 0x9001 failed -22`. Tried so far: 2 and 4 channels, slot
   masks `0x3` and `0xF`, with and without a channel map, the same sync/clock settings as RX.

Next things to check:

- the ADSP firmware's AFE port table (which TX ports it advertises at all);
- whether the microphones actually sit on the second LPASS bus: the stock DT has a separate `lpi_i2s2_*`
  pin group besides the `lpass-tdm1-*` pins used by the speakers. If the ADC is on I2S2, the port to bring
  up is a `*_MI2S_TX`, not TDM;
- module load order: `q6afe` provides the `q6afecc` clock provider; without it the LPASS pinctrl stays
  deferred and so does the whole card:

  ```bash
  modprobe q6afe q6core q6routing q6asm q6afe-dai q6asm-dai
  modprobe pinctrl-sm6115-lpass-lpi
  modprobe snd_soc_sm8250
  ```

### How to test

`rootfs/usr/local/bin/mic-test.sh` enables the route, records 3 seconds from `hw:0,1` and `hw:0,0`,
computes the peak and logs everything to `/var/log/mic-test.log` (the log survives a crash):

```bash
amixer -c0 cset name='MultiMedia2 Mixer PRIMARY_TDM_TX_0' 1
arecord -D hw:0,1 -f S16_LE -c 2 -r 48000 -d 3 /tmp/mic.wav
```

If `dmesg` shows `AFE enable for port 0x9001 failed -22`, the port never started and no file is produced.

### Current state of the built-in microphones (ES7210 on PRIMARY_TDM_TX_0)

Capture now **opens** — the DSP accepts the port. Two things were needed:

1. **Two-channel TDM frame.** `snd_soc_dai_set_tdm_slot(cpu, GENMASK(1,0), 0, 4, 32)` — a
   four-channel mask (`GENMASK(3,0)`) makes the ADSP answer `ADSP_EBADPARAM` (error 2) on
   `AFE_PORT_CMD_SETUP`, and the port never starts.
2. **Codec ratio must match the frame, not the sample width.** The TDM frame is
   `slots × slot_width` = 4 × 32 = 128 bits, so the ES7210 needs `REG02 = 0xC1` (128 × fs).
   `0x41` (64 × fs) is right only for a 2 × 32 I2S frame. `es7210.c` now takes `set_tdm_slot`
   from the machine driver and derives the ratio from it.

What is still open: the capture produces a valid file (144000 frames, stereo, 3 s) but the
samples are **all zero** — the port runs, the codec does not deliver data. Reading the ES7210
registers from userspace is blocked (the driver owns address 0x40), so the next steps are:
`i2c-dev` access through the driver or a debugfs hook, verifying the codec really got the TDM
init (`0x11/0x12`, `0x02`), the MCLK/SCLK the chip sees, and on which of the two LPASS TDM data
lines (`gpio8`/`gpio9`) the ADC drives its `SDOUT`.

Warning from the same session: the stock `adspr/adsps/adspua.jsn` protection-domain maps must
**not** be copied into `/lib/firmware/qcom/sm6115/LENOVO/J606F/` — with them the ADSP enters a
`qcom_q6v5_pas ... Handover signaled` crash loop and Wi-Fi (whose firmware is loaded through the
ADSP) disappears. `pd-mapper` is not needed for audio on this device.

### The card that only appeared on some boots (PDR race) — fixed

`q6core`/`q6afe`/`q6asm`/`q6adm` in `sm6115.dtsi` carried
`qcom,protection-domain = "avs/audio", "msm/adsp/audio_pd"`. `apr_probe()` only registers
PD-dependent services when PDR reports that domain **UP**, and that report arrives over QRTR
from the ADSP — whose `IPCRTR` channel is not announced on every boot (it is present for the
CDSP, not reliably for the ADSP). Whenever it was missing, nothing created `service@4`, so no
`q6afecc` clock, so the LPASS pinctrl stayed in `devices_deferred` and the sound card never
instantiated: `--- no soundcards ---`, no ASoC error in the log.

`kernel/patches/0006-dts-audio-apr-no-protection-domain.patch` drops that property for the
four audio services, so they are registered unconditionally in `apr_probe()`. After it a boot
shows `service@` × 4, `devices_deferred` empty and the card present — every time.

### TDM TX: the parameters mainline never sent

`q6afe_tdm_port_prepare()` did not copy `ctrl_data_out_enable`, `ctrl_invert_sync_pulse` or
`ctrl_sync_data_delay` into the AFE port config, although the DT parser already read
`qcom,tdm-data-out`, `qcom,tdm-invert-sync` and `qcom,tdm-data-delay`.
`kernel/patches/0005-q6afe-tdm-tx-data-out.patch` passes them through, and the TX dai node sets
`qcom,tdm-data-out = <1>`.

State after all of the above: the ES7210 is configured over I²C as 16-bit TDM I2S
(`0x11 = 0x60`, `0x12 = 0x02`, `0x08 = 0x14`), the chip reports `CSM_STATE = normal`, analog
path on, mics selected (`0x43` bit 4), the AFE port starts and `arecord` writes a full-size
file — but every sample is still zero. Next candidates, in order: `qcom,tdm-invert-sync`
polarity on the TX node, and whether the ADC drives LPASS `gpio8` or `gpio9`
(`SOUT1`/`SOUT2`), i.e. whether the port should be `PRIMARY_TDM_TX_1`.

### The microphones are not on TDM — they are on the codec's SoundWire mics

The stock `mixer_paths.xml` (found by scanning `/dev/sda14` for `<mixer>`) settles it:

```
<path name="spkr-vi-record">
    <ctl name="PRI_TDM_RX_VI_FB_MUX" value="PRI_TDM_TX_0" />
    <ctl name="PRI_TDM_TX_0 Channels"  value="Four" />
    <ctl name="PRI_TDM_TX_0 Format"    value="S32_LE" />
    <ctl name="PRI_TDM_TX_0 SampleRate" value="KHZ_48" />
</path>
<path name="amic2">
    <ctl name="TX DEC0 MUX"   value="SWR_MIC" />
    <ctl name="TX SMIC MUX0"  value="SWR_MIC4" />
    <ctl name="TX_CDC_DMA_TX_4 Channels" value="One" />
    <ctl name="TX_AIF2_CAP Mixer DEC0" value="1" />
</path>
```

`PRI_TDM_TX_0` in four-channel `S32_LE` is `spkr-vi-record`: the smart amplifiers'
voice-isolation feedback, i.e. the amps are the *source* of that TX stream. Capturing it
on the ES7210 side can only ever return zeros, which is exactly what we measured through
every variation (2/4 slots, TDM-DSP vs TDM-I2S, both sync polarities, `TX_0` vs `TX_1`,
16- and 32-bit words, `ctrl_data_out_enable` passed to the DSP).

The built-in microphones are `amic2`/`amic3` → `TX DEC0 MUX = SWR_MIC`,
`TX SMIC MUX0 = SWR_MIC4` → `TX_CDC_DMA_TX_4`, i.e. the **WCD9370** codec's SoundWire
mic inputs. Getting microphone capture means bringing up the WCD937x capture path
(SoundWire bus → codec → CDC_DMA_TX), not more TDM tuning.

The ES7210 remains wired and usable as a *second* input, but on this board it is not
what Android uses for the built-in mics.

### Where the built-in microphones actually live (measured, 2026-11-08)

The ES7210/TDM work above was chasing the wrong bus. The stock `mixer_paths.xml` proves it:

```
<path name="spkr-vi-record">
    PRI_TDM_RX_VI_FB_MUX = PRI_TDM_TX_0   ← the smart amps' voice-isolation feedback
<path name="amic2">
    TX DEC0 MUX = SWR_MIC, TX SMIC MUX0 = SWR_MIC4, TX_CDC_DMA_TX_4 Channels = One
```

`PRI_TDM_TX_0` in `Four`/`S32_LE` is the amplifiers talking back for speaker protection —
the amps are the source, so capturing it from the ADC side can only ever return zeros, which is
exactly what every TDM variation measured (2/4 slots, TDM-DSP vs TDM-I2S, both sync polarities,
`TX_0` vs `TX_1`, 16/32-bit, `ctrl_data_out_enable` passed to the DSP).

The microphones are `amic2`/`amic3`: the **WCD9370** ADC, which reaches the AP over SoundWire
(`va_swr_master` on bengal owns the `tx_swr` pins, LPI gpio0-2) and then a CDC DMA TX port.

### SoundWire TX state and the two fixes found so far

* Both codec slaves bound (`sdw:2:0:0217:010a:00:4` RX, `sdw:3:0:0217:010a:00:3` TX), but the
  TX slave reports `Alert` instead of `Attached`, and capture fails with `hw_ptr = 0` and
  `Input/output error` on any port (`TX_CODEC_DMA_TX_3/4`, 1 or 2 channels, 8 or 48 kHz).
* The nodes were missing the static channel maps, so the driver logged
  `Static channel mapping not specified using device channel maps`. Adding
  `qcom,tx-channel-mapping = /bits/ 8 <1 2 1 1 2 3 3 4 1 2 3 4>` and
  `qcom,rx-channel-mapping = /bits/ 8 <1 2 1 1 2 1 1 2>` (taken from the reference board)
  removes the warning.
* Adding a link with the VA macro (`<&vamacro 0>` + `VA_CODEC_DMA_TX_0`) makes the device fall
  into a Qualcomm CrashDump at boot: the ADSP faults before any stream is opened, so that is not
  the way in until the bus itself is healthy.
* Crash log (ECC-damaged but readable): `arm-smmu c600000.iommu: Unhandled context fault:
  fsr=0x402, SID=0xE3` right after the capture attempts. Playback never faults.

### Next steps (in order)

1. Get the TX slave out of `Alert`: compare the master's port configuration at `a740000`
   (`din-ports = 3` while the controller reports 4) against the vendor values, and check that the
   VA macro is actually clocked (`qcom,dmic-sample-rate` is missing from its node, the vendor
   sets `qcom,va-dmic-sample-rate = <600000>`).
2. Only then change the DAPM route to match the stock mux choice: `TX SMIC MUX0 = SWR_MIC4`
   means the codec output must feed `TX SWR_INPUT4`, not `TX SWR_INPUT1`.
3. Then point the capture link at the right CDC DMA TX port and verify with `arecord`.


### State at the end of 8 November (microphones)

The top edge has two openings — at least two microphones, so the capture target is two
channels (codec DEC0 and DEC1, inputs SWR_MIC0 and SWR_MIC4).

Done and verified:
* The SoundWire TX bus now has a working configuration: `qcom,tx-port-mapping = <1 2 3 4>`
  (ADC1..4 to ports 1..4), the vendor `qcom,tx-channel-mapping` values,
  `qcom,din-ports = <4>`, and routes ADC1..3 to `TX SWR_INPUT0/1/2/4/5`.
* Root cause of `Bus clash detected` and the permanent `Alert` found: the driver enabled
  **nine** channels over four ports (every codec channel is on by default). Turning off the
  unused switches (`ADC1/3`, `DMIC0..5`, `MBHC Switch`) reduces the stream to a single port
  with `ch_mask = 0x1`, and the clash disappears.
* The capture link now uses `TX_CODEC_DMA_TX_4`, matching `amic2` in the stock configuration.

Remaining: capture still ends with `EIO` on the first read — the DSP never hands over
buffers. `hw_params`, prepare and port start complete without errors, and the kernel log stays
empty even with dyndbg on `soundwire`, `wcd937x` and `q6asm`. Next step is the ASM session to
AFE port relationship on the ADSP side, not the bus configuration.

### Built-in mic capture: current state (WCD9370 over SoundWire)

The DT is what decides whether capture is even reachable, and the booted image must be built from the tree —
not from an older dump. With the tree DTB (`sm6115p-lenovo-j606f-hx83102p.dtb`) three things changed at once:

- built-in mic link carries the real chain, `codec { sound-dai = <&wcd937x 1>, <&swr0 0>, <&vamacro 0> }`,
  `cpu { sound-dai = <&q6afedai VA_CODEC_DMA_TX_0> }` — an older image pointed the same link at the ES7210
  (`<&es7210>`), so the VA_CODEC_DMA_TX_0 backend was never found and capture failed at `open()` with
  `EINVAL` / `no BE found for VA_CODEC_DMA_TX_0 Capture`;
- the TX SoundWire master has `qcom,din-ports = <4>` and 4-entry `qcom,ports-*` tables, matching the
  controller (otherwise `din-ports (3) mismatch with controller (4)`);
- the codec slave carries `qcom,tx-port-mapping = <1 2 3 4>` and a 12-byte `qcom,tx-channel-mapping`.

Result with that image: **both SoundWire slaves read `Attached`** (the TX slave used to sit in `Alert`, which
alone explains `EIO`/zeros), the card registers with no route errors, and capture no longer fails to open.

What is still open: `arecord -D hw:0,1` starts and then **blocks in the kernel** (`arecord` in state `D`, open
PCM stays `OPEN` with a dead owner) — the stream runs but the DSP never delivers TX buffers. A blocked
capture cannot be cleared without a reboot, and every reboot currently costs minutes because
`j606f-wifi-reprobe` was removed during the CFI investigation.

Next steps (in order): restore `j606f-wifi-reprobe`; run the capture **non-blocking** (`arecord -N`) so the
kernel survives the attempt; read the instrumented `wcd937x_sdw_hw_params()` `dev_info` to see whether the
codec is configured at all and with which ports/channels; then look at the AFE/q6asm side that is supposed to
produce the TX buffers.

### Experiment: which CDC-DMA backend the built-in mic uses

Two DT variants were tested on hardware:

- `cpu { sound-dai = <&q6afedai VA_CODEC_DMA_TX_0> }` (as the stock mixer suggests for the VA path):
  both SoundWire slaves read `Attached`, capture opens without `EINVAL`/`EBUSY`, but the first
  `arecord` **hangs the task in `D`** and the open PCM stays `OPEN` with a dead owner; afterwards the
  codec can fail to re-initialise (`wcd9370-codec ... Initialization not complete`, `ASoC error (-110)`)
  and the card disappears until a power cycle.
- `cpu { sound-dai = <&q6afedai TX_CODEC_DMA_TX_3> }` (the reference qcm6490-idp backend, unique DAI —
  `TX_CODEC_DMA_TX_4` already belongs to the headset-mic link, and using it twice makes the card fail to
  register and the device fall into fastboot): the TX SoundWire slave stays in **`Alert`**.

So the VA backend gets the bus further (attached, stream opens) at the cost of a kernel-side hang, while the
TX-macro backend does not even attach. Next diagnostic that does not need a live console: let the capture
wedge, power-cycle, then read `journalctl -k -b -1 | tail -60` — journald persists kernel messages to disk,
so the last lines before the hang (including the instrumented `hw_params` `dev_info`) survive.
