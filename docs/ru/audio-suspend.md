
## Звук после сна: что выяснено (11.11.2026)

**Симптом.** Почти после каждого пробуждения из `s2idle` ADSP падает, и звук не возвращается:

```
PM: suspend entry (s2idle)
PM: suspend exit
qcom_q6v5_pas a400000.remoteproc: fatal error received: EX:kernel:0x0:irq46:0x116:PC=0xf002ac00
remoteproc remoteproc1: crash detected in adsp: type fatal error
qcom-soundwire a740000.soundwire: swrm_wait_for_wr_fifo_avail err write overflow
soundwire sdw-master-3-0: trf on Slave 1 failed:-5 read addr 346c
```

**Корень.** В `drivers/remoteproc/qcom_q6v5_pas.c` **нет обработки системного сна вообще**: ни
`SET_SYSTEM_SLEEP_PM_OPS`, ни suspend/resume. DSP остаётся запущенным, пока платформа обесточивает его ресурсы, и
прошивка падает на обратном пути.

**Восстановлению мешали два бага драйвера.** Пересобрать звуковой стек в рантайме (unbind/bind карты и двух
мастеров SoundWire) раньше было невозможно:

1. `qcom_swrm_remove()` безусловно вызывал `clk_disable_unprepare()`, но при автосуспенде в 3 с контроллер почти
   всегда уже в runtime-suspend, и `hclk` выключен. Счётчик клоков уходил в минус (WARN в clk core), следующий
   probe падал с `-EINVAL`.
2. После исправления probe всё равно падал на прерывании:
   `irq: type mismatch, failed to map hwirq-328 for interrupt-controller@f200000`, затем `request_irq(0) 0x0` и
   `probe ... failed with error -22` — драйвер жёстко требовал `IRQF_TRIGGER_RISING` для уже замапленного hwirq.

Оба исправлены в `kernel/patches/0013-soundwire-qcom-rebind-recovery.patch` (сначала resume, потом unprepare; тип
триггера берётся из DT). С этим модулем ручная разборка и сборка стека работает, звук возвращается — проверено на
устройстве:

```
sound > unbind; a740000 > unbind; a610000 > unbind
a610000 bind: 0   a740000 bind: 0   card bind: 0
sink: Built-in Audio Speakers, source: Built-in microphones, падений ADSP нет
```

**Что НЕ работает: делать это вокруг сна из userspace.** systemd-хук, который отвязывал карту и мастеров, а затем
останавливал ADSP (`echo stop > /sys/class/remoteproc/remoteproc1/state`), на обратном пути (`echo start`) уронил
устройство в **Qualcomm CrashDump**. Остановка или запуск ADSP при разобранном звуковом стеке роняет устройство.
Настоящее исправление должно жить в ядре, где ALSA сначала снимает карту, а DSP останавливается уже после — в
правильном порядке.

**Восстановление, когда загрузочная цепочка залипает.** После этого падения устройство отказывалось грузить **любой**
образ, включая подписанные стоковые `boot.img` и recovery:
`FAILED (remote: 'Failed to load/authenticate boot image: Load Error')`. Помогло:

1. Удержание питания 60 с (полный сброс PMIC, не тёплая перезагрузка).
2. Вход в fastboot (громкость-вниз + питание) и сразу
   `fastboot flash boot_b boot-arch-j606f-good.img` (`sha256 ec58e6b3...`, релиз v0.2) плюс `fastboot --set-active=b`.
3. Перезагрузка. Успешной может быть только первая загрузка после цикла питания — не тратить её на тестовые образы.

Стоковая прошивка для справки/восстановления — `TB-J606F_S120184_210520_ROW.zip` (зеркало lolinet, 2.4 ГиБ):
внутри `vbmeta.img`, `boot.img`, `dtbo.img`, `xbl.elf`, `abl.elf` и `prog_firehose_ddr.elf` для EDL.
