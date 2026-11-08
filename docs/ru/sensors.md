# Сенсоры, автоповорот, датчик света

## Как поднимается SSC (Snapdragon Sensor Core)

Датчики живут в ADSP и доступны через SSC:

1. Прошивка/конфиги ADSP и реестр сенсоров в `/usr/share/qcom/sm6115/LENOVO/J606F/`
   (`dsp/adsp`, `sensors/config`, `sensors/registry`, `socinfo`) — берутся из стоковых разделов
   `persist` (`/dev/sda2`) и `dsp_b` (`/dev/sde29`), их нельзя стирать.
2. `hexagonrpcd` (AUR) c drop-in'ами для `hexagonrpcd-adsp-rootpd` и `hexagonrpcd-adsp-sensorspd`
   (`-f /dev/fastrpc-adsp -d adsp -R $RPC`), каталог прошивки — в `/etc/conf.d/hexagonrpcd-*`.
3. Проверка:

   ```bash
   ssccli --sensor accelerometer --timeout 5
   ssccli --sensor light --timeout 5          # ~15 люкс в комнате
   monitor-sensor                            # iio-sensor-proxy: HasAmbientLight = true
   ```

## Автоповорот

`iio-sensor-proxy` акселерометр через SSC не видит, поэтому поворотом управляет свой демон
`j606f-autorotate` (пользовательский systemd-юнит): читает `ssccli --sensor accelerometer` и вызывает
`kscreen-doctor output.DSI-1.rotation.<normal|left|inverted|right>`.

Калибровочные якоря (угол наклона в градусах → поворот экрана):

```
(3.5, 90), (93.5, 180), (183.5, 270), (273.5, 0)
```

Панель смонтирована «вверх ногами» (`rotation = <180>` в DTB), тач при этом отдаёт координаты корпуса —
поэтому автоповорот и ориентация панели независимы.

`kscreen-doctor` нужно вызывать с правильным сокетом:

```bash
export XDG_RUNTIME_DIR=/run/user/1001 WAYLAND_DISPLAY=wayland-1 \
       DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1001/bus
```

## Датчик света и подсветка

- Датчик: **Lite-On LTR578** через SSC (`ssccli --sensor light`), работает штатно.
- Подсветка: `/sys/class/backlight/5e94000.dsi.0` (0…4095), обычный sysfs.
- Автояркость в KDE: PowerDevil 6.8 не умеет ambient light, поэтому автоподсветку нужно делать своим
  демоном (lux → brightness с гистерезисом). Датчик и подсветка для этого уже готовы.


## Авто-яркость (Plasma 6.6+)

В KWin 6.8 автояркость есть и для `DSI-1` рапортует `Automatic brightness: supported, enabled`,
но `iio-sensor-proxy` 3.9 с `libssc` 0.4.x только находит LTR578 и не получает ни одного сэмпла
(то же самое с акселерометром), поэтому кривая яркости оставалась из одной точки.

Решение: `j606f-sensor-proxy` сам занимает шинное имя `net.hadess.SensorProxy` и публикует
`HasAmbientLight` / `LightLevel` / `LightLevelUnit`, опрашивая датчик через `ssccli` (он с этим
датчиком работает). Для KWin это обычный датчик: штатная галочка остаётся, а кривую,
гистерезис и анимацию считает сам KWin — свой демон яркости больше не нужен.

Кривая не задаётся вручную, а выучивается: выставь яркость один раз в темноте и один раз на
ярком свете (`kscreen-doctor output.DSI-1.brightness.NN`) — KWin сохранит точки в
`~/.config/kwinoutputconfig.json` (`autoBrightnessCurve`) и дальше интерполирует сам (измерено:
108 люкс -> 80%, закрытый датчик 0.37 люкс -> 40%, с анимацией).

`iio-sensor-proxy` должен быть **замаскирован** (`systemctl mask iio-sensor-proxy`): простого
`disable` мало — KWin поднимает его по D-Bus-активации, он первым занимает
`net.hadess.SensorProxy` и ничего не отдаёт.
`j606f-als-brightness` (прежний скриптовый демон) оставлен в репозитории как запасной вариант,
но выключен.

### Нужна только карта сенсорного PD, а `pd-mapper` должен оставаться выключенным

Датчику света нужен ровно один файл — `adsps.jsn` (`sensor_pd`) в
`/lib/firmware/qcom/sm6115/LENOVO/J606F/`; сам `pd-mapper` при этом выключен. Без этого файла `ssccli --sensor
light` не работает, и мост отдаёт 0 люкс (автояркость молча перестаёт работать); с остальными тремя картами
(`adspr`, `adspua`, `cdspr`) и запущенным `pd-mapper` ADSP уходит в `Handover signaled, but it already
happened` и утягивает за собой Wi-Fi. Достать файл: `mount /dev/disk/by-partlabel/modem_a /mnt/fw`, скопировать
`/mnt/fw/image/adsps.jsn`, `umount`, затем `systemctl restart hexagonrpcd-adsp-sensorspd j606f-sensor-proxy`.
