# Установка

Всё делалось на самом планшете (Arch ARM ставится в раздел `userdata`), загрузчик — штатный ABL.
`boot_b` содержит наш boot-образ, Android не нужен.

## 1. Разметка

| Раздел | Устройство | Что там |
|---|---|---|
| `userdata` | `/dev/sda15` (label `archroot`) | корень Arch Linux ARM, ext4 |
| `boot_b` | `/dev/disk/by-partlabel/boot_b` | наш boot-образ (v2) |
| `persist` | `/dev/sda2` | сенсоры/калибровки — **не трогать** |
| `dsp_b` | `/dev/sde29` | прошивка ADSP — **не трогать** |

Резервные копии `boot_b` перед экспериментами обязательны: `fastboot` — единственный способ
восстановиться, если образ не загрузится.

## 2. Корневая система

```bash
# на планшете, из recovery/fastboot-boot окружения или с другого хоста
mkfs.ext4 -L archroot /dev/sda15
mount /dev/sda15 /mnt
tar -xpf ArchLinuxARM-aarch64-latest.tar.gz -C /mnt
```

Дальше — обычная настройка Arch (ключи pacman, `NetworkManager`, `openssh`, пользователь, `sudo`),
плюс пакеты, без которых не работают узлы:

```bash
pacman -S --needed base-devel openssh networkmanager sudo nano vim htop \
  mesa plasma-meta plasma-login-manager bluez bluez-utils upower zram-generator \
  libcamera libcamera-tools plasma-camera epiphany \
  gst-plugins-base gst-plugins-good gst-plugins-bad gst-libav
# AUR: qrtr rmtfs tqftpserv pd-mapper hexagonrpcd
```

`qrtr`, `rmtfs`, `tqftpserv`, `pd-mapper` обязательны: без них не поднимаются Wi-Fi, тачскрин и часть
ADSP-периферии.

## 3. Ядро

```bash
git clone --depth 1 --branch v7.2.3-r0 https://codeberg.org/sm61x5-mainline/linux.git
cd linux
for p in /path/to/repo/kernel/patches/*.patch; do git apply "$p"; done
cp /path/to/config-nura-qcom-sm61x5.aarch64 .config
make ARCH=arm64 LLVM=1 olddefconfig
make ARCH=arm64 LLVM=1 KERNELRELEASE=7.2.3-sm61x5-hermes -j$(nproc) Image.gz modules dtbs
make ARCH=arm64 LLVM=1 KERNELRELEASE=7.2.3-sm61x5-hermes modules_install
depmod -a 7.2.3-sm61x5-hermes
```

`KERNELRELEASE` нужен, чтобы каталог модулей совпадал с `uname -r` (localversion в `.config` при этом
перекрывается).

## 4. initramfs и boot-образ

Минимальный initramfs — статический busybox, который монтирует корень и делает `switch_root`
(`boot/mininit-init`):

```
mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev
mount /dev/sda15 /newroot
exec switch_root /newroot /sbin/init
```

Образ собирается `boot/mkboot.py` (Android boot image v2):

```bash
python3 boot/mkboot.py --ref stock.img \
  --kernel arch/arm64/boot/Image.gz \
  --ramdisk mininit.img \
  --dtb arch/arm64/boot/dts/qcom/sm6115p-lenovo-j606f-hx83102p.dtb \
  --cmdline "console=tty0 fbcon=rotate:2 clk_ignore_unused pd_ignore_unused root=/dev/sda15 rw loglevel=7" \
  --out boot-arch.img
```

Прошивка (с ноутбука, планшет в fastboot — Power ~15 с, затем Громкость− + Power):

```bash
fastboot flash boot_b boot-arch.img
fastboot reboot
```

## 5. После первого запуска

```bash
# сервисы из rootfs/
install -m644 rootfs/etc/systemd/system/j606f-*.service /etc/systemd/system/
install -m755 rootfs/usr/local/bin/j606f-* /usr/local/bin/
install -Dm644 rootfs/etc/wireplumber/wireplumber.conf.d/51-j606f-nommap.conf \
  /etc/wireplumber/wireplumber.conf.d/51-j606f-nommap.conf
install -Dm644 rootfs/etc/systemd/zram-generator.conf /etc/systemd/zram-generator.conf
install -Dm644 rootfs/etc/sysctl.d/99-zram.conf /etc/sysctl.d/99-zram.conf
install -Dm644 rootfs/etc/modules-load.d/j606f.conf /etc/modules-load.d/j606f.conf
install -Dm644 rootfs/ucm/Lenovo-TB-J606F.conf /usr/share/alsa/ucm2/conf.d/sm4250/Lenovo-TB-J606F.conf
install -Dm644 rootfs/ucm/HiFi.conf /usr/share/alsa/ucm2/Lenovo/TB-J606F/HiFi.conf

systemctl enable j606f-touch j606f-lid j606f-hid-resume upower bluetooth sddm
systemctl set-default graphical.target
```

