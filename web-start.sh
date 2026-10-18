#!/bin/sh
# Start a separate, read-only uHTTPd instance from the USB repository.
set -eu
umask 077

REPO=$(CDPATH='' && export CDPATH && cd "$(dirname "$0")" && pwd -P)
MOUNT=${MOUNT:-/tmp/mountd/disk1_part1}
LISTEN=${WEB_LISTEN:-192.168.5.1:8443}
PID=${WEB_PID:-/tmp/onedrive-backup-dashboard.pid}
export REPO MOUNT

sh "$REPO/mount-check.sh" >/dev/null
command -v uhttpd >/dev/null 2>&1 || {
    echo 'uhttpd is not installed; install it with opkg first' >&2
    exit 1
}
[ -f "$REPO/web/index.html" ] || { echo 'Dashboard files are missing' >&2; exit 1; }

if [ -r "$PID" ] && kill -0 "$(cat "$PID")" 2>/dev/null; then
    echo "Dashboard already running (pid $(cat "$PID"))" >&2
    exit 1
fi
rm -f "$PID"

set -- -f -p "$LISTEN" -h "$REPO/web" -x /cgi-bin -S -D

uhttpd "$@" &
echo "$!" > "$PID"
echo "Dashboard started on $LISTEN (pid $(cat "$PID"))"