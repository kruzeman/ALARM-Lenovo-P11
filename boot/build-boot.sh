#!/bin/bash
# Собрать Android boot image v2 для Lenovo TB-J606F.
#
#   ./build-boot.sh <Image.gz> <dtb> [mininit.img] [out.img]
#
# initramfs по умолчанию собирается из boot/mininit-init (статический busybox).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

KERNEL="${1:?Image.gz}"
DTB="${2:?dtb}"
RAMDISK="${3:-$HERE/mininit.img}"
OUT="${4:-$HERE/boot-arch.img}"

CMDLINE="console=tty0 fbcon=rotate:2 clk_ignore_unused pd_ignore_unused root=/dev/sda15 rw loglevel=7"

if [ ! -f "$RAMDISK" ]; then
	# initramfs: busybox (static) + init из boot/mininit-init
	command -v busybox >/dev/null || { echo "нужен busybox (pacman -S busybox)"; exit 1; }
	TMP="$(mktemp -d)"
	mkdir -p "$TMP/bin" "$TMP/dev" "$TMP/proc" "$TMP/sys"
	cp "$(command -v busybox)" "$TMP/bin/busybox"
	for applet in sh mount switch_root sleep mkdir echo; do
		ln -sf busybox "$TMP/bin/$applet"
	done
	install -m755 "$HERE/mininit-init" "$TMP/init"
	( cd "$TMP" && find . | cpio -o -H newc 2>/dev/null | gzip -9 ) > "$RAMDISK"
	rm -rf "$TMP"
	echo "initramfs: $RAMDISK"
fi

python3 "$HERE/mkboot.py" --ref "$HERE/stock.img" \
	--kernel "$KERNEL" --ramdisk "$RAMDISK" --dtb "$DTB" \
	--cmdline "$CMDLINE" --out "$OUT"

echo
echo "готово: $OUT"
echo "прошивка: fastboot flash boot_b $OUT && fastboot reboot"