## Опционально: тюнинг рабочего стола

`rootfs/usr/local/bin/j606f-kde-tune.sh` (запускать от имени пользователя) отключает тяжёлые эффекты
KWin и индексатор Baloo; замеры — в `docs/performance.md`, `docs/ru/performance.md`.

## Если планшет не загрузился

Симптомы — чёрный экран, «буковки», бесконечная перезагрузка. Действия:

1. Выключить (Power ~15 с), зайти в fastboot (Громкость− + Power).
2. Прошить последний рабочий образ: `fastboot flash boot_b good.img && fastboot reboot`.
3. Не пытаться «переждать» цикл перезагрузок — только возврат образа.

Проверенный порядок отладки: сначала загрузиться с рабочим DTB, потом менять один узел за раз и
сравнивать `dtc -I dtb -O dts` старого и нового дерева (см. `tools/patch_dts.py`).

## Экран входа (Plasma Login Manager, автологин)

`plasma-login-manager` (служба `plasmalogin`) заменил SDDM. От SDDM пришлось уйти из-за нестабильного
Wayland-греeter'а: `kwin_wayland`, запущенный под пользователем `sddm`, писал
`kwin_core: Failed to take control of ... session. Maybe another compositor is running?`, падал с `SEGV`, а
после перезапусков оставались висеть сессии, держащие DRM-мастер, и следующий вход зависал после пароля
(`startplasma-wayland` стартовал, `plasmashell` не появлялся). Обходным путём был Xorg-греeter с `xrandr`;
с plasmalogin воевать не с кем — устройство сразу автологинится в Wayland-сессию, а поворот берётся из
сохранённой конфигурации выхода.

`rootfs/etc/plasmalogin.conf.d/10-autologin.conf`:

```ini
[Autologin]
User=user
Session=plasma.desktop
Relogin=false
```

Дальше:

```bash
systemctl disable sddm
systemctl enable plasmalogin      # перевесит симлинк display-manager.service
```

Проверено после перезагрузки: `plasmalogin` активен, `sddm` выключен, сессия пользователя на tty1,
`kwin_wayland` работает, поворот и автояркость на месте, Wi-Fi ассоциировался. Старые файлы SDDM
(`rootfs/etc/sddm.conf.d/20-x11.conf` и `rootfs/usr/local/bin/sddm-x11-rotate.sh`) оставлены только как путь
назад; им нужен пакет `xorg-xrandr`.

## Пого-док: клавиатура и тачпад

Lenovo Keyboard Pack поднимает два независимых клиента HID-over-I2C: клавиатуру на `i2c1` 0x61
(`17EF:6103`) и тачпад Elan на `i2c0` 0x60 (`04F3:3164`, им занимается `hid-multitouch`). Клавиатуре хватает
`post-power-on-delay-ms = <100>`, а тачпаду нет: при 100 мс ядро читает битый дескриптор отчётов
(`unknown main item tag 0x0`, `collection stack underflow`, `item 0 0 0 12 parsing failed`,
`probe with driver hid-multitouch failed with error -22`), устройство ввода не появляется, а MCU после
этого засыпает, и последующий unbind/bind отвечает `GPI transfer failed: -5`. 400 мс в узле `touchpad@60`
достаточно — тачпад работает. Если он снова замолчит: передёрнуть док и перезагрузиться, дескриптор
читается один раз, при пробе.

## Сторож Wi-Fi: включать не нужно

`ath10k_snoc` (WCN3990) действительно умеет терять `wlan0`, но перепривязка драйвера «на всякий случай»
делает только хуже. `j606f-wifi-watchdog.timer` (раз в минуту проверяет наличие беспроводного интерфейса и
при его отсутствии перезагружает драйвер) мы попробовали и **испортили каждую загрузку**: при нормальном
старте `wlan0` появляется через несколько секунд после рукопожатия прошивки WCN3990, а таймер срабатывал
раньше и выгружал `ath10k_snoc` прямо внутри `ath10k_qmi_driver_event_work`. В журнале появлялось

    WARNING: lib/radix-tree.c:572 at delete_node+0x2b4/0x2c8
    Workqueue: ath10k_qmi_driver_event ath10k_qmi_driver_event_work [ath10k_snoc]

