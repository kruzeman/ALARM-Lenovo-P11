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

## Чехол (Hall-сенсор)

Сенсор — `gpiochip0`, линия **36**, active-low. `j606f-lid.service` держит `gpiomon` и при закрытии
чехла вызывает `systemctl suspend`:

```
j606f-lid.service: ExecStart=/usr/bin/gpiomon -c gpiochip0 -e both 36
```

Пробуждение **по открытию чехла** пока не работает (нужен `wakeup-source` в узле GPIO в DTB);
пробуждение — только кнопкой Power.

## Батарея

`mm8013` (I²C) не автозагружается сам — добавлен в `/etc/modules-load.d/j606f.conf`:

```
mm8013
```

Плюс `upower` для индикатора в KDE:

```bash
upower -i /org/freedesktop/UPower/devices/battery_mm8013 | grep -E "percentage|capacity"
```

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
