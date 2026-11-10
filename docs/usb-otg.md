# USB-C OTG (host mode) — state on 2026-11-10

Goal: a USB Wi-Fi adapter plugged into the port should enumerate.

What works:
- The board DTS (`sm6115p-lenovo-j606f-hx83102p.dts` — the one this SKU needs; the base
  `sm6115p-lenovo-j606f.dts` has no `usb-role-switch` and no Himax panel) already wires the FUSB302 at
  `i2c0 0x22` to `usb_dwc3` through a role switch, `dr_mode = "otg"`, high speed only.
- Writing `host` to `/sys/class/usb_role/4e00000.usb-role-switch/role` does bring up xHCI:
  `usb1`/`usb2` root hubs appear, `ls /sys/bus/usb/devices/` shows the two buses.

What does not work:
- **VBUS never turns on.** GPIO 38, which enables the external 5 V boost (`usb_otg_vbus`, the stock "dock_pogo
  usb_vbus" line), stays `out low`, so the adapter gets no power and nothing enumerates. Plugging a device produces
  no dmesg lines at all: TCPM does not report a connection, and per the reference patch TCPM is what enables the
  regulator — only after it sees Rd on CC.
- `power_role` is already `source` in `/sys/class/typec/port0`, writing it returns `EIO`, and `i2cget` on `0x22`
  fails with `Device or resource busy` (the driver owns it), so userspace cannot force VBUS.

Dead end (do not repeat): adding `vbus-supply = <&usb_otg_vbus>;` to `&usb_dwc3`. The DTB difference is that single
property (16 bytes, verified by decompiling both DTBs), and the tablet then hangs on the Lenovo logo — the USB
controller never probes. Reverted; the working image is `boot-txmac2.img` (release v0.2).

Next step: enable dynamic debug for `tcpm` and `fusb302`, plug/unplug a device and see whether the CC interrupt
arrives at all. If it does not, the problem is the FUSB302 interrupt (gpio97) or the CC wiring, not TCPM.
