#!/bin/sh
# X11-греeter: ждём готовности X и поворачиваем выход под док
for _ in $(seq 1 30); do
    xrandr --query >/dev/null 2>&1 && break
    sleep 0.5
done
xrandr --output DSI-1 --rotate left 2>/dev/null || \
  xrandr --output DSI1 --rotate left 2>/dev/null || true
