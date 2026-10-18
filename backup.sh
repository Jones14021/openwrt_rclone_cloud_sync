#!/bin/sh
# GL-MT3000 native rclone; never writes to internal flash as a backup destination.
set -eu
umask 077
REPO=/tmp/mountd/disk1_part1/openwrt_rclone_cloud_sync
PATH="$REPO/.local/bin:$PATH"
export PATH
MOUNT=/tmp/mountd/disk1_part1
CONF=$REPO/.local/rclone.conf
DEST=$REPO/backup/current
MONTHLY=$REPO/backup/monthly
STATE_DIR=/tmp/onedrive-backup
STATE=$STATE_DIR/status.json
LAST_SUCCESS=$REPO/.local/last-success.json
LOG=/tmp/onedrive-usb-backup.log
LOG_LIMIT=131072
ACTION=${1:-run}
case "$ACTION" in run|dry-run) ;; *) echo 'Usage: sh backup.sh [dry-run|run]' >&2; exit 2;; esac

# Keep all job output in RAM and trim it before each run. Cron must not redirect
# this script elsewhere, otherwise rclone output would bypass the size cap.
mkdir -p "$STATE_DIR"
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt "$LOG_LIMIT" ]; then
    tail -c "$LOG_LIMIT" "$LOG" > "$LOG.new" && mv "$LOG.new" "$LOG"
fi
exec >> "$LOG" 2>&1

check() { sh "$REPO/mount-check.sh" >/dev/null 2>&1; }
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
state_update() {
    PHASE=$1
    ERROR=${2:-}
    NOW=$(date '+%Y-%m-%dT%H:%M:%S%z')
    USB=false
    AVAILABLE=0
    TOTAL=0
    if check; then
        USB=true
        # shellcheck disable=SC2046 # Split the two numeric df fields into $1 and $2.
        set -- $(df -Pk "$MOUNT" | awk 'NR == 2 { print $4 * 1024, $2 * 1024 }')
        AVAILABLE=${1:-0}
        TOTAL=${2:-0}
    fi
    LAST_SUCCESS_AT=
    [ -r "$LAST_SUCCESS" ] && LAST_SUCCESS_AT=$(sed -n 's/.*"finished_at":"\([^"]*\)".*/\1/p' "$LAST_SUCCESS" | head -n 1)
    TMP=$STATE_DIR/.status.$$
    printf '{"phase":"%s","action":"%s","started_at":"%s","updated_at":"%s","pid":%s,"usb_mounted":%s,"available_bytes":%s,"total_bytes":%s,"last_success_at":"%s","error":"%s"}\n' \
        "$(json_escape "$PHASE")" "$ACTION" "${STARTED_AT:-$NOW}" "$NOW" "$$" "$USB" "$AVAILABLE" "$TOTAL" \
        "$(json_escape "$LAST_SUCCESS_AT")" "$(json_escape "$ERROR")" > "$TMP" && mv "$TMP" "$STATE"
}
publish_success() {
    TMP=$REPO/.local/.last-success.$$
    FINISHED_AT=$(date '+%Y-%m-%dT%H:%M:%S%z')
    printf '{"finished_at":"%s","monthly_snapshot":"%s"}\n' "$FINISHED_AT" "${SNAP:-}" > "$TMP" && mv "$TMP" "$LAST_SUCCESS"
}

STARTED_AT=$(date '+%Y-%m-%dT%H:%M:%S%z')
state_update checking
LOCK=/tmp/onedrive-usb-backup.lock
mkdir "$LOCK" 2>/dev/null || { state_update failed 'Backup already active or stale lock'; exit 1; }
PID=
MONITOR=
cleanup() {
    RESULT=$?
    [ -z "$MONITOR" ] || { kill "$MONITOR" 2>/dev/null || :; wait "$MONITOR" 2>/dev/null || :; }
    [ -z "$PID" ] || { kill "$PID" 2>/dev/null || :; wait "$PID" 2>/dev/null || :; }
    [ "$RESULT" -eq 0 ] || state_update failed "${ERROR:-Backup interrupted or failed}" || :
    rmdir "$LOCK" 2>/dev/null || :
}
trap 'cleanup' 0
trap 'exit 1' 1 2 3 15
log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*"; }
fail() { ERROR=$*; state_update failed "$ERROR" || :; log "ERROR: $*" >&2; exit 1; }
[ -f "$REPO/.local/bin/rclone" ] || fail 'USB rclone binary missing'
check || fail 'USB not mounted correctly; will not start'
[ -r "$CONF" ] && [ -w "$CONF" ] || fail 'Missing/unwritable OAuth config on USB'
[ "$(date +%Y)" -ge 2024 ] || fail 'Clock not set; configure NTP'
command -v rclone >/dev/null 2>&1 || fail 'Install native rclone first'
state_update 'checking OneDrive'
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
    if [ "$RESULT" -ne 0 ] && tail -n 200 "$LOG" | grep -Fq 'no space left on device'; then
        fail 'USB storage is full; backup stopped before completion'
    fi
    [ "$RESULT" -eq 0 ] || fail 'Active operation failed or was stopped; backup may be partial'
}
if [ "$ACTION" = dry-run ]; then
    state_update downloading
    monitored rclone --config "$CONF" sync onedrive: "$DEST" --dry-run --transfers 1 --checkers 2 \
        --buffer-size 8M --multi-thread-streams 1 --modify-window 2s --log-level INFO
else
    state_update downloading
    monitored rclone --config "$CONF" sync onedrive: "$DEST" --delete-after --transfers 1 --checkers 2 \
        --buffer-size 8M --multi-thread-streams 1 --modify-window 2s --log-level INFO
fi
[ "$ACTION" = run ] || { state_update completed; log 'Dry run complete'; exit 0; }
MONTH=$(date +%Y-%m)
SNAP=$MONTHLY/$MONTH
TMP=$MONTHLY/.new-$MONTH
if [ ! -d "$SNAP" ]; then
    [ ! -e "$SNAP" ] || fail 'Snapshot path occupied by non-directory'
    [ ! -e "$TMP" ] || rm -rf "$TMP"
    check || fail 'USB removed before snapshot'
    mkdir "$TMP" || fail 'Cannot create monthly staging directory'
    state_update 'creating monthly snapshot'
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
publish_success || fail 'Cannot publish last-success record'
state_update completed
