#!/bin/bash
# uninstall-pi.sh - remove the QMX relay service from this Raspberry Pi.
#   sudo bash uninstall-pi.sh            keeps the log (/var/log/qmx-relay) and /etc/default/qmx-relay
#   sudo bash uninstall-pi.sh --purge    removes those too
set -uo pipefail
PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1
if [ "$(id -u)" != 0 ]; then exec sudo bash "$0" "$@"; fi

[ -x /opt/qmx-relay/qmx-relay-event.sh ] && /opt/qmx-relay/qmx-relay-event.sh note "uninstall-pi.sh: removing the relay service."
systemctl disable --now qmx-relay.timer qmx-relay-boot.service 2>/dev/null
systemctl stop qmx-relay.service 2>/dev/null
for u in qmx-relay.service qmx-relay.timer qmx-relay-boot.service qmx-relay-gaveup.service; do
    rm -f "/etc/systemd/system/$u"
done
systemctl daemon-reload
systemctl reset-failed qmx-relay.service qmx-relay-gaveup.service 2>/dev/null
rm -f /etc/udev/rules.d/70-qmx-relay.rules /etc/logrotate.d/qmx-relay /usr/local/bin/qmx-relay-ctl
command -v udevadm >/dev/null && udevadm control --reload-rules
rm -rf /opt/qmx-relay
if [ $PURGE = 1 ]; then
    rm -rf /var/log/qmx-relay /etc/default/qmx-relay
    echo "Removed, including the log and settings."
else
    echo "Removed. Kept: /var/log/qmx-relay (log) and /etc/default/qmx-relay (settings); --purge removes them."
fi
