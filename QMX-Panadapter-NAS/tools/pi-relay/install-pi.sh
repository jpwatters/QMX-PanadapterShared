#!/bin/bash
# install-pi.sh - install the QMX relay as a service on a Raspberry Pi 4 or 5
# (Raspberry Pi OS Bookworm or any Debian/Ubuntu with systemd, 64- or 32-bit).
#
#   sudo bash install-pi.sh             install and start the relay now
#   sudo bash install-pi.sh --no-start  install only; it starts 60 s after the next boot
#
# What it sets up:
#   /opt/qmx-relay/                   the relay (tools/nas-relay/qmx_nas_relay.py, unchanged), nettest.py,
#                                     qmx-relay-event.sh, qmx-relay-ctl, README.md
#   /usr/local/bin/qmx-relay-ctl      status / log / test / restart / stop / start
#   /etc/default/qmx-relay            relay arguments (kept if it already exists)
#   qmx-relay.timer                   starts the relay 60 s after every boot
#   qmx-relay.service                 runs it; restarts it up to 3 times if it fails
#   qmx-relay-boot.service            logs each boot
#   qmx-relay-gaveup.service          logs when the 3 restarts are used up
#   /etc/udev/rules.d/70-qmx-relay.rules  keeps ModemManager / PipeWire off the QMX, no USB autosuspend
#   /etc/logrotate.d/qmx-relay        weekly log rotation
#   /var/log/qmx-relay/qmx-relay.log  the log: service events and the relay's own output
set -euo pipefail

START=1
for a in "$@"; do
    case "$a" in
        --no-start) START=0 ;;
        -h|--help) sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $a"; exit 1 ;;
    esac
done

if [ "$(id -u)" != 0 ]; then
    exec sudo bash "$0" "$@"
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
RELAY_SRC="$HERE/../nas-relay"
OPT=/opt/qmx-relay
LOGDIR=/var/log/qmx-relay
UNITDIR=/etc/systemd/system

say() { echo "==> $*"; }
die() { echo "ERROR: $*" >&2; exit 1; }

# ---- checks -----------------------------------------------------------------
[ "$(uname -s)" = Linux ] || die "this installer is for Linux (Raspberry Pi OS)."
command -v systemctl >/dev/null || die "systemd is needed (systemctl not found)."
[ -d /run/systemd/system ] || die "systemd is not running as the init system."
command -v python3 >/dev/null || die "python3 is needed: sudo apt install python3"
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else 1)' \
    || die "python3 3.8 or newer is needed (found $(python3 -V 2>&1))."
[ -f "$RELAY_SRC/qmx_nas_relay.py" ] || die "relay not found at $RELAY_SRC/qmx_nas_relay.py (run this from tools/pi-relay in the project)."
[ -f "$HERE/systemd/qmx-relay.service" ] || die "systemd unit files missing next to this script."
if ! grep -q "discovery_responder" "$RELAY_SRC/qmx_nas_relay.py"; then
    echo "WARNING: this copy of the relay predates Find NAS (it won't answer QMXR? searches)."
    echo "         Install from the current NAS build instead: ~/src/QMX-Panadapter-NAS/tools/pi-relay"
fi

model=""
[ -r /proc/device-tree/model ] && model="$(tr -d '\0' </proc/device-tree/model)"
say "Installing the QMX relay on ${model:-$(uname -n)} ($(uname -m), $(python3 -V 2>&1))"
case "$model" in
    *"Raspberry Pi 4"*|*"Raspberry Pi 5"*) ;;
    "") say "note: not a Raspberry Pi as far as I can tell - continuing anyway" ;;
    *)  say "note: made for a Raspberry Pi 4/5; this is '$model' - continuing anyway" ;;
esac
for p in 7355 7356; do
    if command -v ss >/dev/null && ss -ltnH "sport = :$p" 2>/dev/null | grep -q . \
       && ! systemctl is-active --quiet qmx-relay.service; then
        die "TCP port $p is already in use by another program (see: sudo ss -ltnp 'sport = :$p')."
    fi
done

# ---- files ------------------------------------------------------------------
was_active=0
systemctl is-active --quiet qmx-relay.service && was_active=1
if [ $was_active = 1 ]; then
    say "Stopping the running relay for the update"
    "$HERE/qmx-relay-event.sh" note "installer: stopping the relay to update it." || true
    systemctl stop qmx-relay.service
fi

say "Copying the relay to $OPT"
install -d -m 755 "$OPT" "$LOGDIR"
install -m 644 "$RELAY_SRC/qmx_nas_relay.py" "$RELAY_SRC/nettest.py" "$OPT/"
install -m 755 "$HERE/qmx-relay-event.sh" "$HERE/qmx-relay-ctl" "$OPT/"
install -m 644 "$HERE/README.md" "$OPT/" 2>/dev/null || true
ln -sf "$OPT/qmx-relay-ctl" /usr/local/bin/qmx-relay-ctl

if [ -f /etc/default/qmx-relay ]; then
    say "Keeping the existing /etc/default/qmx-relay"
else
    install -m 644 "$HERE/qmx-relay.default" /etc/default/qmx-relay
fi

say "Installing the systemd units, udev rule and log rotation"
for u in qmx-relay.service qmx-relay.timer qmx-relay-boot.service qmx-relay-gaveup.service; do
    install -D -m 644 "$HERE/systemd/$u" "$UNITDIR/$u"
done
install -D -m 644 "$HERE/udev/70-qmx-relay.rules" /etc/udev/rules.d/70-qmx-relay.rules
install -D -m 644 "$HERE/logrotate/qmx-relay" /etc/logrotate.d/qmx-relay
touch "$LOGDIR/qmx-relay.log"

if command -v udevadm >/dev/null; then
    udevadm control --reload-rules || true
    udevadm trigger --subsystem-match=usb --attr-match=idVendor=0483 --attr-match=idProduct=a34c || true
fi

systemctl daemon-reload
systemctl enable qmx-relay.timer qmx-relay-boot.service >/dev/null
"$HERE/qmx-relay-event.sh" note "installed by install-pi.sh: relay starts 60 s after each boot, restarts up to 3 times."

# ---- start ------------------------------------------------------------------
if [ $START = 1 ]; then
    say "Starting the relay now (after a reboot it waits 60 s)"
    "$HERE/qmx-relay-event.sh" note "installer: starting the relay now."
    systemctl reset-failed qmx-relay.service 2>/dev/null || true
    systemctl start qmx-relay.service
    sleep 4
else
    say "Not started now; it starts 60 s after the next boot (or: sudo qmx-relay-ctl start)"
fi

echo
"$OPT/qmx-relay-ctl" status || true
echo
cat <<EOF
Installed.
  Status / log : qmx-relay-ctl status     qmx-relay-ctl follow
  Network test : qmx-relay-ctl test        (read-only; needs the QMX plugged in)
  Log file     : $LOGDIR/qmx-relay.log
  Settings     : /etc/default/qmx-relay   then: sudo qmx-relay-ctl restart
  Tab5         : Radio source -> Find NAS (or type this Pi's address: $(hostname -I 2>/dev/null | awk '{print $1}'))
  Remove       : sudo bash $HERE/uninstall-pi.sh
EOF
