#!/bin/sh
# One-off check: environment + QMX probe + read-only self-test (or, when the
# relay is running, a network test against it from the NAS itself).
# DSM: Control Panel > Task Scheduler > Create > Scheduled Task > User-defined
# script, user root, then "Run". Result: check.log in this folder.
. "$(cd "$(dirname "$0")" && pwd)/env.sh"
OUT="$DIR/check.log"
# Restart on request: put a file named "restart.request" in this folder and run
# this task. The relay process is stopped; start-relay.sh's supervisor starts the
# (updated) relay again 5 s later. Avoids re-creating root tasks after an update.
if [ -f "$DIR/restart.request" ]; then
  rm -f "$DIR/restart.request"
  # /proc rather than ps: DSM's "ps w" only lists processes on the current
  # terminal, and a Task Scheduler job has none.
  for d in /proc/[0-9]*; do
    if tr '\0' ' ' < "$d/cmdline" 2>/dev/null | grep -q 'qmx_nas_relay\.py'; then kill "${d#/proc/}" 2>/dev/null; fi
  done
  echo "$(date) restart requested via check.sh" >> "$DIR/qmx-relay.log"
  sleep 12
fi
{
  echo "=== QMX relay check $(date)"
  echo "--- system";  uname -a; cat /etc.defaults/VERSION 2>/dev/null | grep -E 'productversion|buildnumber'
  echo "--- python";  echo "PY=$PY"; [ -n "$PY" ] && "$PY" -V 2>&1
  echo "--- libusb";  ls -l /lib/libusb* /usr/lib/libusb* /lib64/libusb* /usr/lib64/libusb* /usr/local/lib/libusb* 2>/dev/null; echo "QMX_LIBUSB=$QMX_LIBUSB"
  echo "--- usb devices"; for d in /sys/bus/usb/devices/*; do [ -f "$d/idVendor" ] && echo "$(basename $d) $(cat $d/idVendor):$(cat $d/idProduct) $(cat $d/product 2>/dev/null)"; done
  echo "--- kernel drivers bound to the QMX"; for i in /sys/bus/usb/devices/*:*; do [ -L "$i/driver" ] && case "$(cat $i/../idVendor 2>/dev/null)" in 0483) echo "$(basename $i) -> $(basename $(readlink $i/driver))";; esac; done
  echo "--- relay already running?"; for d in /proc/[0-9]*; do tr '\0' ' ' < "$d/cmdline" 2>/dev/null | grep -q 'qmx_nas_relay\.py' && echo "yes, pid ${d#/proc/}"; done
  if [ -n "$PY" ]; then
    echo "--- libusb1 (python)"; "$PY" "$DIR/get_libusb1.py" 2>&1
    echo "--- probe";    "$PY" -u "$DIR/qmx_nas_relay.py" --probe 2>&1
    if [ -f "$DIR/relay.pid" ] && kill -0 "$(cat "$DIR/relay.pid")" 2>/dev/null; then
      echo "--- relay is running: network test (as Tab5 on 7355 and PC on 7356)"
      "$PY" -u "$DIR/nettest.py" 127.0.0.1 2>&1; echo "nettest exit code: $?"
      echo "--- relay log (last 25 lines)"; tail -25 "$DIR/qmx-relay.log"
    else
      echo "--- selftest"; "$PY" -u "$DIR/qmx_nas_relay.py" --selftest-only 2>&1; echo "selftest exit code: $?"
    fi
  else
    echo "NO PYTHON 3 FOUND"
  fi
  echo "=== done $(date)"
} > "$OUT" 2>&1
