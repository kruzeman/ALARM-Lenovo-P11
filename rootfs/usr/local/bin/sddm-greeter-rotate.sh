#!/bin/bash
# Greeter SDDM работает на kwin_wayland; его kwinoutputconfig.json KWin может
# перезаписать, если не находит EDID у панели. Поэтому поворот применяем ещё раз
# после старта greeter'а (идемпотентно).
UID_SDDM=$(id -u sddm)
SOCK=/run/user/$UID_SDDM/wayland-0
for _ in $(seq 1 40); do [ -S "$SOCK" ] && break; sleep 1; done
sleep 3
sudo -u sddm env XDG_RUNTIME_DIR=/run/user/$UID_SDDM WAYLAND_DISPLAY=wayland-0 \
  DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$UID_SDDM/bus \
  kscreen-doctor output.DSI-1.rotation.left >/dev/null 2>&1
exit 0
