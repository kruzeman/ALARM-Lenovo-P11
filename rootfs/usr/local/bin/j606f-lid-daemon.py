#!/usr/bin/env python3
"""j606f-lid-daemon — сон по закрытию чехла без цикла «уснул-проснулся».

Почему не logind: gpio-keys с wakeup-source будит по любому изменению линии,
поэтому немедленный suspend по закрытию тут же будится тем же событием.
Здесь мы ждём 3 секунды после закрытия (событие уже прошло, линия стабильна)
и только затем уходим в сон — будить будет уже только открытие чехла.
"""
import os, select, struct, subprocess, sys, time

DEV = "/dev/input/event2"
EV_SW = 0x05
SW_LID = 0x00
SETTLE = 3.0          # секунд после закрытия перед сном
EVENT_FMT = "llHHi"   # struct input_event на 64-битной ARM
EVENT_SIZE = struct.calcsize(EVENT_FMT)

def log(msg):
    print(msg, flush=True)

def suspend():
    log("cover closed -> suspend")
    subprocess.run(["systemctl", "suspend"], check=False)

def read_events(fd, timeout):
    r, _, _ = select.select([fd], [], [], timeout)
    if not r:
        return []
    data = os.read(fd, EVENT_SIZE * 64)
    out = []
    for i in range(0, len(data) - EVENT_SIZE + 1, EVENT_SIZE):
        _, _, etype, code, value = struct.unpack(EVENT_FMT, data[i:i + EVENT_SIZE])
        out.append((etype, code, value))
    return out

def main():
    fd = os.open(DEV, os.O_RDONLY)
    closed = False
    pending_at = None
    log("started, watching SW_LID on %s" % DEV)
    while True:
        pending = None if pending_at is None else max(0.0, pending_at - time.time())
        timeout = 0.5 if pending is None else min(pending, 0.5)
        for etype, code, value in read_events(fd, timeout):
            if etype == EV_SW and code == SW_LID:
                closed = bool(value)
                log("SW_LID -> %d" % value)
                if closed:
                    pending_at = time.time() + SETTLE
                else:
                    pending_at = None

        if pending_at is not None and time.time() >= pending_at:
            pending_at = None
            # дренаж: не открыли ли чехол за эти секунды
            for etype, code, value in read_events(fd, 0):
                if etype == EV_SW and code == SW_LID:
                    closed = bool(value)
                    log("SW_LID -> %d (during settle)" % value)
            if closed:
                suspend()

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(0)
