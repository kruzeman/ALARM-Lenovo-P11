#!/bin/bash
# Разложить конфиги и сервисы в систему (запускать от root на планшете).
# Install the configs and services into the running system (run as root on the tablet).
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"

install -m644 "$HERE"/etc/systemd/system/j606f-*.service /etc/systemd/system/
install -m644 "$HERE"/etc/systemd/system/sddm-greeter-rotate.service /etc/systemd/system/
install -m755 "$HERE"/usr/local/bin/j606f-* /usr/local/bin/
install -m755 "$HERE"/usr/local/bin/mic-test.sh /usr/local/bin/ 2>/dev/null || true
install -m755 "$HERE"/usr/local/bin/sddm-greeter-rotate.sh /usr/local/bin/

install -Dm644 "$HERE/etc/wireplumber/wireplumber.conf.d/51-j606f-nommap.conf" \
	/etc/wireplumber/wireplumber.conf.d/51-j606f-nommap.conf
install -Dm644 "$HERE/etc/systemd/zram-generator.conf" /etc/systemd/zram-generator.conf
install -Dm644 "$HERE/etc/sysctl.d/99-zram.conf" /etc/sysctl.d/99-zram.conf
install -Dm644 "$HERE/etc/modules-load.d/j606f.conf" /etc/modules-load.d/j606f.conf
install -Dm644 "$HERE/etc/modprobe.d/j606f-audio.conf" /etc/modprobe.d/j606f-audio.conf
install -Dm644 "$HERE/ucm/Lenovo-TB-J606F.conf" \
	/usr/share/alsa/ucm2/conf.d/sm4250/Lenovo-TB-J606F.conf
install -Dm644 "$HERE/ucm/HiFi.conf" /usr/share/alsa/ucm2/Lenovo/TB-J606F/HiFi.conf

# SDDM: Wayland-greeter (KWin). Xorg не используется вообще.
install -Dm644 "$HERE/etc/sddm.conf.d/10-wayland.conf" /etc/sddm.conf.d/10-wayland.conf

systemctl daemon-reload
systemctl enable j606f-touch j606f-lid j606f-hid-resume upower bluetooth sddm sddm-greeter-rotate
systemctl set-default graphical.target

# Первичный поворот greeter'а (дальше его держит sddm-greeter-rotate.service)
/usr/local/bin/sddm-greeter-rotate.sh || true

echo "готово; перезагрузись и проверь systemctl --failed"
