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
