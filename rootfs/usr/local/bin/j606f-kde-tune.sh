#!/bin/bash
# j606f-kde-tune — отключить тяжёлые эффекты KWin и индексатор Baloo.
# Запускать ОТ ИМЕНИ ПОЛЬЗОВАТЕЛЯ рабочего стола (не root), один раз.
#
#   ./j606f-kde-tune.sh
#
# Обратная операция: те же ключи со значением true и `balooctl6 enable`.
set -e

if [ "$(id -u)" -eq 0 ]; then
	echo "Запусти от имени пользователя рабочего стола, не root." >&2
	exit 1
fi

echo "== Baloo: выключаем индексатор"
balooctl6 disable 2>/dev/null || echo "  (balooctl6 не найден — пропускаем)"

echo "== KWin: отключаем тяжёлые эффекты"
for eff in blur contrast diminactive slidingpopups fadingpopups magiclamp scale \
           kwin4_effect_translucency kwin4_effect_fade kwin4_effect_scale; do
	kwriteconfig6 --file kwinrc --group Plugins --key "${eff}Enabled" false 2>/dev/null || true
done

echo "== Ускоряем оставшиеся анимации вдвое"
kwriteconfig6 --file kdeglobals --group KDE --key AnimationDurationFactor 0.5 2>/dev/null || true

echo "== Перечитываем конфиг KWin"
dbus-send --session --print-reply --dest=org.kde.KWin /KWin org.kde.KWin.reconfigure >/dev/null 2>&1 ||
	qdbus6 org.kde.KWin /KWin reconfigure >/dev/null 2>&1 ||
	echo "  (не удалось — эффекты применятся после повторного входа)"

echo "готово"
