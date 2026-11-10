# USB-C OTG (host mode) — state on 2026-11-10

Goal: a USB Wi-Fi adapter plugged into the port should enumerate.

What works:
- The board DTS (`sm6115p-lenovo-j606f-hx83102p.dts` — the one this SKU needs; the base
  `sm6115p-lenovo-j606f.dts` has no `usb-role-switch` and no Himax panel) already wires the FUSB302 at
  `i2c0 0x22` to `usb_dwc3` through a role switch, `dr_mode = "otg"`, high speed only.
- Writing `host` to `/sys/class/usb_role/4e00000.usb-role-switch/role` does bring up xHCI:
  `usb1`/`usb2` root hubs appear, `ls /sys/bus/usb/devices/` shows the two buses.

**Host mode works (confirmed 2026-11-10).** Plugging a device in — no manual role switching — makes TCPM detect it,
switch the port to host and enable VBUS: GPIO 38 goes `out high`, xHCI enumerates the device and the adapter shows up
under `/sys/bus/usb/devices/`:

```
usb 1-1: new high-speed USB device number 2 using xhci-hcd
usb 1-1: New USB device found, idVendor=0bda, idProduct=8179
usb 1-1: Product: 802.11n NIC
```

`/sys/class/usb_role/*/role` reads `host`, `GPIO38` reads `out high`. What is still missing for that particular
adapter is only the driver: `rtl8xxxu` is not built in this kernel (`CONFIG_RTL8XXXU` unset), so no `wlan1` appears.
Build it as a module if the adapter is needed; nothing else is required.

Notes from the failed attempts (do not repeat):
- Forcing `role=host` by hand brings up xHCI but leaves VBUS off until a device is actually plugged — TCPM owns the
  regulator. `power_role` is already `source`; writing it returns `EIO`; `i2cget` on `0x22` fails with
  `Device or resource busy` because the driver owns the chip.

Dead end (do not repeat): adding `vbus-supply = <&usb_otg_vbus>;` to `&usb_dwc3`. The DTB difference is that single
property (16 bytes, verified by decompiling both DTBs), and the tablet then hangs on the Lenovo logo — the USB
controller never probes. Reverted; the working image is `boot-txmac2.img` (release v0.2).

Next step: enable dynamic debug for `tcpm` and `fusb302`, plug/unplug a device and see whether the CC interrupt
arrives at all. If it does not, the problem is the FUSB302 interrupt (gpio97) or the CC wiring, not TCPM.
