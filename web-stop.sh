#!/bin/sh
# Stop only the dashboard process started by web-start.sh.
set -eu

PID=${WEB_PID:-/tmp/onedrive-backup-dashboard.pid}

[ -r "$PID" ] || { echo 'Dashboard is not running.'; exit 0; }
PROCESS=$(cat "$PID")
case "$PROCESS" in *[!0-9]*|'') echo "Invalid dashboard PID file: $PID" >&2; exit 1;; esac
if ! kill -0 "$PROCESS" 2>/dev/null; then
    rm -f "$PID"
    echo 'Removed stale dashboard PID file.'
    exit 0
fi
COMMAND=$(tr '\000' ' ' < "/proc/$PROCESS/cmdline" 2>/dev/null || :)
case "$COMMAND" in *uhttpd*) ;; *) echo "Refusing to stop non-dashboard process $PROCESS" >&2; exit 1;; esac
kill "$PROCESS"
rm -f "$PID"
echo "Dashboard stopped (pid $PROCESS)."