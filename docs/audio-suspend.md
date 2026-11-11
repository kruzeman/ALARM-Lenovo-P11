
## Sound after suspend: what was found (11.11.2026)

**Symptom.** After almost every resume from `s2idle` the ADSP faults and audio never comes back:

```
PM: suspend entry (s2idle)
PM: suspend exit
qcom_q6v5_pas a400000.remoteproc: fatal error received: EX:kernel:0x0:irq46:0x116:PC=0xf002ac00
remoteproc remoteproc1: crash detected in adsp: type fatal error
qcom-soundwire a740000.soundwire: swrm_wait_for_wr_fifo_avail err write overflow
soundwire sdw-master-3-0: trf on Slave 1 failed:-5 read addr 346c
```

**Root cause.** `drivers/remoteproc/qcom_q6v5_pas.c` has no system-sleep handling at all: no
`SET_SYSTEM_SLEEP_PM_OPS`, no suspend/resume. The DSP is left running while the platform power-collapses its
resources, so the firmware faults on the way back.

**Two driver bugs blocked recovery.** Rebuilding the audio stack at runtime (unbind/bind of the card and the two
SoundWire masters) used to be impossible:

1. `qcom_swrm_remove()` called `clk_disable_unprepare()` unconditionally, but with 3 s autosuspend the controller is
   almost always runtime-suspended and `hclk` is already off. The clock refcount underflowed (clk core WARN) and the
   next probe failed with `-EINVAL`.
2. After fixing that, probe still failed on the interrupt:
   `irq: type mismatch, failed to map hwirq-328 for interrupt-controller@f200000` followed by
   `request_irq(0) 0x0` and `probe ... failed with error -22`, because the driver forced `IRQF_TRIGGER_RISING` on an
   already-mapped hwirq.

Both are fixed in `kernel/patches/0013-soundwire-qcom-rebind-recovery.patch` (resume before unprepare, and let the
DT-provided trigger type stand). With that module loaded, tearing the stack down and rebuilding it by hand works and
audio comes back — verified on the device:

```
sound > unbind; a740000 > unbind; a610000 > unbind
a610000 bind: 0   a740000 bind: 0   card bind: 0
sink: Built-in Audio Speakers, source: Built-in microphones, no ADSP crash
```

**What does NOT work: doing it around suspend from userspace.** A systemd sleep hook that unbound the card and the
masters and then stopped the ADSP (`echo stop > /sys/class/remoteproc/remoteproc1/state`) put the device into
**Qualcomm CrashDump** on the way back (`echo start`). Stopping or starting the ADSP while the audio stack is torn down
crashes the device. Any real fix must live in the kernel, where ALSA removes the card first and the DSP is stopped
afterwards, in the right order.

**Recovery when the boot chain locks up.** After that crash the device refused to load *any* image, including the
signed stock `boot.img` and the stock recovery: `FAILED (remote: 'Failed to load/authenticate boot image: Load Error')`.
What helped:

1. Hold power for 60 s (full PMIC reset, not a warm reboot).
2. Enter fastboot (vol-down + power) and immediately `fastboot flash boot_b boot-arch-j606f-good.img`
   (`sha256 ec58e6b3...`, release v0.2) plus `fastboot --set-active=b`.
3. Reboot. Only the first boot after a power cycle may succeed, so do not waste it on test images.

The stock firmware for reference/recovery is `TB-J606F_S120184_210520_ROW.zip` (lolinet mirror, 2.4 GiB) — it contains
`vbmeta.img`, `boot.img`, `dtbo.img`, `xbl.elf`, `abl.elf` and `prog_firehose_ddr.elf` for EDL.
