#!/bin/sh
set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
FIXTURE=$(mktemp -d)
trap 'rm -rf "$FIXTURE"' EXIT
export FIXTURE
REPO=$FIXTURE/repo
MOUNT=$FIXTURE
MOUNT_CHECK_TEST=1
BUSYBOX=$(command -v busybox)
export REPO MOUNT MOUNT_CHECK_TEST BUSYBOX

mkdir -p "$REPO/.git" "$REPO/.local/bin" "$REPO/backup/current" "$REPO/backup/monthly" "$FIXTURE/state"
touch "$REPO/.local/volume-id" "$REPO/.local/rclone.conf"
cp "$ROOT/mount-check.sh" "$REPO/mount-check.sh"
printf 'original backup\n' > "$REPO/backup/current/example"
cat > "$REPO/.local/bin/rclone" <<'EOF'
#!/bin/sh
case "$3" in
    lsf) printf 'example\n' ;;
    sync) exit 0 ;;
    *) exit 1 ;;
esac
EOF
cat > "$REPO/.local/bin/sync" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$REPO/.local/bin/cp" <<'EOF'
#!/bin/sh
printf '%s\n' "$3" > "$FIXTURE/copy-destination"
exec "$BUSYBOX" cp "$@"
EOF
chmod +x "$REPO/.local/bin/rclone" "$REPO/.local/bin/sync" "$REPO/.local/bin/cp"

sed -e "s|^REPO=.*|REPO=\$FIXTURE/repo|" \
    -e "s|^MOUNT=.*|MOUNT=\$FIXTURE|" \
    -e "s|^STATE_DIR=.*|STATE_DIR=\$FIXTURE/state|" \
    -e "s|^LOG=.*|LOG=\$FIXTURE/backup.log|" \
    -e "s|^LOCK=.*|LOCK=\$FIXTURE/backup.lock|" \
    "${BACKUP_SCRIPT:-$ROOT/backup.sh}" > "$FIXTURE/backup.sh"

MONTH=$(date +%Y-%m)
mkdir "$REPO/backup/monthly/.new-$MONTH"
printf 'stale\n' > "$REPO/backup/monthly/.new-$MONTH/stale"
sh "$FIXTURE/backup.sh" run

SNAPSHOT=$REPO/backup/monthly/$MONTH
COPY_DESTINATION=$(cat "$FIXTURE/copy-destination")
if [ "$COPY_DESTINATION" != "$REPO/backup/monthly/.new-$MONTH/" ]; then
    printf 'Unexpected snapshot copy destination: %s\n' "$COPY_DESTINATION" >&2
    exit 1
fi
[ -f "$SNAPSHOT/example" ]
[ ! -e "$SNAPSHOT/stale" ]
[ ! -e "$REPO/backup/monthly/.new-$MONTH" ]
[ -z "$(find "$FIXTURE/state" -type d -name '.status.*' -print)" ]
grep -q '"phase":"completed"' "$FIXTURE/state/status.json"
grep -Fq '"monthly_snapshot":"'"$SNAPSHOT"'"' "$REPO/.local/last-success.json"
printf 'changed backup\n' > "$REPO/backup/current/example"
[ "$(cat "$SNAPSHOT/example")" = 'original backup' ]
printf 'Snapshot destination test passed\n'