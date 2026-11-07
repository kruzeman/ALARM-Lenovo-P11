# Bluetooth

Controller: Qualcomm **WCN3990** (QCA) over UART, firmware `crbtfw21.tlv` / `crnv21.bin` in
`/lib/firmware/qca/`. Drivers: `hci_uart`, `btqca` (loads the firmware).

## What was needed

1. Packages: `bluez`, `bluez-utils` (tested with bluez 5.87).
2. **A stable BD address.** The WCN3990 has no address in firmware and the driver flags it with
   `BDADDR_PROPERTY_BROKEN`; without an address the controller comes up unreliably. In the DT (patch 0001):

   ```dts
   bluetooth {
           compatible = "qcom,wcn3990-bt";
           /* the kernel byte-swaps the property: reads back as 02:00:00:00:60:6f */
           local-bd-address = [6f 60 00 00 00 02];
   };
   ```

3. Verify:

   ```bash
   hciconfig hci0        # STATE UP RUNNING, BD Address 02:00:00:00:60:6F
   bluetoothctl show
   ```

## Diagnosing

Typical failure mode without a proper address or with a mismatched firmware:

```
Bluetooth: hci0: AOSP extensions version v0.98
Bluetooth: hci0: AOSP capabilities length 19 too short
Bluetooth: hci0: QCA pre shutdown cmd
Bluetooth: hci0: err 0x13
```

`err 0x13` is an initialisation timeout: check that `local-bd-address` is present and that `btqca` is loaded
after `hci_uart` (udev orders them by modalias).

Bluetooth audio (A2DP/HFP) has not been tested: those profiles depend on PipeWire/bluez, not on the kernel.
