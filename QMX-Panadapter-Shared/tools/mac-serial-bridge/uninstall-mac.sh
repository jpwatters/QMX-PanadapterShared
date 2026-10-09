#!/bin/bash
# Remove the QMX serial bridge login item.
LABEL="com.qmx.serial-bridge"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Library/Application Support/QMX-Serial-Bridge"
rm -f "$HOME/cu.QMX-NAS"
echo "Removed. (The log stays at ~/Library/Logs/qmx-serial-bridge.log)"
