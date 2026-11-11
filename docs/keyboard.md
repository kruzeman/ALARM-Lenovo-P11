# Keyboard (Lenovo pogo keyboard, TB-J606F)

The tablet's detachable keyboard is a HID device over I2C: `17EF:6103`, exposed as `event3`
(`hid-over-i2c 17EF:6103 Keyboard`). It has **no F-row and no Escape key** — but its HID descriptor does declare
F1-F24 and Esc, so the kernel will happily deliver those codes if something generates them.

## What the globe key actually sends

The language-switch ("globe") key is not a normal key: it reports

```
Event: type 4 (EV_MSC), code 4 (MSC_SCAN), value c0390
Event: type 1 (EV_KEY), code 240 (KEY_UNKNOWN), value 1
```

i.e. scancode `0xc0390` mapped to `KEY_UNKNOWN` (240). Nothing in userspace reacts to that, so the key is dead.

## Remapping: globe becomes Fn

Two layers, both below XKB, so they work in the console and in KDE alike.

1. **udev hwdb** — turn the dead scancode into `F13`:

```
# /etc/udev/hwdb.d/90-j606f-keyboard.hwdb
evdev:name:hid-over-i2c 17EF:6103 Keyboard:*
 KEYBOARD_KEY_c0390=f13
```

2. **keyd** — use `F13` as a held layer:

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

Install and enable:

```sh
pacman -S keyd
systemd-hwdb update
udevadm trigger --subsystem-match=input
systemctl enable --now keyd
```

## Verified mapping

Captured from the `keyd virtual keyboard` device while pressing the combinations:

```
59 KEY_F1        globe + 1
60 KEY_F2        globe + 2
29 KEY_LEFTCTRL  CapsLock held
1  KEY_ESC       CapsLock tapped
```

So: **globe = Fn**, `Fn+1..0` = `F1..F10`, `Fn+-`/`Fn+=` = `F11`/`F12`, `Fn+Backspace` = `Delete`,
and the **Android "back" button = `Esc`** — it sends `KEY_BACK`, which keyd turns into Escape. CapsLock is left
untouched (an earlier attempt bound Esc to a CapsLock overload; that was rejected in favour of the back button).

## Changing it

Edit `/etc/keyd/default.conf` and run `keyd reload`. If keyd ever misbehaves, `systemctl stop keyd` restores the
raw keyboard immediately (the hwdb remap only changes the globe key, which was dead anyway).

To find a key that does nothing yet, run `evtest /dev/input/event3`, press it, and read the `MSC_SCAN` value.
