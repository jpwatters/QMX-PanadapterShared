#!/bin/bash
# Install the QMX bridge as a login item (LaunchAgent) on this Mac.
#   bash install-mac.sh                 # TCI server for WS / WSJT-X / JTDX (default); finds the NAS by
#                                       # asking QMXR? (falls back to 10.0.0.137)
#   bash install-mac.sh 192.168.1.20    # fixed NAS address, no search
#   MODE=serial bash install-mac.sh     # the old serial port (~/cu.QMX-NAS), CAT only
#   EXTRA="--keep-connected" MODE=serial bash install-mac.sh
set -euo pipefail
HOST="${1:-}"
FALLBACK="${FALLBACK:-10.0.0.137}"
LABEL="com.qmx.serial-bridge"
SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="$HOME/Library/Application Support/QMX-Serial-Bridge"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/qmx-serial-bridge.log"
PY=/usr/bin/python3

if ! xcode-select -p >/dev/null 2>&1; then
  echo "macOS's Python 3 needs the Xcode command line tools: run 'xcode-select --install' first."
  exit 1
fi

MODE="${MODE:-tci}"
if [ "$MODE" = tci ]; then
  # The TCI server makes receive audio from the I/Q and measures transmit tones: numpy.
  if ! "$PY" -c "import numpy" 2>/dev/null; then
    echo "Installing numpy for macOS's Python 3 (once) ..."
    "$PY" -m pip install --user --quiet numpy || { echo "numpy could not be installed - check the network"; exit 1; }
  fi
fi

mkdir -p "$DEST" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cp "$SRC/qmx_serial_bridge.py" "$SRC/qmx_tci.py" "$DEST/"

ARGS="<string>$PY</string><string>$DEST/qmx_serial_bridge.py</string>"
if [ -n "$HOST" ]; then
  ARGS="$ARGS<string>--host</string><string>$HOST</string>"; WHERE="NAS $HOST (fixed)"; PROBE="--host $HOST"
else
  ARGS="$ARGS<string>--fallback-host</string><string>$FALLBACK</string>"
  WHERE="NAS found by QMXR? search (fallback $FALLBACK)"; PROBE="--fallback-host $FALLBACK"
fi
[ "$MODE" = tci ] && ARGS="$ARGS<string>--tci</string>"
for a in ${EXTRA:-}; do ARGS="$ARGS<string>$a</string>"; done

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>$ARGS</array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
sleep 1
if [ "$MODE" = tci ]; then
  echo "Installed. TCI server: 127.0.0.1:40001   ($WHERE; relay ports 7356 CAT, 7357 I/Q)"
  echo "In WS / WSJT-X: Settings > Radio: Rig 'TCI Client RX1', TCI Server 127.0.0.1:40001,"
  echo "  PTT Method CAT, Mode Data/Pkt, Split None.  Audio: tick 'Use TCI Audio', then restart WS."
else
  echo "Installed. Serial port: $HOME/cu.QMX-NAS   ($WHERE, relay port 7356)"
fi
echo "Log: $LOG"
tail -n 3 "$LOG" 2>/dev/null || true
echo
echo "Checking the relay:"
"$PY" "$DEST/qmx_serial_bridge.py" $PROBE $([ "$MODE" = tci ] && echo --tci) --probe || true
