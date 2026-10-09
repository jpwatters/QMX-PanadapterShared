#!/bin/sh
# Start the QMX relay in the background and keep it running (restarts if it
# exits). DSM: Task Scheduler > Create > Triggered Task > User-defined script,
# user root, event "Boot-up". Log: qmx-relay.log in this folder.
. "$(cd "$(dirname "$0")" && pwd)/env.sh"
LOG="$DIR/qmx-relay.log"
PIDF="$DIR/relay.pid"
[ -n "$PY" ] || { echo "$(date) no python3 found" >>"$LOG"; exit 1; }
# python-libusb1 is optional: without libusb-1.0 the relay uses Linux usbfs.
"$PY" "$DIR/get_libusb1.py" >>"$LOG" 2>&1 || echo "$(date) python-libusb1 not installed - using usbfs" >>"$LOG"
if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
  echo "$(date) already running (pid $(cat "$PIDF"))" >>"$LOG"; exit 0
fi
(
  trap 'kill $CHILD 2>/dev/null; exit 0' TERM INT
  while :; do
    if [ -f "$LOG" ] && [ "$(wc -c <"$LOG")" -gt 2000000 ]; then mv -f "$LOG" "$LOG.1"; fi
    "$PY" -u "$DIR/qmx_nas_relay.py" --selftest >>"$LOG" 2>&1 &
    CHILD=$!
    wait $CHILD
    echo "$(date) relay exited (code $?), restarting in 5 s" >>"$LOG"
    sleep 5
  done
) </dev/null >/dev/null 2>&1 &
echo $! >"$PIDF"
echo "$(date) started (supervisor pid $!)" >>"$LOG"
