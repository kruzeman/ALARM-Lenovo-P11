# Клавиатура (съёмная клавиатура Lenovo, TB-J606F)

Клавиатура планшета — HID-устройство на I2C: `17EF:6103`, в системе видна как `event3`
(`hid-over-i2c 17EF:6103 Keyboard`). В ней **нет ряда F-клавиш и нет Escape**, хотя дескриптор HID эти коды
объявляет — то есть ядро готово их отдать, если их кто-то сгенерирует.

## Что на самом деле присылает кнопка «глобус»

Кнопка переключения языка — не обычная клавиша, она отдаёт

```
Event: type 4 (EV_MSC), code 4 (MSC_SCAN), value c0390
Event: type 1 (EV_KEY), code 240 (KEY_UNKNOWN), value 1
```

то есть scancode `0xc0390` в `KEY_UNKNOWN` (240). В userspace на это никто не реагирует — клавиша мёртвая.

## Переназначение: «глобус» становится Fn

Два слоя, оба ниже XKB, поэтому работают и в консоли, и в KDE.

1. **udev hwdb** — превращаем мёртвый scancode в `F13`:

```
# /etc/udev/hwdb.d/90-j606f-keyboard.hwdb
evdev:name:hid-over-i2c 17EF:6103 Keyboard:*
 KEYBOARD_KEY_c0390=f13
```

2. **keyd** — используем `F13` как удерживаемый слой:

```
# /etc/keyd/default.conf
[ids]
17ef:6103

[main]
f13 = layer(fn)
back = esc

[fn]
1 = f1
2 = f2
...
0 = f10
minus = f11
equal = f12
backspace = delete
```

Установка и включение:

```sh
pacman -S keyd
systemd-hwdb update
udevadm trigger --subsystem-match=input
systemctl enable --now keyd
```

## Проверенное соответствие

Снято с устройства `keyd virtual keyboard` при нажатии комбинаций:

```
59 KEY_F1        глобус + 1
60 KEY_F2        глобус + 2
29 KEY_LEFTCTRL  CapsLock удерживается
1  KEY_ESC       CapsLock нажат коротко
```

Итого: **«глобус» = Fn**, `Fn+1..0` = `F1..F10`, `Fn+-`/`Fn+=` = `F11`/`F12`, `Fn+Backspace` = `Delete`,
а **андроидная кнопка «назад» = `Esc`** — она присылает `KEY_BACK`, и keyd превращает его в Escape. CapsLock
не тронут (первый вариант вешал Esc на него через overload — от него отказались в пользу «назад»).

## Как менять

Правится `/etc/keyd/default.conf`, применяется `keyd reload`. Если keyd начнёт мешать — `systemctl stop keyd`
сразу возвращает «сырую» клавиатуру (hwdb-правка трогает только мёртвую кнопку «глобус»).

Чтобы найти ещё не занятую клавишу: `evtest /dev/input/event3`, нажать её и посмотреть значение `MSC_SCAN`.
