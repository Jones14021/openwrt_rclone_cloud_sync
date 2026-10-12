#!/bin/sh
# Exit 0 only when GL.iNet has mounted the one USB partition at this exact path.
set -eu
MOUNT=/tmp/mountd/disk1_part1
# GL firmware mounts USB as /dev/sdXN. No mounting or creation is attempted here.
awk -v m="$MOUNT" '
    $2==m && $1 ~ /^\/dev\/sd[a-z]+[0-9]+$/ && $4 ~ /(^|,)rw(,|$)/ { ok=1 }
    END { exit !ok }
' /proc/mounts || { echo "USB not mounted read-write at $MOUNT; inspect /proc/mounts and /tmp/mountd" >&2; exit 1; }
[ -d "$MOUNT/openwrt_rclone_cloud_sync/.git" ] || { echo 'Expected Git clone absent from USB' >&2; exit 1; }
[ -f "$MOUNT/openwrt_rclone_cloud_sync/.local/volume-id" ] || { echo 'USB setup marker absent' >&2; exit 1; }

echo "USB provisioned and mounted read-write at $MOUNT. Ready for router use."
echo "Git repository openwrt_rclone_cloud_sync is present. Never commit or share .local/."
echo "If you see this message on the router, the USB is ready for backup.sh to run."
