#!/bin/bash
# Разложить конфиги и сервисы в систему (запускать от root на планшете).
# Install the configs and services into the running system (run as root on the tablet).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"

install -m644 "$HERE"/etc/systemd/system/j606f-*.service /etc/systemd/system/
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

systemctl daemon-reload
systemctl enable j606f-touch j606f-lid j606f-hid-resume upower bluetooth sddm
systemctl set-default graphical.target

echo "готово; перезагрузись и проверь systemctl --failed"
