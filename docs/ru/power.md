# Питание, сон, память

## Сон

Доступен только **s2idle**:

```bash
cat /sys/power/mem_sleep        # [s2idle]
systemctl suspend               # пробуждение — кнопкой Power
dmesg | tail                    # PM: suspend entry / exit
```

После пробуждения выживают Wi-Fi, звук, тачскрин; пого-HID переподключается сервисом
`j606f-hid-resume` (`rootfs/usr/local/bin/j606f-hid-rebind.sh`).

### Что срывает сон и как это лечится

Три устройства на этой машине ломают s2idle, поэтому
`rootfs/usr/lib/systemd/system-sleep/50-j606f-resume` отвязывает их перед сном и возвращает
после пробуждения:

| Устройство | Симптом | Что делает хук |
| --- | --- | --- |
| пого-HID `i2c_hid_of` (`0-0060`, `1-0061`) | `i2c_hid_core_pm_resume ... returns -6`, suspend откатывается через 1 с | unbind / bind |
| USB3-контроллер `4ef8800.usb` | `dwc3-qcom-legacy ...: port-1 HS-PHY not in L2`, suspend прерывается | unbind / bind (зарядка идёт через PMIC/tcpm, не страдает) |
| UART Bluetooth `4a8c000.serial` | `pm_wakeup_irq = 114`, будит через ~1 с после входа в сон | `power/wakeup` disabled / enabled |

## Чехол (Hall-сенсор)

Сенсор — `gpiochip0`, линия **36**, active-low. В DT он оформлен как нормальный input-свитч
(`sm6115p-lenovo-j606f.dts`):

```
key-lid {
    gpios = <&tlmm 36 GPIO_ACTIVE_LOW>;
    linux,input-type = <EV_SW>;
    linux,code = <SW_LID>;
    debounce-interval = <15>;
    wakeup-source;
};
```

`gpio-keys` превращает его в `SW_LID` на `/dev/input/event2` и помечает устройство как
источник пробуждения (`/sys/devices/platform/gpio-keys/power/wakeup` → `enabled`), поэтому
открытие чехла будит планшет.

Сам `logind` крышку обрабатывать **не должен**: `gpio-keys` будит по любому изменению линии,
и немедленный suspend по закрытию тут же будится тем же событием — получается цикл
«уснул-проснулся». Поэтому `/etc/systemd/logind.conf.d/10-j606f-lid.conf` ставит
`HandleLidSwitch=ignore`, а `j606f-lid.service` запускает `j606f-lid-daemon.py`: он ждёт
3 секунды после закрытия (линия уже стабильна, фронт даёт только открытие) и затем усыпляет:

```bash
journalctl -u j606f-lid -f       # SW_LID -> 1 / cover closed -> suspend / SW_LID -> 0
```

KDE-шный PowerDevil по умолчанию тоже реагирует на крышку — нужно выставить `lidAction=0`
(No action) для профилей `AC`, `Battery` и `LowBattery` в `~/.config/powermanagementprofilesrc`,
иначе он шлёт свои suspend'ы поверх демона.

## Батарея

`mm8013` (I²C) не автозагружается сам — добавлен в `/etc/modules-load.d/j606f.conf`:

```
mm8013
```

Контроллер GENI-I²C под топливным датчиком изредка отдаёт таймаут
(`geni_i2c 4a80000.i2c: geni_i2c_gpi_xfer:I2C timeout`), и одного неудачного чтения регистра
хватало, чтобы power_supply-ядро сообщило `driver failed to report 'present' property: -110` —
KDE на пару секунд показывал «батарея отсутствует / 0 %». Патч
`kernel/patches/mm8013-i2c-retry.patch` повторяет каждое чтение регистра четыре раза
(пауза 2–4 мс), прежде чем вернуть ошибку:

```bash
cd /usr/src/linux && patch -p1 < .../kernel/patches/mm8013-i2c-retry.patch
make ARCH=arm64 LLVM=1 M=drivers/power/supply modules
```

Плюс `upower` для индикатора в KDE:

```bash
upower -i /org/freedesktop/UPower/devices/battery_mm8013 | grep -E "percentage|capacity"
```

### Стол загружается без батареи и яркости

