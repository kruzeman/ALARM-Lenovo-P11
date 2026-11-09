#!/bin/bash
# /usr/local/bin/j606f-wifi-watchdog.sh
#
# ath10k_snoc (WCN3990) на этой платформе умеет терять wlan0 не только на
# загрузке, но и в работе: интерфейс пропадает целиком, NetworkManager видит
# пустоту, и сам драйвер не возвращается. Сторож проверяет наличие
# беспроводного интерфейса раз в минуту и при его отсутствии перепривязывает
# драйвер (j606f-wifi-reprobe.sh), а если интерфейс есть, но лежит down —
# просто поднимает линк.
set -u

log() { echo "j606f-wifi-watchdog: $*"; }

wlan_ifaces() {
	for i in /sys/class/net/*; do
		[ "$(basename "$i")" = lo ] && continue
		[ -e "$i/phy80211" ] && echo "$(basename "$i")"
	done
}

ifs=$(wlan_ifaces)

if [ -n "$ifs" ]; then
	for n in $ifs; do
		if [ "$(cat /sys/class/net/$n/operstate 2>/dev/null)" = "down" ]; then
			log "$n down — поднимаю линк"
			ip link set "$n" up 2>/dev/null
		fi
	done
	exit 0
fi

log "беспроводного интерфейса нет — перепривязываю ath10k_snoc"
systemctl stop NetworkManager 2>/dev/null
/usr/local/bin/j606f-wifi-reprobe.sh
rc=$?
systemctl start NetworkManager 2>/dev/null
[ $rc -ne 0 ] && log "перепривязка не дала wlan0"
exit 0
