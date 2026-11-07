# Камеры

Сенсоры:

| | Модель | I²C | Разрешение | Особенности |
|---|---|---|---|---|
| Задняя | OV13B10 | cci0 bus0 `0x10` | 4200×3120 | VCM `dw9719` (`0x0c`, focus_absolute 0…1023) |
| Передняя | S5K4H7 | cci1 bus1 `0x10` | 3256×2448 | data-lanes 4, MCLK 24 МГц |

Драйверы сенсоров (`ov13b10`, `s5k4h7`), `qcom_camss`/`cci` и VCM приходят из порта ядра.
Пользовательский слой — **libcamera** («simple» pipeline, uncalibrated IPA).

## Проверка

```bash
cam -l                                    # список камер
cam -c 1 --capture=3 --file=/tmp/f.ppm    # индексы меняются между загрузками — смотри cam -l
```

`/dev/video12` — декодер Venus (H.264/VP9/HEVC), `/dev/video13` — энкодер.

## Патч libcamera (обязателен для экспозиции)

Без него в логе:

```
WARN IPASoft soft_simple.cpp:104 IPASoft: Failed to create camera sensor helper for ov13b10
```

и кадры чёрные/тёмные: программному IPA нечего опереться, чтобы управлять экспозицией и усилением.
Патч `libcamera/libcamera-ov13b10-s5k4h7.patch` добавляет в `src/ipa/libipa/camera_sensor_helper.cpp`
два хелпера по константам из драйверов сенсоров:

```cpp
/* OV13B10: gain 0x80 == 1x, step 1/128 */
gain_ = AnalogueGainLinear{ 1, 0, 0, 128 };  blackLevel_ = 1024;
/* S5K4H7: gain 0x20 == 1x, step 1/32 */
gain_ = AnalogueGainLinear{ 1, 0, 0, 32 };   blackLevel_ = 1024;
```

Сборка (на планшете, ~15 минут при `-j4`, иначе KWin «задыхается» и экран чернеет):

```bash
git clone --depth 1 --branch v0.7.2 https://github.com/libcamera-org/libcamera.git
cd libcamera && patch -p1 < /path/to/libcamera-ov13b10-s5k4h7.patch
meson setup build --buildtype=release -Dpipelines=simple,uvcvideo -Dipas=simple \
  -Dcam=enabled -Dqcam=disabled -Dgstreamer=disabled -Dpycamera=disabled \
  -Dtest=false -Dlc-compliance=disabled -Ddocumentation=disabled -Dv4l2=enabled \
  -Dandroid=disabled -Dcpp_args="-Wno-error -Wno-array-bounds"
nice -n 19 ionice -c3 ninja -C build -j4
meson install -C build --destdir /tmp/lcstage
# заменить /usr/lib/libcamera.so.0.7.2, libcamera-base.so.0.7.2 и libcamera/ipa/ipa_soft_simple.so
```

(В свежем GCC сборка падает на `-Werror=array-bounds` в `log.cpp` — отсюда `-Wno-error`.)

## Поворот фронтальной камеры

В DTB сенсор был помечен `rotation = <270>` (из стокового `sensor-position-roll`), но поток с этого
модуля уже приходит прямым, и приложение поворачивало его второй раз — превью было боком.
Патч 0004 ставит `rotation = <0>`.

## Задняя камера: автофокуса нет

- libcamera simple-pipeline не реализует AF, поэтому привод не трогается.
- VCM доступен вручную: `/dev/v4l-subdev*` с именем `dw9719`, контрол `focus_absolute` (0…1023).
- Привод **запитан только во время стрима**: вне потока запись падает с `dw9719: Error writing reg
  0x0002: -6`, поэтому свипы фокуса нужно делать внутри одного потока (в кадре виден момент, когда
  привод получает питание).
- Свип по контрасту в потоке даёт пик около **focus ≈ 384**, но картинка остаётся мягкой — либо дистанция
  вне хода линзы, либо модуль просто мягкий. Метрика: средняя |вторая производная| по центральному кропу,
  нормированная на яркость.
- GUI: `plasma-camera` (KDE, через libcamera).

## Известные ограничения

- Цветопередача «зелёная» — следствие ненастроенного IPA (нет калибровочных tuning-файлов для этих
  сенсоров). Лечится сборкой tuning-данных, а не настройками.
- Задняя камера на 4–7 fps в 13 МП (столько успевает пайплайн), фронтальная — 30 fps.
