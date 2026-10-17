#!/bin/sh
# Start a separate, read-only uHTTPd instance from the USB repository.
set -eu
umask 077

REPO=$(CDPATH='' && export CDPATH && cd "$(dirname "$0")" && pwd -P)
MOUNT=${MOUNT:-/tmp/mountd/disk1_part1}
AUTH=$REPO/.local/web-auth
LISTEN=${WEB_LISTEN:-127.0.0.1:8443}
PID=${WEB_PID:-/tmp/onedrive-backup-dashboard.pid}
CONFIG=$PID.conf
export REPO MOUNT

sh "$REPO/mount-check.sh" >/dev/null
command -v uhttpd >/dev/null 2>&1 || {
    echo 'uhttpd is not installed; install it with opkg first' >&2
    exit 1
}
[ -r "$AUTH" ] || {
    echo "Create $AUTH containing one uHTTPd user:password entry" >&2
    exit 1
}
AUTH_LINE=$(sed -n '1p' "$AUTH")
case "$AUTH_LINE" in ''|:*|*:|*:*:*) echo 'web-auth must contain one non-empty user:password entry' >&2; exit 1;; esac
[ -z "$(sed -n '2p' "$AUTH")" ] || {
    echo 'web-auth must contain exactly one user:password entry' >&2
    exit 1
}
[ -f "$REPO/web/index.html" ] || { echo 'Dashboard files are missing' >&2; exit 1; }

if [ -r "$PID" ] && kill -0 "$(cat "$PID")" 2>/dev/null; then
    echo "Dashboard already running (pid $(cat "$PID"))" >&2
    exit 1
fi
rm -f "$PID"
printf '/:%s\n' "$AUTH_LINE" > "$CONFIG"
chmod 600 "$CONFIG"

# TLS is opt-in because certificate creation is router-specific. Without both
# paths, this is intentionally suitable only for loopback SSH-tunnel testing.
set -- -f -p "$LISTEN" -h "$REPO/web" -x /cgi-bin -c "$CONFIG" -r 'OneDrive backup' -S -D
if [ -n "${WEB_CERT:-}" ] || [ -n "${WEB_KEY:-}" ]; then
    [ -r "${WEB_CERT:-}" ] && [ -r "${WEB_KEY:-}" ] || {
        echo 'Set both WEB_CERT and WEB_KEY for HTTPS' >&2
        exit 1
    }
    set -- -f -s "$LISTEN" -C "$WEB_CERT" -K "$WEB_KEY" -h "$REPO/web" -x /cgi-bin -c "$CONFIG" -r 'OneDrive backup' -S -D
fi

uhttpd "$@" &
echo "$!" > "$PID"
echo "Dashboard started on $LISTEN (pid $(cat "$PID"))"