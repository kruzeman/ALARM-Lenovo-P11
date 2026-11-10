#!/bin/sh
# Глубокое состояние простоя (cpu-sleep-0-0) вешает процессор в
# cpuidle_enter_s2idle: при уходе в s2idle ядро ловит hard LOCKUP и планшет
# не просыпается. Оставляем только WFI (state0) — батарея в простое тратится
# немного быстрее, зато сон и пробуждение работают.
set -e
for d in /sys/devices/system/cpu/cpu[0-9]*/cpuidle/state[1-9]/disable; do
    [ -w "$d" ] && echo 1 > "$d"
done
exit 0
