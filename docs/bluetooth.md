# Bluetooth

Контроллер — Qualcomm **WCN3990** (QCA), UART, прошивки `crbtfw21.tlv` / `crnv21.bin` в
`/lib/firmware/qca/`. Драйверы: `hci_uart`, `btqca`, `btqca` грузит прошивку из `/lib/firmware`.

## Что понадобилось

1. Пакеты: `bluez`, `bluez-utils` (проверено на bluez 5.87).
2. **Стабильный BD-адрес.** У WCN3990 нет своего адреса в прошивке, а драйвер помечает
   `BDADDR_PROPERTY_BROKEN`; без адреса контроллер поднимается нестабильно. В DT (патч 0001):

   ```dts
   bluetooth {
           compatible = "qcom,wcn3990-bt";
           /* ядро байт-свапает свойство: читается как 02:00:00:00:60:6f */
           local-bd-address = [6f 60 00 00 00 02];
   };
   ```

3. Проверка:

   ```bash
   hciconfig hci0        # STATE UP RUNNING, BD Address 02:00:00:00:60:6F
   bluetoothctl show
   ```

## Диагностика

Классические симптомы при отсутствии адреса/несовпадении прошивки:

```
Bluetooth: hci0: AOSP extensions version v0.98
Bluetooth: hci0: AOSP capabilities length 19 too short
Bluetooth: hci0: QCA pre shutdown cmd
Bluetooth: hci0: err 0x13
```

`err 0x13` — таймаут инициализации: проверяй, что `local-bd-address` задан и модуль `btqca`
загружается после `hci_uart` (порядок обеспечивает udev по modalias).

Аудио по Bluetooth (A2DP/HFP) отдельно не проверялось: профили зависят от PipeWire/bluez, а не от
ядра.
