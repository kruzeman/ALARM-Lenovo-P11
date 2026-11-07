#!/bin/bash
LOG=/var/log/mic-test.log
sleep 30
exec >>$LOG 2>&1
echo "===== $(date -Is) mic test"
cat /proc/asound/cards | head -3
echo "-- codec driver:"; readlink -f /sys/bus/i2c/devices/1-0040/driver 2>/dev/null
echo "-- card components with es7210:"; find /sys/kernel/debug/asoc -maxdepth 2 -iname "*es7210*" 2>/dev/null | head -2
amixer -c0 cset name='MultiMedia2 Mixer PRIMARY_TDM_TX_0' 1 2>&1 | tail -1
amixer -c0 cset name='MultiMedia1 Mixer PRIMARY_TDM_TX_0' 1 2>&1 | tail -1
for dev in hw:0,1 hw:0,0; do
  f=/tmp/mic_${dev//[:,]/_}.wav
  echo "-- arecord $dev -> $f"
  timeout 20 arecord -D $dev -f S16_LE -c 2 -r 48000 -d 3 "$f" 2>&1 | tail -2
  ls -l "$f" 2>/dev/null | awk '{print "size:", $5}'
done
python3 - <<'PY'
import wave,struct,glob
for p in sorted(glob.glob('/tmp/mic_hw_*.wav')):
    try:
        w=wave.open(p); n=w.getnframes(); d=w.readframes(n)
        s=struct.unpack("<%dh"%(len(d)//2), d) if d else ()
        peak=max((abs(x) for x in s), default=0)
        print(f"RESULT {p}: frames={n} peak={peak} ({peak/32768*100:.2f}% fs)")
    except Exception as e:
        print("RESULT", p, "error", e)
PY
echo "-- dmesg tail"; dmesg -T | tail -20
echo "===== $(date -Is) mic test done"