после чего WLAN-сервис на ADSP оставался мёртвым: ни `wlan0`, ни даже `host capability request rejected` —
просто ничего, до полного снятия питания. Поэтому `j606f-wifi-watchdog.timer` и
`j606f-wifi-reprobe.service` по умолчанию отключены; если Wi-Fi действительно пропал, выключай планшет
полностью (удержанием кнопки), а не перезагружай драйвер в рантайме.

## Зависание: `CFI failure at notifier_call_chain`

Симптом: планшет замирает через некоторое время после загрузки (часто сразу после входа), экран не
реагирует, `sshd` принимает TCP, но баннер не отдаёт, помогает только сброс питания. В журнале той
загрузки:

```
CFI failure at notifier_call_chain+0x98/0x1d8
  (target: himax_GESTURE_write+0x124/0x1e8 [himax_hx83102e]; expected type: 0xd5127a3b)
Internal error: Oops - CFI
```

Причина — в драйвере тачскрина порта, а не в той подсистеме, которую в этот момент тестировали:
`himax_chip_common_init()` регистрирует `power_supply`-notifier при включённом `HX_USB_DETECT_GLOBAL`, а
`himax_chip_common_deinit()` его не отписывает. Порт перезагружает модуль при загрузке (`j606f-touch`,
чтобы выиграть гонку пробе TDDI), поэтому старый notifier остаётся в глобальной цепочке и указывает в
освобождённую память модуля; первое событие питания вызывает его — и CFI роняет ядро. Патч
`kernel/patches/0008-himax-unregister-power-supply-notifier.patch` отписывает notifier, уничтожает его
workqueue и освобождает контейнер в deinit. Проверка после перезагрузки модуля:
`dmesg | grep -cE "CFI failure|Oops"` должен дать 0, а в `/proc/bus/input/devices` остаётся
`himax-touchscreen`.

## Поток `Handover signaled, but it already happened`

Вендорский `adsp.mbn` повторно выставляет SMP2P-элемент `handover` после первого handover (~2 раза в
секунду на этом устройстве), и `q6v5_handover_interrupt()` писал на каждое срабатывание сообщение
уровня error. Вреда нет — звук, Wi-Fi и зарядка работают, — но `dmesg` заполняется за минуты и прячет
настоящие ошибки; вариант с `dev_err_ratelimited` на этом ядре не сработал. Патч
`kernel/patches/0009-remoteproc-quiet-handover-warning.patch` переводит сообщение в `dev_dbg`.

## Профили производительности (`power-saver` / `balanced` / `performance`)

Plasma не показывает переключатель профилей: в Arch Linux ARM нет пакета `power-profiles-daemon`, а на SoC
нет ACPI `platform_profile` — PowerDevil просто не с кем разговаривать. Эту нишу занимает
`j606f-power-profiles`: он владеет системным шинным именем `org.freedesktop.UPower.PowerProfiles` и
реализует API, которым пользуется Plasma 6 — `ActiveProfile`, `Profiles` и пару
`HoldProfile`/`ReleaseProfile`, которую PowerDevil держит, пока запущена игра.

Маппинг на то, что есть у sm6115 (`performance` и `schedutil`, 300 МГц–2.016 ГГц):

- `power-saver` — `schedutil`, потолок 1.4 ГГц на обоих кластерах;
- `balanced` — `schedutil`, полный диапазон;
- `performance` — governor `performance`, полный диапазон.

Две детали, которые стоили времени: сервису нужен policy-файл D-Bus
(`rootfs/usr/share/dbus-1/system.d/org.freedesktop.UPower.PowerProfiles.conf`), иначе любой вызов
отвечает `Access denied`, хотя свойства читаются; и в элементах `Profiles` нужны оба набора ключей —
`profile`/`driver` и `Profile`/`Driver`, с одними строчными PowerDevil показывает три профиля с пустыми
именами.

Проверено через `busctl`: `profileChoices` отдаёт `power-saver balanced performance`, `setProfile
performance` переключает governor на `performance`, `HoldProfile`/`ReleaseProfile` перекрывают и
возвращают выбранный вручную профиль.
