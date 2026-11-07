# Звук

Карта: `Lenovo-TB-J606F` (компонент `snd-soc-sm8250`, драйвер `qrb4210-rb2-sndcard`).

```
/proc/asound/cards
 0 [LenovoTBJ606F]: sm4250 - Lenovo-TB-J606F
```

## Что уже работает

- **Динамики** — 4 усилителя AW88258 на I²C0 (`0x34–0x37`) на `PRIMARY_TDM_RX_0`, 48 кГц / 4 слота × 32 бита,
  стерео в слотах 0/1. UCM-профиль включает маршрут
  `name='PRIMARY_TDM_RX_0 Audio Mixer MultiMedia1'` и ставит громкость усилителей.
- **Гарнитура/разъём** — WCD937x, SoundWire (rx/tx/va macro) и `pm4125` поднимаются, MBHC видит джек,
  но аналоговый выход идёт через **FSA4480** (USB-C), который пока не описан — звука в разъёме нет.
- **Микрофоны ES7210** — драйвер кодека есть и работает до момента запуска потока, см. ниже.

WirePlumber: этому TDM-тракту нужен **S16LE**, иначе цифровая тишина.
`/etc/wireplumber/wireplumber.conf.d/51-j606f-nommap.conf`:

```
monitor.alsa.rules = [ { matches = [ { node.name = "~alsa_output.*" } ]
  actions = { update-props = { audio.format = "S16LE", api.alsa.period-size = 1024, api.alsa.headroom = 4096 } } } ]
```

## Микрофоны ES7210 (в работе)

Кодек — Everest ES7210 (4-канальный АЦП) на I²C1 `0x40`, данные — в primary TDM (та же шина, что у
динамиков). Драйвер `sound/soc/codecs/es7210.c` (патч 0003) инициализирует чип и регистрируется в карте:

```
/sys/kernel/debug/asoc/Lenovo-TB-J606F/es7210.1-0040
```

Линк в DTB (патч 0001): `builtin-mic-dai-link` → `cpu = <&q6afedai PRIMARY_TDM_TX_0>`.

### Что уже выяснено (важно для продолжения)

1. Для TDM-порта **обязателен дочерний узел `&q6afedai`** с параметрами синхронизации:

   ```dts
   dai@19 {
           reg = <PRIMARY_TDM_TX_0>;
           qcom,tdm-sync-mode = <0>;
           qcom,tdm-sync-src  = <1>;
           qcom,tdm-data-out  = <0>;
           qcom,tdm-invert-sync = <1>;
           qcom,tdm-data-delay = <0>;
           qcom,tdm-data-align = <0>;
   };
   ```

   Без него `q6afe_tdm_cfg` нулевой: раньше это давало SMMU fault в аудио-IOMMU и падение ADSP
   (цикл перезагрузок), теперь — чистую ошибку `-22`.
2. Машинный драйвер (`sm8250.c`, патч 0002) на `PRIMARY_TDM_TX_0` ставит `IBIT`-клок, `set_tdm_slot()`
   и `set_channel_map()` — по аналогии с рабочим RX-путём динамиков.
3. **Остаётся блокер**: `AFE_PORT_CMD_DEVICE_START` для порта `0x9001` отбивается прошивкой ADSP —
   `DSP returned error[2]`, `AFE enable for port 0x9001 failed -22`. Перебраны:
   2 и 4 канала, маски слотов `0x3` и `0xF`, с картой каналов и без, одинаковые sync/clock с RX.

Что проверять дальше:

- таблицу AFE-портов в стоковой прошивке ADSP (какие TX-порты она вообще объявляет);
- не висят ли микрофоны на второй LPASS-шине: в стоковом DTB есть отдельная группа пинов
  `lpi_i2s2_*` помимо `lpass-tdm1-*`, которые использует динамики. Если АЦП на I2S2, поднимать надо
  порт `*_MI2S_TX`, а не TDM;
- порядок загрузки модулей: `q6afe` создаёт тактовый провайдер `q6afecc`, без которого LPASS-pinctrl
  висит в deferred, а вместе с ним и вся карта:

  ```bash
  modprobe q6afe q6core q6routing q6asm q6afe-dai q6asm-dai
  modprobe pinctrl-sm6115-lpass-lpi
  modprobe snd_soc_sm8250
  ```

### Как тестировать

`rootfs/usr/local/bin/mic-test.sh` включает маршрут, пишет 3 секунды с `hw:0,1` и `hw:0,0`,
считает пик и складывает всё в `/var/log/mic-test.log` (лог переживает падение):

```bash
amixer -c0 cset name='MultiMedia2 Mixer PRIMARY_TDM_TX_0' 1
arecord -D hw:0,1 -f S16_LE -c 2 -r 48000 -d 3 /tmp/mic.wav
```

Если в `dmesg` появляется `AFE enable for port 0x9001 failed -22` — порт не запущен, запись не пойдёт
(файл не создаётся).
