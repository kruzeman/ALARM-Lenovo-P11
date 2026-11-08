#!/bin/bash
# /usr/local/bin/j606f-wifi-reprobe.sh
#
# ath10k_snoc (WCN3990) на этой платформе иногда не поднимается с первой попытки:
# прошивка/калибровка читаются через rmtfs из EFS, и если EFS-сервисы (rmtfs,
# tqftpserv) стартовали позже, чем пробился драйвер, wlan0 не появляется вовсе и
# сам не возвращается. Повторная загрузка модуля после того, как сервисы поднялись,
# всегда помогает.
set -u

have_wlan() {
	for i in /sys/class/net/*; do
		[ "$(basename "$i")" = lo ] && continue
		[ -e "$i/phy80211" ] && return 0
	done
	return 1
}

have_wlan && exit 0

# ждём EFS-сервисы до 40 секунд
for i in $(seq 1 40); do
	if systemctl is-active --quiet rmtfs && systemctl is-active --quiet tqftpserv; then
		break
	fi
	sleep 1
done

for attempt in 1 2 3; do
	modprobe -r ath10k_snoc ath10k_core 2>/dev/null
	sleep 1
	modprobe ath10k_snoc 2>/dev/null
	for i in $(seq 1 15); do
		have_wlan && exit 0
		sleep 1
	done
	echo "j606f-wifi-reprobe: попытка $attempt не дала wlan0"
done

exit 1