`upowerd` при старте обходит `/sys/class/power_supply`, а топливный датчик сидит на той же
проблемной шине GENI-I²C. В начале загрузки это чтение блокируется дольше штатных 90 с
`TimeoutStartSec`, systemd убивает юнит — вместе с ним падают `plasmashell` и `powerdevil`,
и в KDE пропадают батарея и ползунок яркости, пока оба не поднимутся сами (пара минут).
`rootfs/etc/systemd/system/upower.service.d/10-j606f-timeout.conf` поднимает таймаут до 300 с
и перезапускает юнит при сбое.

Саму яркость восстанавливает `systemd-backlight@backlight:5e94000.dsi.0` из
`/var/lib/systemd/backlight/`; если там сохранено тусклое значение с прошлой сессии, панель
стартует почти чёрной — достаточно один раз записать нормальное
(`echo 1400 > /sys/class/backlight/*/brightness`), и сохранится уже оно.

### Настоящая причина: висячие input-устройства тачскрина

`upowerd` падает с фолтом в `input_dev_uevent → vsnprintf → string`, а вместе с ним ложатся
`plasmashell` и `powerdevil`. Виноват вендорный драйвер тачскрина: в пути выгрузки он вызывал
`input_free_device()` на **уже зарегистрированных** устройствах, поэтому каждый
`modprobe -r himax_hx83102e` (а `j606f-touch.service` делает это при каждой загрузке)
оставлял в `/sys/class/input` освобождённое устройство, имя которого указывало на
освобождённую память. Чтение `uevent` такого устройства — ровно то, что делают udev и
upower — разыменовывает битый указатель.

`kernel/patches/himax-input-unregister.patch` запоминает факт регистрации и вызывает
`input_unregister_device()` для зарегистрированных устройств (`input_free_device()` — только
для незарегистрированных). После него в загрузке ровно одна пара
`himax-touchscreen`/`himax-pen`, а upower, батарея и ползунок яркости поднимаются штатно.

## Память (zram)

4 ГБ ОЗУ мало для KDE, поэтому включён zram с zstd:

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

Проверка: `zramctl` → `/dev/zram0` ~1.8 ГиБ, `swapon --show`.

## Замечания по производительности

- Сборка чего-либо на 8 ядрах (`ninja -j8`) вытесняет KWin: экран чернеет, события тача отстают
  (`client bug: event processing lagging behind`). Собирать с `nice -n 19 ionice -c3` и `-j4`.
- В этом ядре встречается `Internal error: Oops - CFI` в `power_supply_changed_work`
  (батарея/зарядка, `qcom_pmi632_charger`/`mm8013`). Система обычно остаётся жива, но может подвиснуть —
  лечится перезагрузкой. К аудио/камерам отношения не имеет.

## USB PD / быстрая зарядка: что показал эксперимент

Если включить PD в DT (убрать `pd-disable`, добавить `sink-pdos` 5 В/3 А + 9 В/2 А и
`op-sink-microwatt` 18 Вт, плюс `source-pdos` 5 В/1.5 А — у порта `power-role = "dual"`, а tcpm без
`source-pdos` падает с `-EINVAL`), переговоры действительно проходят: `tcpm-source-psy` показывает
`voltage_now = 9000000`, `current_now = 2000000` с 65-ваттным PD-адаптером. **Но планшет при этом не
заряжается**: у `pmi632-charger` `input_current_limit = 0` и `status = Not charging`, батарея продолжает
разряжаться, а рабочий стол пишет «разряжается» при воткнутом кабеле.

Причина не в DT, а в драйвере зарядника: `drivers/power/supply/qcom_pmi632_charger.c` только читает
регистры (нет `set_property`, нет записи), поэтому путь HVDCP у SMB5 никто не настраивает, и при 9 В вход
остаётся закрытым. Значит быстрая зарядка требует сначала работы по драйверу (ICL/FCC/HVDCP по карте
регистров SMB5 из CAF), и только потом включения PD в DT — само включение PD только ломает зарядку.

Откатились на образ без PD: зарядка вернулась в `DCP`, `ICL = 1.5 А` при 5 В (≈7.5 Вт на входе).

### Зарядка: драйвер научился задавать входной предел (10.11.2026)

