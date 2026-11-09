#!/bin/bash
# Разложить конфиги и сервисы в систему (запускать от root на планшете).
# Install the configs and services into the running system (run as root on the tablet).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"

install -m644 "$HERE"/etc/systemd/system/j606f-*.service /etc/systemd/system/
install -Dm644 "$HERE"/etc/plasmalogin.conf.d/10-autologin.conf /etc/plasmalogin.conf.d/10-autologin.conf
install -Dm644 "$HERE"/usr/share/dbus-1/system.d/org.freedesktop.UPower.PowerProfiles.conf \
    /usr/share/dbus-1/system.d/org.freedesktop.UPower.PowerProfiles.conf
install -m755 "$HERE"/usr/local/bin/j606f-* /usr/local/bin/
install -m755 "$HERE"/usr/local/bin/mic-test.sh /usr/local/bin/ 2>/dev/null || true
install -m755 "$HERE"/usr/local/bin/sddm-x11-rotate.sh /usr/local/bin/

install -Dm644 "$HERE/etc/wireplumber/wireplumber.conf.d/51-j606f-nommap.conf" \
	/etc/wireplumber/wireplumber.conf.d/51-j606f-nommap.conf
install -Dm644 "$HERE/etc/systemd/zram-generator.conf" /etc/systemd/zram-generator.conf
install -Dm644 "$HERE/etc/sysctl.d/99-zram.conf" /etc/sysctl.d/99-zram.conf
install -Dm644 "$HERE/etc/modules-load.d/j606f.conf" /etc/modules-load.d/j606f.conf
install -Dm644 "$HERE/etc/modprobe.d/j606f-audio.conf" /etc/modprobe.d/j606f-audio.conf
install -Dm644 "$HERE/ucm/Lenovo-TB-J606F.conf" \
	/usr/share/alsa/ucm2/conf.d/sm4250/Lenovo-TB-J606F.conf
install -Dm644 "$HERE/ucm/HiFi.conf" /usr/share/alsa/ucm2/Lenovo/TB-J606F/HiFi.conf

# SDDM: greeter — X11 (Xorg), рабочий стол — Wayland.
# Wayland-греeter (kwin_wayland под sddm) на этом устройстве нестабилен: падает с SEGV и оставляет
# висящие сессии, из-за которых вход зависает. Для X11-греeter'а нужен пакет xorg-xrandr.
install -Dm644 "$HERE/etc/sddm.conf.d/20-x11.conf" /etc/sddm.conf.d/20-x11.conf

# Чехол: крышку обрабатывает не logind (иначе цикл «уснул-проснулся»), а j606f-lid.service
# с задержкой 3 с; хук сна отвязывает устройства, которые срывают s2idle.
install -Dm644 "$HERE/etc/systemd/logind.conf.d/10-j606f-lid.conf" \
	/etc/systemd/logind.conf.d/10-j606f-lid.conf
install -Dm755 "$HERE/usr/lib/systemd/system-sleep/50-j606f-resume" \
	/usr/lib/systemd/system-sleep/50-j606f-resume
# upowerd упирается в таймауты I2C при старте и не успевает в штатные 90 с —
# без запаса systemd убивает его вместе с plasmashell/powerdevil.
install -Dm644 "$HERE/etc/systemd/system/upower.service.d/10-j606f-timeout.conf" \
	/etc/systemd/system/upower.service.d/10-j606f-timeout.conf

# Резервный доступ по USB (172.16.42.1) и повторный подъём Wi-Fi, если адаптер
# не появился на загрузке: оба случая реально приводили к потере связи с планшетом.
install -m755 "$HERE/usr/local/bin/j606f-usb-gadget.sh" /usr/local/bin/
install -m755 "$HERE/usr/local/bin/j606f-wifi-reprobe.sh" /usr/local/bin/
install -Dm644 "$HERE/etc/systemd/system/j606f-usb-gadget.service" /etc/systemd/system/j606f-usb-gadget.service
install -Dm644 "$HERE/etc/systemd/system/j606f-wifi-reprobe.service" /etc/systemd/system/j606f-wifi-reprobe.service

systemctl daemon-reload
systemctl enable j606f-touch j606f-lid j606f-hid-resume j606f-usb-gadget upower bluetooth plasmalogin
systemctl enable j606f-power-profiles
# j606f-wifi-reprobe и j606f-wifi-watchdog НЕ включаем: перепривязка ath10k_snoc
# в рантайме рвёт инициализацию WCN3990 (radix-tree WARNING в
# ath10k_qmi_driver_event_work) и после этого WLAN-сервис ADSP не поднимается
# до полного снятия питания. Скрипты остаются на месте для ручного запуска.
systemctl disable j606f-wifi-reprobe j606f-wifi-watchdog.timer 2>/dev/null || true
# j606f-sensor-proxy ставится, но не включается: он требует карты sensor_pd
# (adsps.jsn) и на этом устройстве ADSP уходит в handover-loop — включать
# только осознанно, см. docs/sensors.md.
systemctl disable sddm 2>/dev/null || true
# iio-sensor-proxy на этом планшете не получает сэмплов от libssc 0.4.x, но
# захватывает датчик; данные в net.hadess.SensorProxy отдаёт j606f-sensor-proxy.
# disable не помогает: iio-sensor-proxy поднимается по D-Bus-активации и первым
# занимает net.hadess.SensorProxy, поэтому маскируем его.
systemctl mask --now iio-sensor-proxy 2>/dev/null || true
systemctl set-default graphical.target

echo "готово; перезагрузись и проверь systemctl --failed"
