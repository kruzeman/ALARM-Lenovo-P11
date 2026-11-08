#!/bin/bash
# /usr/local/bin/j606f-usb-gadget.sh
#
# Резервный канал доступа: USB-NCM гаджет на 172.16.42.1.
# Нужен на случай, когда Wi-Fi после неудачной загрузки не поднимается и SSH по сети
# недоступен, а планшет при этом жив (кабель воткнут в ноутбук/ПК).
set -e

G=/sys/kernel/config/usb_gadget/j606f
modprobe libcomposite

if [ ! -d "$G" ]; then
	mkdir -p "$G"
	cd "$G"
	echo 0x1d6b > idVendor
	echo 0x0104 > idProduct
	mkdir -p strings/0x409
	echo "LENOVO" > strings/0x409/manufacturer
	echo "TB-J606F" > strings/0x409/product
	echo "0123456789" > strings/0x409/serialnumber
	mkdir -p configs/c.1/strings/0x409
	echo "ncm" > configs/c.1/strings/0x409/configuration
	mkdir -p functions/ncm.usb0
	ln -sf functions/ncm.usb0 configs/c.1/ 2>/dev/null || true
fi

# контроллер появляется не сразу после загрузки — ждём
for i in $(seq 1 30); do
	UDC=$(ls /sys/class/udc 2>/dev/null | head -1)
	[ -n "$UDC" ] && break
	sleep 1
done
[ -n "$UDC" ] || { echo "нет UDC, выходим"; exit 0; }

[ -e "$G/UDC" ] && [ "$(cat "$G/UDC" 2>/dev/null)" = "$UDC" ] || echo "$UDC" > "$G/UDC"

# адрес на usb0: профиль NetworkManager создаётся один раз и держится между загрузками
for i in $(seq 1 20); do
	ip link show usb0 >/dev/null 2>&1 && break
	sleep 1
done
if ip link show usb0 >/dev/null 2>&1; then
	ip link set usb0 up || true
	if ! nmcli -t -f NAME connection show 2>/dev/null | grep -qx "j606f-usb"; then
		nmcli connection add type ethernet ifname usb0 con-name j606f-usb \
			ipv4.method manual ipv4.addresses 172.16.42.1/24 \
			ipv4.route-metric 700 connection.autoconnect yes 2>/dev/null || true
	fi
	nmcli connection up j606f-usb 2>/dev/null || ip addr add 172.16.42.1/24 dev usb0 2>/dev/null || true
fi

echo "usb gadget готов: $(cat "$G/UDC" 2>/dev/null), $(ip -4 -o addr show usb0 2>/dev/null | awk '{print $4}')"
