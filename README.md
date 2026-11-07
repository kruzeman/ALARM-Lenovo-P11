# Arch Linux ARM на Lenovo Tab P11 (TB-J606F)

Собственный набор для запуска **Arch Linux ARM** на планшете **Lenovo Tab P11 TB-J606F**
(Qualcomm Snapdragon 662 / SM6115 «bengal», 4 ГБ ОЗУ, панель 1200×2000, пого-док с клавиатурой и тачпадом).

Основа — mainline-порт [sm61x5-mainline/linux](https://codeberg.org/sm61x5-mainline/linux) (тег `v7.2.3-r0`)
и наработки [Yar1klamer/j606f-postmarketos](https://github.com/Yar1klamer/j606f-postmarketos).
Здесь лежит то, что сделано поверх: собственные патчи ядра, драйвер кодека ES7210, правки DTB,
libcamera-патч для камер, минимальный initramfs, конфиги и сервисы для Arch.

## Что работает

| Устройство | Статус | Комментарий |
|---|---|---|
| Загрузка (A/B, `boot_b`) | ✅ | своё ядро `7.2.3-sm61x5-hermes`, минимальный initramfs |
| Экран (Himax HX83102P, DSI) | ✅ | яркость через `/sys/class/backlight`, панель смонтирована «вверх ногами» (`rotation = 180`) |
| Тачскрин (Himax HX83102E) | ✅ | нужны `rmtfs`, `tqftpserv`, `pd-mapper`; сервис `j606f-touch` |
| Пого-док: клавиатура и тачпад | ✅ | `hid-over-i2c`, IRQ GPIO 93/96; переподключение после сна — `j606f-hid-resume` |
| Wi-Fi (WCN3990 / ath10k_snoc) | ✅ | нужны `qrtr`, `rmtfs`, `tqftpserv`, `pd-mapper` |
| Bluetooth (QCA) | ✅ | стабильный BD-адрес задаётся в DTB (`local-bd-address`) |
| Динамики (4× AW88258) | ✅ | PRIMARY_TDM_RX_0, стерео, UCM-профиль |
| Разъём USB-C / гарнитура | ⚠️ | WCD937x + SoundWire поднимаются, но аналоговый выход идёт через FSA4480 — не реализовано |
| Камеры (OV13B10 + S5K4H7) | ⚠️ | обе снимают; фронтальная повёрнута правильно (после правки DTB), задняя без автофокуса |
| Встроенные микрофоны (ES7210) | ❌ | драйвер кодека готов, DSP отвергает TDM-TX порт (`-22`), см. `docs/audio.md` |
| Сон (`s2idle`) | ✅ | пробуждение по Power; сон по закрытию чехла — `j606f-lid` (Hall-сенсор, gpiochip0 36) |
| Автоповорот | ✅ | демон `j606f-autorotate` поверх `ssccli` (SSC/ADSP) |
| Датчик света | ✅ | LTR578 через SSC, `iio-sensor-proxy` видит `HasAmbientLight` |
| Батарея | ✅ | `mm8013` + `upower` |
| zram | ✅ | `zram-generator`, zstd, `ram / 2` |

## Что лежит в репозитории

```
kernel/patches/     патчи к дереву sm61x5-mainline/linux (v7.2.3-r0)
  0001-…            DTB: аудио (ES7210 + TDM TX) и BD-адрес Bluetooth
  0002-…            sm8250.c: capture-линк на PRIMARY_TDM_TX_0
  0003-…            драйвер кодека ES7210 (sound/soc/codecs/es7210.c)
  0004-…            DTB: поворот фронтальной камеры
boot/               сборка boot-образа (mkboot.py) и минимальный initramfs
rootfs/             файлы для системы: systemd-сервисы, UCM, конфиги WirePlumber/zram,
                    скрипты (автоповорот, переподключение HID, тест микрофона)
libcamera/          патч libcamera 0.7.2: sensor helper'ы для OV13B10 и S5K4H7 (работает АЭ)
tools/              утилиты для DTB: patch_dts.py, fdtread.py
docs/               подробности по каждому узлу
```

## Готовый образ

В [releases](../../releases) лежит проверенный boot-образ (`boot-arch-j606f-good.img`):
звук (динамики), Wi-Fi, Bluetooth, тач, пого-док, камеры, сон и автоповорот работают,
микрофоны ES7210 выключены. Прошивка: `fastboot flash boot_b boot-arch-j606f-good.img`.

## Быстрый старт

1. Прочитать `docs/install.md` — там разметка разделов, сборка образа и первый запуск.
2. Собрать ядро и DTB:
   ```bash
   git clone --depth 1 --branch v7.2.3-r0 https://codeberg.org/sm61x5-mainline/linux.git
   cd linux
   for p in /path/to/repo/kernel/patches/*.patch; do git apply "$p"; done
   make ARCH=arm64 LLVM=1 KERNELRELEASE=7.2.3-sm61x5-hermes -j$(nproc) Image.gz modules dtbs
   ```
3. Собрать boot-образ: `boot/build-boot.sh` (нужны `Image.gz`, `dtb`, initramfs).
4. Скопировать `rootfs/*` в систему, включить сервисы (`docs/install.md`).

## Известные проблемы

- **Микрофоны**: DSP отвечает `AFE enable for port 0x9001 failed -22` на любой конфигурации порта
  (2/4 канала, маски `0x3`/`0xF`, с картой каналов и без). Нужно сверять таблицу AFE-портов прошивки ADSP
  и проверять, не висят ли микрофоны на второй шине LPI I2S2 (`lpi_i2s2_*` в стоковом DTB).
- **Задняя камера**: автофокуса нет (libcamera simple-pipeline не умеет AF для этого сенсора);
  VCM `dw9719` управляется вручную через `/dev/v4l-subdev*` (`focus_absolute`), но привод запитан только
  во время стрима.
- **USB-C аналоговый звук**: нужен драйвер FSA4480.
- **`power_supply` oops**: в этом ядре иногда возникает `Internal error: Oops - CFI` в
  `power_supply_changed_work` (батарея/зарядка) — к аудио и камерам отношения не имеет, но может подвесить
  систему; лечится перезагрузкой.

## Благодарности

- [sm61x5-mainline](https://codeberg.org/sm61x5-mainline/linux) — mainline-порт для SM6115/SM4250.
- [Yar1klamer/j606f-postmarketos](https://github.com/Yar1klamer/j606f-postmarketos) — первоначальный порт
  для этого планшета (DTB, драйверы усилителей, документация по железу).
- Команде libcamera — за простой пайплайн и понятный код сенсорных хелперов.
