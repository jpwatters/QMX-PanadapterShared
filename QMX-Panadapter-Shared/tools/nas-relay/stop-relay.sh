#!/bin/sh
# Stop the QMX relay started by start-relay.sh.
. "$(cd "$(dirname "$0")" && pwd)/env.sh"
PIDF="$DIR/relay.pid"
[ -f "$PIDF" ] && kill "$(cat "$PIDF")" 2>/dev/null
rm -f "$PIDF"
echo "$(date) stopped" >>"$DIR/qmx-relay.log"