До сих пор `qcom_pmi632_charger` был read-only — именно поэтому при включённом PD получалось `ICL = 0` и зарядки не
было вообще. Теперь есть `set_property` + `property_is_writeable` для `INPUT_CURRENT_LIMIT` (регистр
`USBIN_ICL_CFG 0x370`) и `CONSTANT_CHARGE_CURRENT` (`CHGR_FCC_CFG 0x061`), шаг 50 мА, плюс автоматика в опросе: при
подключении читается результат APSD и вход открывается на 3 А для DCP/CDP и на 500 мА для SDP.

Замерено на адаптере IdeaPad 3 65 Вт USB-C, батарея 80 %:

| состояние | эффективный ICL (`0x107`) | ток в батарею |
|---|---|---|
| было (read-only драйвер) | 950 мА | +0.69 А с запущенной игрой |
| стало, игра запущена | 2.5 А | +0.69 А |
| стало, нагрузку сняли | 2.35 А | +1.2…1.3 А |

В `dmesg` видно, что запись ложится: `set 0x370: want 3000000 uA -> step 60, readback 60, effective 53` — регистр
принимает 3 А, AICL затем устаканивается около 2.35–2.65 А. То есть при 5 В порт теперь тянет ~12 Вт вместо ~5 Вт.

### 9 В (PD) — подготовлено, но не проверено

`boot-pd.img` (DTB 92 364 байта, sha256 начинается на `743e75b3`) включает PD в коннекторе: убран `pd-disable`,
`sink-pdos` 5 В/3 А + 9 В/2 А, `op-sink-microwatt` 18 Вт, `source-pdos` 5 В/1.5 А (обязателен, потому что
`power-role` = `dual`, иначе tcpm возвращает `-EINVAL`). Пока не прошит; модуль с сеттерами ICL уже стоит на
планшете, так что открытый вопрос — заряжается ли теперь порт при контракте 9 В: раньше вход закрывался, потому что
`ICL` некому было запрограммировать. Откат: `boot-txmac2.img` (релиз v0.2).

### 9 В (PD) проверено 10.11.2026: зарядник защёлкивает over-voltage на USBIN

С прошитым `boot-pd.img` и подключённым 65-ваттным адаптером IdeaPad переговоры PD проходят штатно —
`tcpm-source-psy` показывает `voltage_now = 9000000`, `current_now = 2000000` — но планшет не заряжается:
`status = Not charging`, эффективный `input_current_limit` (`0x107`) = 0, батарея разряжается на ~-0.9 А при
воткнутом кабеле.

Регистры в этот момент (из отладочного вывода нашего драйвера):

```
set 0x370: want 2000000 uA -> step 40, readback 40, effective 0, path 0x13, icl_max 40
usbin_rt=0x18 chgr1=0x46 chgr7=0x0
```

- Конфигурационные регистры принимают наши значения (`0x370 = 40`, `0x106 = 40`) — то есть запись `ICL` работает.
- В `usbin_rt = 0x18` установлен `BIT(3)` — это **`USBIN_OV_RT_STS`**: зарядник воспринимает 9 В как
  over-voltage и закрывает вход. `chgr1 = 0x46` (статус 6 = `CHG_PAUSE`) это подтверждает.
- Запись `USBIN_ADAPTER_ALLOW_CFG` (`USBIN_BASE + 0x60`, то есть `0x1360`) — регистра, которым CAF разрешает
  `5V_OR_9V_TO_12V`, — не помогает: со значением `0x07` читается обратно `0x7`, со значением `0x0c` — `0x4`,
  а бит OV остаётся установленным, в том числе после переподключения кабеля.

Причина: в mainline стек Type-C/PD (`tcpm` + `fusb302`) отделён от драйвера зарядника, поэтому зарядник не знает,
что PD поднял VBUS до 9 В. В CAF-овском `smb5-lib` они связаны — состояние PD сообщает заряднику ожидаемое
напряжение, и конфигурация OV/allow выполняется до подъёма напряжения. Чтобы сделать так же, нужно связать
`usb_pd`-notifier с `qcom_pmi632_charger` — это отдельная работа.

Откатились на образ 5 В (`boot-txmac2.img`): с новыми сеттерами ICL/FCC порт тянет ~2.4 А при 5 В, то есть ~12 Вт
вместо прежних ~5 Вт.
