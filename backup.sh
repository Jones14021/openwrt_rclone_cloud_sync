#!/bin/sh
# GL-MT3000 native rclone; never writes to internal flash as a backup destination.
set -eu
umask 077
REPO=/tmp/mountd/disk1_part1/openwrt_rclone_cloud_sync
MOUNT=/tmp/mountd/disk1_part1
CONF=$REPO/.local/rclone.conf
DEST=$REPO/backup/current
MONTHLY=$REPO/backup/monthly
ACTION=${1:-run}
case "$ACTION" in run|dry-run) ;; *) echo 'Usage: sh backup.sh [dry-run|run]' >&2; exit 2;; esac
LOCK=/tmp/onedrive-usb-backup.lock
mkdir "$LOCK" 2>/dev/null || { echo 'Backup already active or stale /tmp lock' >&2; exit 1; }
PID= MONITOR=
cleanup() {
    [ -z "$MONITOR" ] || { kill "$MONITOR" 2>/dev/null || :; wait "$MONITOR" 2>/dev/null || :; }
    [ -z "$PID" ] || { kill "$PID" 2>/dev/null || :; wait "$PID" 2>/dev/null || :; }
    rmdir "$LOCK" 2>/dev/null || :
}
trap 'cleanup' 0
trap 'exit 1' 1 2 3 15
log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"; }
fail() { log "ERROR: $*" >&2; exit 1; }
check() { sh "$REPO/mount-check.sh" >/dev/null 2>&1; }
check || fail 'USB not mounted correctly; will not start'
[ -r "$CONF" ] && [ -w "$CONF" ] || fail 'Missing/unwritable OAuth config on USB'
[ "$(date +%Y)" -ge 2024 ] || fail 'Clock not set; configure NTP'
command -v rclone >/dev/null 2>&1 || fail 'Install native rclone first'
LIST=$(rclone --config "$CONF" lsf --max-depth 1 onedrive:) || fail 'Remote listing failed; no USB modifications'
[ -n "$LIST" ] || fail 'OneDrive root empty; refusing to mirror'
check || fail 'USB removed during remote listing'
log "Starting $ACTION: OneDrive -> $DEST"
if [ "$ACTION" = run ]; then
    mkdir -p "$DEST" "$MONTHLY" || fail 'Cannot create backup directories'
fi
# Poll /proc/mounts during lengthy transfers/copies. This reduces (not eliminates) the unplug race.
monitored() {
    "$@" &
    PID=$!
    (
        while kill -0 "$PID" 2>/dev/null; do
            if ! check; then
                echo 'USB disappeared; stopping active operation' >&2
                kill "$PID" 2>/dev/null || :
                break
            fi
            sleep 2
        done
    ) &
    MONITOR=$!
    if wait "$PID"; then RESULT=0; else RESULT=1; fi
    PID=
    kill "$MONITOR" 2>/dev/null || :
    wait "$MONITOR" 2>/dev/null || :
    MONITOR=
    check || fail 'USB missing after active operation; backup may be partial'
    [ "$RESULT" -eq 0 ] || fail 'Active operation failed or was stopped; backup may be partial'
}
if [ "$ACTION" = dry-run ]; then
    monitored rclone --config "$CONF" sync onedrive: "$DEST" --dry-run --transfers 1 --checkers 2 \
        --buffer-size 8M --multi-thread-streams 1 --modify-window 2s --log-level INFO
else
    monitored rclone --config "$CONF" sync onedrive: "$DEST" --delete-after --transfers 1 --checkers 2 \
        --buffer-size 8M --multi-thread-streams 1 --modify-window 2s --log-level INFO
fi
[ "$ACTION" = run ] || { log 'Dry run complete'; exit 0; }
MONTH=$(date +%Y-%m)
SNAP=$MONTHLY/$MONTH
TMP=$MONTHLY/.new-$MONTH
if [ ! -d "$SNAP" ]; then
    [ ! -e "$SNAP" ] || fail 'Snapshot path occupied by non-directory'
    [ ! -e "$TMP" ] || rm -rf "$TMP"
    check || fail 'USB removed before snapshot'
    mkdir "$TMP" || fail 'Cannot create monthly staging directory'
    # cp -R avoids hardlinks: frozen monthly is independent of current.
    monitored cp -R "$DEST/." "$TMP/" || fail 'Monthly copy incomplete; previous month retained'
    check || fail 'USB removed during monthly copy; previous month retained'
    mv "$TMP" "$SNAP" || fail 'Cannot publish monthly snapshot'
    log "Published $SNAP"
fi
check || fail 'USB removed before rotation cleanup'
for OLD in "$MONTHLY"/[0-9][0-9][0-9][0-9]-[0-1][0-9]; do
    [ -d "$OLD" ] || continue
    [ "$OLD" = "$SNAP" ] || { check || fail 'USB removed during cleanup'; rm -rf "$OLD" || fail "Cannot remove $OLD"; }
done
check || fail 'USB removed before completion'
log 'Backup finished; sync filesystem and verify status'
sync
check || fail 'USB removed before sync/flush finished'
