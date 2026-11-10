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

### Working configuration: built-in microphones

The capture path is: codec ADC (ADC2 <- AMIC2) -> port 2 of the TX SoundWire slave -> bus `swr0`
(`a740000`, clocked by the TX macro) -> `TX SWR_INPUT1` -> `TX SMIC MUX0` (`SWR_MIC1`) -> `TX DEC0 MUX`
(`SWR_MIC`) -> `TX_AIF1_CAP Mixer DEC0` -> CDC DMA TX3 -> DSP (`TX_CODEC_DMA_TX_3`).

Two mistakes kept the path dead:

1. The DAI link used `&vamacro`. The VA macro serves voice activation; the TX bus is clocked by `&txmacro`
   and the codec TX data goes through it. With the VA macro the card registered and the SoundWire stream was
   prepared, but the DSP never received a sample.
2. The three TX-macro muxes (`TX SMIC MUX0`, `TX DEC0 MUX`, `TX_AIF1_CAP Mixer DEC0`) are off by default.
   While `TX_AIF1_CAP Mixer DEC0` is off, `q6asm_read()` returns 0 for every period but no `DATA_READ_DONE`
   ever arrives, so `snd_pcm_lib_read` gives up after ~0.7 s with `-EIO` ("capture read timeout").

Widget names matter: this SoC is `lpass_ver_10_sm6115`, which uses the `tx_macro_dapm_widgets_v9_2` set where
the inputs are `TX SWR_INPUT0..7`. The newer sm8250/sm8450 sets call the same inputs `TX SWR_ADCn`; using
those names makes the card fail with `ASoC: Failed to add route`.

No kernel patch is required for any of this — the working setup is DTS plus UCM only. (The `VA_CODEC_DMA_TX_0`
experiments that produced the `sdw_stream_add_slave()` NULL dereference were a dead end: `VA_CODEC_DMA_TX_0`
is missing from `qcom_snd_is_sdw_dai()`, so `qcom_snd_sdw_startup()` returned before setting the stream.)

`rootfs/usr/share/alsa/ucm2/Lenovo/TB-J606F/HiFi.conf` gains a `Mic` device with `CapturePCM "hw:${CardId},1"`
and an `EnableSequence` that sets `MultiMedia2 Mixer TX_CODEC_DMA_TX_3`, `ADC2 MUX`, `TX SMIC MUX0`,
`TX DEC0 MUX` and `TX_AIF1_CAP Mixer DEC0`. PipeWire then exposes "Built-in microphones" as a source right
after boot, and `pw-record --rate 48000 --channels 1 --format s16` returns live signal (measured: peak 32768
with occasional transients, RMS ~3.8k for room noise at unity gain).

**Known limitation: every capture delivers only ~0.5 s of audio, then digital silence.** This is not a
"reopen" problem — it reproduces inside the very first stream. Measured facts:

- Per-0.5 s RMS of a 5 s capture: `[711, 15, 0, 0, 0, …]` — one short burst, then exact zeros (digital silence,
  not a quiet room).
