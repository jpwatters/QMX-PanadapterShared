#!/bin/sh
# qmx-relay-event.sh - write what happens to the QMX relay service into its log,
# /var/log/qmx-relay/qmx-relay.log (the relay's own output goes to the same file).
#
# Called by systemd:
#   boot    qmx-relay-boot.service    the system booted; the relay starts 60 s later
#   start   ExecStartPre              the relay is starting (first start, restart n of 3, or by hand)
#   stop    ExecStopPost              the relay stopped: why, and whether it will be restarted
#   gaveup  OnFailure                 the 3 restarts are used up; it stays stopped
# and by qmx-relay-ctl:
#   note "text"                       a line of its own (manual start/stop/restart)
#
# It never fails, so it can never stop the relay from starting.

LOGDIR=/var/log/qmx-relay
LOG="$LOGDIR/qmx-relay.log"
UNIT=qmx-relay.service
MAX_RESTARTS=3          # keep in step with StartLimitBurst=4 in qmx-relay.service
RESTART_SEC=10          # keep in step with RestartSec= in qmx-relay.service
BOOT_DELAY=60           # keep in step with OnBootSec= in qmx-relay.timer

mkdir -p "$LOGDIR" 2>/dev/null

say() {
    printf '%s SERVICE %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG" 2>/dev/null
}

uptime_s() { cut -d. -f1 /proc/uptime 2>/dev/null || echo "?"; }

nrestarts() {
    n="$(systemctl show -p NRestarts --value "$UNIT" 2>/dev/null)"
    case "$n" in ''|*[!0-9]*) echo 0 ;; *) echo "$n" ;; esac
}

case "$1" in
boot)
    say "---- system booted (uptime $(uptime_s) s, $(uname -n), kernel $(uname -r))."
    say "relay will be started by qmx-relay.timer ${BOOT_DELAY} s after boot."
    ;;
start)
    n="$(nrestarts)"
    up="$(uptime_s)"
    if [ "$n" -gt 0 ] 2>/dev/null; then
        say "starting the relay: restart $n of $MAX_RESTARTS (uptime $up s)."
    elif [ "$up" != "?" ] && [ "$up" -lt $((BOOT_DELAY + 60)) ]; then
        say "starting the relay: ${BOOT_DELAY} s after boot, by qmx-relay.timer (uptime $up s)."
    else
        say "starting the relay (uptime $up s)."
    fi
    say "command: python3 qmx_nas_relay.py ${RELAY_ARGS:-}   backend: ${QMX_BACKEND:-auto}"
    ;;
stop)
    n="$(nrestarts)"
    res="${SERVICE_RESULT:-unknown}"; code="${EXIT_CODE:-?}"; st="${EXIT_STATUS:-?}"
    case "$res" in
    success)
        if [ "$code" = "exited" ]; then
            say "relay exited normally (status $st); not restarted."
        else
            say "relay stopped on request ($code $st)."
        fi
        ;;
    *)
        case "$code" in
            exited) why="exited with status $st" ;;
            killed) why="was killed by signal $st" ;;
            dumped) why="crashed (signal $st, core dumped)" ;;
            *)      why="stopped ($code $st)" ;;
        esac
        if [ "$n" -lt "$MAX_RESTARTS" ] 2>/dev/null; then
            say "relay FAILED: it $why (result: $res). Restart $((n + 1)) of $MAX_RESTARTS in ${RESTART_SEC} s."
        else
            say "relay FAILED: it $why (result: $res). All $MAX_RESTARTS restarts used - not restarting."
        fi
        ;;
    esac
    ;;
gaveup)
    say "GAVE UP: the relay failed and its $MAX_RESTARTS restarts are used up. It stays stopped"
    say "until the next reboot or 'sudo qmx-relay-ctl restart'. See the lines above for why."
    ;;
note)
    shift
    say "$*"
    ;;
*)
    say "qmx-relay-event.sh: unknown event '$1'"
    ;;
esac
exit 0
