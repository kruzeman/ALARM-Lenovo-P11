#!/usr/bin/env python3
"""Build an Android boot image (header v2) from explicit parts, cloning the layout
and load addresses of a reference image (the TB-J606F stock boot.img).

    python3 mkboot.py --ref stock.img --kernel vmlinuz --ramdisk initramfs.img \
        --dtb board.dtb --cmdline "console=tty0 root=UUID=... rw" --out boot.img

Header v2 (boot_img_hdr_v2) field offsets:
    0 magic, 8 kernel_size, 12 kernel_addr, 16 ramdisk_size, 20 ramdisk_addr,
    24 second_size, 28 second_addr, 32 tags_addr, 36 page_size, 40 header_version,
    44 os_version, 48 name[16], 64 cmdline[512], 576 id[8] (SHA1 in first 20),
    608 extra_cmdline[1024], 1632 recovery_dtbo_size, 1636 recovery_dtbo_offset,
    1644 header_size, 1648 dtb_size, 1652 dtb_addr.

The id is SHA1(kernel, ramdisk, second, recovery_dtbo), the way mkbootimg and the
port's own repacker compute it; ABL on this device does not check it, but keep it.
"""
import argparse
import hashlib
import struct


def pages(n, page):
    return (n + page - 1) // page * page


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ref", required=True)
    ap.add_argument("--kernel", required=True)
    ap.add_argument("--ramdisk", required=True)
    ap.add_argument("--dtb", required=True)
    ap.add_argument("--cmdline", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()

    ref = open(a.ref, "rb").read()
    if ref[:8] != b"ANDROID!":
        raise SystemExit("reference is not an Android boot image")
    hdr = ref[:4096]
    (_, kernel_addr, _, ramdisk_addr, _,
     second_addr, tags_addr, page, version, os_version) = struct.unpack_from("<10I", ref, 8)
    if version != 2:
        raise SystemExit("reference header v%d, only v2 supported" % version)
    dtb_addr, = struct.unpack_from("<Q", ref, 1652)
    cmdline = a.cmdline.encode()
    if len(cmdline) >= 512:
        raise SystemExit("cmdline too long (%d)" % len(cmdline))

    kernel = open(a.kernel, "rb").read()
    ramdisk = open(a.ramdisk, "rb").read()
    dtb = open(a.dtb, "rb").read()
    assert dtb[:4] == b"\xd0\x0d\xfe\xed", "dtb: bad magic"

    # id = SHA1 over each section followed by its length, exactly as the port's
    # bootimg_replace_dtb.py (and ABL, which rejects a mismatched id) expects.
    sha = hashlib.sha1()
    empty_dtbo = b""
    for blob in (kernel, ramdisk, b"", empty_dtbo):
        sha.update(blob)
        sha.update(struct.pack("<I", len(blob)))
    sha.update(dtb)
    sha.update(struct.pack("<I", len(dtb)))
    digest = sha.digest()

    h = bytearray(4096)
    h[0:8] = b"ANDROID!"
    struct.pack_into("<10I", h, 8, len(kernel), kernel_addr, len(ramdisk), ramdisk_addr,
                     0, second_addr, tags_addr, page, version, os_version)
    # name left empty, like the stock image
    h[64:64 + len(cmdline)] = cmdline
    h[576:576 + 20] = digest
    struct.pack_into("<I", h, 1632, 0)       # recovery_dtbo_size
    struct.pack_into("<Q", h, 1636, 0)       # recovery_dtbo_offset
    struct.pack_into("<I", h, 1644, 1660)    # header_size (sizeof boot_img_hdr_v2)
    struct.pack_into("<I", h, 1648, len(dtb))  # dtb_size
    struct.pack_into("<Q", h, 1652, dtb_addr)  # dtb_addr

    out = bytearray(h)
    for blob in (kernel, ramdisk, dtb):
        out += blob
        out += b"\0" * (pages(len(blob), page) - len(blob))
    open(a.out, "wb").write(out)
    print("kernel %d, ramdisk %d, dtb %d, cmdline %d chars, total %d -> %s"
          % (len(kernel), len(ramdisk), len(dtb), len(cmdline), len(out), a.out))


if __name__ == "__main__":
    main()