- The DSP keeps streaming: `ASM_CLIENT_EVENT_DATA_READ_DONE` fires continuously (509 events over 5 s, counter
  climbing from #14 to #526, stream state RUNNING). So the DSP is delivering buffers — they are simply full of
  zeros, i.e. the break is upstream of the DSP (codec -> SoundWire -> TX macro).
- During the silent phase the TX macro is still clocked (`LPASS_CLK_ID_TX_CORE_MCLK` 19.2 MHz,
  `lpass-tx-mclk` 9.6 MHz, both `Y`) and both the slave and the master are `active`.
- Codec register dump taken twice inside one stream (early, while audio flows, and late, during silence):
  only `0x3125` changes, `0x0a -> 0x08` — that is `WCD937X_MBHC_NEW_FSM_STATUS`, the headset-jack state machine.
  The TX-macro register dump does not change at all. Turning `MBHC Switch` off before the capture does not help,
  so the jack detector is a red herring.
- The SoundWire start sequence is textbook: `port_params(bank1)` -> bank switch -> `prep(bank0)` ->
  `port_params(bank0)` -> `chn_en en=1 addr=0x220 ch_mask=0x1` -> bank switch. Teardown mirrors it and disables
  the channel in both banks. Nothing in this sequence differs between a working and a silent stream.

Where to look next: the break is between the codec's ADC/TX port and the data the master reads out. The codec's
TX port stays enabled while its register map is unchanged, so the prime suspects are the analog capture path
powering down silently (mic bias / ADC bias not held by DAPM) and the SWR master's read-FIFO underflow
(`qcom_swrm_irq_handler: SWR read FIFO underflow fifo status 0x3` right at the stall). Instrument the codec's
`dapm_widget_event` for `ADC2`/`TX SWR` widgets and the qcom master's read-FIFO path, and try a capture with
`MIC BIAS2` forced on via a `snd_soc_dapm_force_enable_pin()` patch.

**Update after instrumentation (delayed register read).** A 3-second-delayed read added to
`sdw_enable_disable_slave_ports()` settles where the codec stands during the silence: `chn_en B0 = 0x1`
immediately after the write **and 3 s later**, `portctl = 0x0`, `dp0_int = 0x0`, and the codec's analog bias
registers do not move either (`0x3023` MICB2 stays `0x10`, `0x3022` MICB1 stays `0x50`, `0x3001` `0x80`). So the
codec's TX port is still enabled and healthy, its mic bias is still up, and no interrupt is pending — yet the
samples are zeros. That rules out "the codec disabled its port" and leaves the analog ADC output or the
macro's CDC-DMA read path.

**Methodology warning learned the hard way:** do not toggle FE mixer routes (or anything else) *while a stream is
open* on this platform. It leaves the ADM matrix on the ADSP in a state where `q6adm … Failed to close copp -22`
and `q6asm_dai_prepare: stream reg failed ret:-22` appear, after which **playback goes silent too** and only a
reboot clears it. One experiment per boot, with the stream closed before any mixer change.

### Vendor-vs-mainline comparison of the capture path (result)

Comparing `techpack/audio/asoc/codecs/wcd937x/wcd937x.c` from the vendor kernel with mainline
`sound/soc/codecs/wcd937x.c` settles where the bug is *not*:

- The DAPM widget sets are identical (66 vs 67 names, mainline has one extra `WCD_TX_OUTPUT`).
- `wcd937x_codec_enable_adc()` and `wcd937x_enable_req()` write the same registers in the same order
  (`CDC_DIG_CLK_CTL`, `CDC_ANA_CLK_CTL`, `CDC_REQ_CTL`, `ANA_TX_CH1/CH2/CH3`, `ANA_TX_CH3_HPF`); the diffs are
  style only (`BIT(n)` vs `0x..`, atomic vs mutex on `ana_clk_count`).
- Mic bias handling, the ADC power levels (`TX CH1/CH3 PWR`, a vendor-only kcontrol writing bits 6:5 of
  `WCD937X_ANA_TX_CH1/CH3`, default L1) and the BCS/headset-mic special case are all present in mainline or
  irrelevant here (registers `0x3022`/`0x3023`/`0x3001` do not move during the stall).
- The one structural difference: the vendor **re-connects the codec's SoundWire port on every ADC power-up**
  (`wcd937x_tx_connect_port()` → `swr_connect_port()`), while mainline does the equivalent once per stream in
  `wcd937x_sdw_hw_params()` → `sdw_stream_add_slave()`.

So the codec driver is not the missing piece, and the next checks belong to the host side:

1. Sample `clk_summary` for `LPASS_HW_DCODEC_VOTE` (the codec's analog clock vote) and the macro's SWR clock
   bits during the silent phase — the ADC needs the SWR clock to convert, and a stopped SWR clock would explain
   zeros with *no* register change on either side, plus the master's `SWR read FIFO underflow`.
2. Read the TX macro's `CDC_TX_TOP_CSR_*` registers (SWR clock select / DEC clock enable) twice inside one
   stream, the same early-vs-late trick that already worked for the slave.
3. If the SWR clock turns out to be the trigger, the fix belongs in `lpass-tx-macro` (hold the SWR clock while a
   capture stream is active) rather than in the codec or the machine driver.

### 2026-11-10 (morning): the mux value was the bug, and a measurement trap

- **`TX SMIC MUX0` must be 5, not 1.** The enum has a leading `Item #0 'ZERO'`, so index 1 is `SWR_MIC0`
  while index **5 is `SWR_MIC4`** — exactly what the stock `mixer_paths.xml` sets for `amic2`. With 5 the capture
  path finally returns *continuous* data (RMS ~125-136 across every 0.25 s window) instead of a single power-up
  transient followed by zeros. UCM now sets `TX SMIC MUX0 5` and `ADC2 MUX 0` (INP2 = AMIC2).
- **A raw mixer sweep is only valid with PipeWire stopped.** The UCM `EnableSequence` re-applies its values every
  time the device is activated, so `amixer cset` followed by `pw-record` measures the UCM's value, not the one you
  just set — several sweeps were meaningless until repeated with
  `systemctl --user stop pipewire wireplumber pipewire.socket pipewire-pulse.socket` and plain `arecord`.
- **What the power-up transient looks like:** the first non-zero sample sits at about -3549 and decays smoothly
  (`-3549, -3548, -3546, ...`), and the whole-file RMS is *always* 711 regardless of what happens in the room.
  That is the ADC settling, never audio — do not read it as "the mic works for half a second".
- Microphone bias: `MIC BIAS2` (`0x3023`) reads `0x10` (bits 7:6 clear = off) even with a stream running, so a
  temporary `snd_soc_dapm_force_enable_pin()` on `MIC BIAS1/2/3` in the codec probe is installed to keep the analog
  front end alive (`0x3023` then reads `0x50`). Whether DAPM powers it by itself once the route is correct is still
  unverified.
- Still open: the captured level is flat (~125, peak ~930) and did not react to a 1 kHz tone played through the
  speakers — but that test cannot be trusted because the speakers were never confirmed to be playing. The next test
  is acoustic: speak into the tablet and check that the RMS rises.

### Solved: the built-in mics are on ADC1 (AMIC1), not ADC2

Measured with the operator speaking into the tablet while four inputs were swept in one run at `TX_DEC0 Volume`
104 (+20 dB):

| config | result |
|---|---|
| `TX SMIC MUX0 = 5`, `ADC2 MUX = 0` (INP2 / AMIC2) | power-up transient, then silence |
| `TX SMIC MUX0 = 5`, `ADC2 MUX = 1` (INP3 / AMIC3) | silence |
| `TX SMIC MUX0 = 1` with `ADC1` switches on | **live audio**, RMS moving between 19 and 251 with speech |
| `TX SMIC MUX0 = 4` with `ADC1` | transient, then silence |

So the capture path is: codec **ADC1 <- AMIC1** -> TX port 1 of the slave -> master port 1 -> macro input
`SWR_MIC0` (**`TX SMIC MUX0 = 1`**) -> `TX DEC0 MUX = SWR_MIC` -> `TX_AIF1_CAP Mixer DEC0` -> CDC DMA TX3 -> DSP.
The stock `mixer_paths.xml` `amic2` path does not describe this board's built-in mics.

The UCM `Mic` device now enables `ADC1 Switch`, `ADC1_MIXER Switch`, `ADC1 REQ Switch` and sets
`TX SMIC MUX0 1` / `TX DEC0 MUX 1` / `TX_AIF1_CAP Mixer DEC0 1`. Note that a UCM `EnableSequence` runs when the
*device* is created, so after editing the file the node has to be recreated (reboot, or stop WirePlumber and let the
card be re-probed) — restarting WirePlumber alone leaves an already-created node with the old values, which is how
one test run measured `TX SMIC MUX0 = 9` and recorded silence.

**Confirmed by the operator** on 2026-11-10: a recording made through PipeWire's default source was played back to
him and he confirmed his voice is audible and clear (RMS moving 19 -> 3600 with speech, peak ~8.2k).

### Second microphone: not on the codec, it has to be a SoC DMIC (open)

Where the second capture channel could live, and what was measured with the operator speaking into the tablet:

- **Analog inputs (codec).** `ADC1`/`AMIC1` is the working built-in mic (`TX SMIC MUX0 = 1`). Sweeping every macro
  `TX SMIC MUX0` item 2..9 with `ADC1`, `ADC2` and `ADC3` all powered produced only power-up transients and zeros —
  so `AMIC2`, `AMIC3` and `ADC3` carry no live signal on this board.
- **Codec DMIC inputs.** `DMIC0..5 Switch` on with `TX SMIC MUX0 = ZERO` and `TX DMIC MUX0` swept over 1..6 gives no
  data at all: the stream does not even fill a 0.25 s window, so the DSP never receives frames.
- **Port map in the codec** (`wcd937x_sdw_tx_ch_info`): port 1 = ADC1, port 2 = ADC2 + ADC3, port 3 = DMIC0/1/MBHC/
  DMIC2/3, port 4 = DMIC4/5/6. `tx-port-mapping = <1 2 3 4>` already covers all four.

Conclusion: the second microphone is a digital mic wired to the **SoC DMIC interface** (bengal has its own LPASS DMIC),
not to the codec. Capturing it needs a separate DAI link (the `q6dsp-dmic` front-end) plus the matching routing, which
is a DTS change and a new boot image — deliberately left as a separate piece of work, because the mono capture already
works and is used for voice.
