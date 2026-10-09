#!/bin/bash
# Record the Tab5's USB serial output (boot messages, crash reasons) for a while.
#   bash ~/src/qmx-panadapter-v1.16/tools/mac-capture-serial.sh [seconds]   (default 90)
# Output: build/serial-capture.log in this project. Uses ESP-IDF's Python (pyserial).
# Note: on macOS opening the port restarts the Tab5 (USB-serial-JTAG reset), so
# the capture always starts from a fresh boot. Setting DTR/RTS first does not help.
REPO="$(cd "$(dirname "$0")/.." && pwd)"; mkdir -p "$REPO/build"
OUT="$REPO/build/serial-capture.log"; SECS="${1:-90}"
PY="$(ls -d "$HOME/.espressif/python_env/idf5.4_py"*_env 2>/dev/null | sort -V | tail -1)/bin/python"
[ -x "$PY" ] || { echo "ESP-IDF Python not found"; exit 1; }
PORT="$(ls /dev/cu.usbmodem* 2>/dev/null | head -1)"
[ -n "$PORT" ] || { echo "No Tab5 USB serial port found - is it plugged in with a data cable?"; exit 1; }
echo "Recording $PORT for $SECS s into $OUT ..."
"$PY" - "$PORT" "$SECS" "$OUT" <<'PYEOF'
import sys, time, serial
port, secs, out = sys.argv[1], float(sys.argv[2]), sys.argv[3]
end = time.time() + secs
with open(out, "wb") as f:
    f.write(("# capture of %s started %s\n" % (port, time.ctime())).encode())
    while time.time() < end:
        try:
            s = serial.Serial(port, 115200, timeout=0.5)
            s.dtr = False; s.rts = False          # never reset the board ourselves
            while time.time() < end:
                d = s.read(4096)
                if d: f.write(d); f.flush(); sys.stdout.buffer.write(d); sys.stdout.flush()
        except (serial.SerialException, OSError) as e:
            # the port disappears while the board reboots - wait and reopen
            f.write(("\n# [port gone: %s] %s\n" % (e.__class__.__name__, time.ctime())).encode()); f.flush()
            time.sleep(0.3)
print("\nSaved:", out)
PYEOF
