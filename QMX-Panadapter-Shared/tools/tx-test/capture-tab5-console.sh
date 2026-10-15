#!/bin/bash
# Record the Tab5's USB-serial console to a file for a whole test session,
# each line stamped with this Mac's clock. Stop with Ctrl-C.
#   bash tools/tx-test/capture-tab5-console.sh [name]
# Output: build/tab5-console-<name or date-time>.log in this project.
#
# The Mac timestamps are ONLY used by tx_compare.py to tell which FT8 slot a
# burst belongs to. Every measurement it compares comes from the firmware's
# own lines ("key down at +N ms into the slot", "(N ms on-air)"), which are
# timed on the Tab5's clock alone.
#
# On macOS, opening the port restarts the Tab5 (USB-serial-JTAG reset): start
# this FIRST, let the Tab5 boot and connect, then begin transmitting.
REPO="$(cd "$(dirname "$0")/../.." && pwd)"; mkdir -p "$REPO/build"
NAME="${1:-$(date '+%Y%m%d-%H%M%S')}"
OUT="$REPO/build/tab5-console-$NAME.log"
PY="$(ls -d "$HOME/.espressif/python_env/idf5.4_py"*_env 2>/dev/null | sort -V | tail -1)/bin/python"
[ -x "$PY" ] || PY="$(command -v python3)"
"$PY" -c "import serial" 2>/dev/null || { echo "pyserial missing: $PY -m pip install pyserial"; exit 1; }
PORT="$(ls /dev/cu.usbmodem* 2>/dev/null | head -1)"
[ -n "$PORT" ] || { echo "No Tab5 USB serial port found - is it plugged in with a data cable?"; exit 1; }
echo "Recording $PORT into $OUT - Ctrl-C to stop"
"$PY" - "$PORT" "$OUT" <<'PYEOF'
import sys, time, serial
port, out = sys.argv[1], sys.argv[2]
def stamp():
    t = time.time()
    return time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(t)) + ".%03d | " % int((t % 1) * 1000)
buf = b""
with open(out, "ab") as f:
    f.write(("# Tab5 console %s, capture started %s (Mac clock)\n" % (port, time.strftime("%Y-%m-%d %H:%M:%S %z"))).encode())
    try:
        while True:
            try:
                s = serial.Serial(port, 115200, timeout=0.2)
                s.dtr = False; s.rts = False          # never reset the board ourselves
                while True:
                    d = s.read(4096)
                    if not d:
                        continue
                    buf += d
                    while b"\n" in buf:
                        line, buf = buf.split(b"\n", 1)
                        rec = stamp().encode() + line.rstrip(b"\r") + b"\n"
                        f.write(rec); f.flush()
                        sys.stdout.buffer.write(rec); sys.stdout.flush()
            except (serial.SerialException, OSError) as e:
                f.write(("%s# [port gone: %s]\n" % (stamp(), e.__class__.__name__)).encode()); f.flush()
                time.sleep(0.3)
    except KeyboardInterrupt:
        pass
print("\nSaved:", out)
PYEOF
