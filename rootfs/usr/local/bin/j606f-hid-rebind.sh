#!/bin/bash
# Lenovo TB-J606F: the pogo-dock MCU answers I2C only a moment after resume, so
# i2c_hid_of's own resume leaves the keyboard (i2c-1 0x61) and touchpad
# (i2c-0 0x60) dead. Re-binding the clients works, but the first bind right
# after resume often fails with -EIO, hence the retries.
DRV=i2c_hid_of
for client in 1-0061 0-0060; do
    dev=/sys/bus/i2c/devices/$client
    [ -e "$dev" ] || continue
    if [ -e "$dev/driver" ]; then
        echo "$client" > /sys/bus/i2c/drivers/$DRV/unbind 2>/dev/null
    fi
    for try in 1 2 3 4 5 6; do
        sleep 1
        if echo "$client" > /sys/bus/i2c/drivers/$DRV/bind 2>/dev/null; then
            logger -t j606f-hid "re-bound $client on try $try"
            break
        fi
        logger -t j606f-hid "bind $client failed (try $try)"
    done
done
logger -t j606f-hid "inputs: $(grep -cE '17EF:6103|04F3:3164' /proc/bus/input/devices) pogo nodes present"
