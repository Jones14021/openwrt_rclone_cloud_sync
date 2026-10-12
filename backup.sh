#!/bin/sh
# Native OpenWrt rclone; download-only from OneDrive to USB.
set -eu
umask 077
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
ROOT=${BACKUP_ROOT:-/mnt/onedrive-backup}
MAX_DELETE=${MAX_DELETE:-100}
case "${1:-run}" in run|dry-run) ACTION=${1:-run};; *) echo 'Usage: backup.sh [dry-run|run]' >&2; exit 2;; esac
case "$ROOT" in /mnt/*) ;; *) echo 'BACKUP_ROOT must start with /mnt/' >&2; exit 2;; esac
case "$ROOT" in *' '*|*'..'*|*/.|*/|*'//'*) echo 'Use a simple absolute mount path without spaces or dot segments' >&2; exit 2;; esac
case "$MAX_DELETE" in ''|*[!0-9]*) echo 'MAX_DELETE must be a nonnegative integer' >&2; exit 2;; esac
LOCK=/tmp/mt3000-onedrive-native.lock
mkdir "$LOCK" 2>/dev/null || { echo 'Another run is active or the /tmp lock is stale' >&2; exit 1; }
trap 'rmdir "$LOCK" 2>/dev/null || :' 0
trap 'exit 1' 1 2 3 15
log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"; }
fail() { log "ERROR: $*" >&2; exit 1; }
command -v rclone >/dev/null 2>&1 || fail 'Native rclone binary not found'
awk -v root="$ROOT" '$2 == root { found=1 } END { exit !found }' /proc/mounts || fail "USB filesystem not mounted directly at $ROOT"
[ -f "$ROOT/.onedrive-backup-volume" ] || fail 'USB marker absent: refusing to write'
[ -w "$ROOT" ] || fail 'USB volume is not writable'
CONF=$ROOT/.onedrive-backup/rclone.conf
[ -f "$CONF" ] && [ -r "$CONF" ] && [ -w "$CONF" ] || fail 'OAuth config missing/unwritable (token refresh must be saved)'
[ "$(date +%Y)" -ge 2024 ] || fail 'Router clock appears unset: configure NTP first'
LIST=$(rclone --config "$CONF" lsf --max-depth 1 onedrive:) || fail 'Cannot list OneDrive; refusing to touch USB data'
[ -n "$LIST" ] || fail 'OneDrive root is empty; refusing to mirror empty source'
CURRENT=$ROOT/current
MONTHLY=$ROOT/monthly
MONTH=$(date +%Y-%m)
SNAP=$MONTHLY/$MONTH
TMP=$MONTHLY/.new-$MONTH
log "Action=$ACTION; OneDrive -> $CURRENT; max deletes=$MAX_DELETE"
if [ "$ACTION" = dry-run ]; then
    rclone --config "$CONF" sync onedrive: "$CURRENT" \
        --transfers 1 --checkers 2 --buffer-size 8M --multi-thread-streams 1 \
        --max-delete "$MAX_DELETE" --dry-run --stats 1m --log-level INFO || fail 'Dry run failed'
    log 'Dry run complete; no current/ or monthly/ changes made'
    exit 0
fi
mkdir -p "$CURRENT" "$MONTHLY" || fail 'Cannot make USB backup directories'
if ! rclone --config "$CONF" sync onedrive: "$CURRENT" \
    --transfers 1 --checkers 2 --buffer-size 8M --multi-thread-streams 1 \
    --max-delete "$MAX_DELETE" --stats 1m --log-level INFO; then
    fail 'Sync failed. Monthly untouched; current may be partly updated.'
fi
if [ ! -d "$SNAP" ]; then
    [ ! -e "$SNAP" ] || fail 'Month snapshot path exists and is not a directory'
    [ ! -e "$TMP" ] || rm -rf "$TMP"
    mkdir "$TMP" || fail 'Cannot create temporary snapshot directory'
    if ! cp -a "$CURRENT/." "$TMP/"; then
        fail "Monthly copy failed; old snapshot kept; incomplete $TMP will be retried"
    fi
    mv "$TMP" "$SNAP" || fail 'Cannot publish monthly snapshot'
    log "Published $SNAP"
fi
# Cleanup also handles a prior interruption immediately after snapshot promotion.
for OLD in "$MONTHLY"/[0-9][0-9][0-9][0-9]-[0-1][0-9]; do
    [ -d "$OLD" ] || continue
    if [ "$OLD" != "$SNAP" ]; then
        rm -rf "$OLD" || fail "Failed to remove older monthly snapshot: $OLD"
    fi
done
log 'Completed successfully'
