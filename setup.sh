#!/bin/sh
# Run as: sh setup.sh host  (on Linux with browser), or sh setup.sh router (on GL-MT3000).
set -eu
umask 077

REPO=$(CDPATH= cd "$(dirname "$0")" && pwd -P)

case "$(basename "$REPO")" in
    openwrt_rclone_cloud_sync) ;;
    *)
        echo 'Repository directory must be named openwrt_rclone_cloud_sync' >&2
        exit 1
        ;;
esac

case "${1:-}" in
    host)
        command -v rclone >/dev/null || {
            echo 'Install rclone on Linux first' >&2
            exit 1
        }

        [ -d "$REPO/.git" ] || {
            echo 'Clone the Git repository onto the USB first' >&2
            exit 1
        }

        mkdir -p "$REPO/.local"

        if [ ! -e "$REPO/.local/volume-id" ]; then
            (
                umask 077
                od -An -N16 -tx1 /dev/urandom |
                    tr -d ' \n' > "$REPO/.local/volume-id"
            )
        fi

        if [ ! -f "$REPO/.local/rclone.conf" ]; then
            : > "$REPO/.local/rclone.conf"
            echo 'Wizard: create a new remote named exactly onedrive, storage OneDrive, sign in through browser, choose drive, save and quit.'
            rclone --config "$REPO/.local/rclone.conf" config
        fi

        rclone --config "$REPO/.local/rclone.conf" lsf onedrive: >/dev/null || {
            echo 'OneDrive listing failed' >&2
            exit 1
        }

        chmod 700 "$REPO/.local" 2>/dev/null || :
        chmod 600 "$REPO/.local/rclone.conf" "$REPO/.local/volume-id" 2>/dev/null || :

        echo 'USB provisioned. Never commit or share .local/. Safely unmount on Linux, then insert into router.'
        ;;

    router)
        [ "$REPO" = /tmp/mountd/disk1_part1/openwrt_rclone_cloud_sync ] || {
            echo 'Router repo must be on the GL automounted USB at /tmp/mountd/disk1_part1' >&2
            exit 1
        }

        sh "$REPO/mount-check.sh" >/dev/null

        [ -f "$REPO/.local/rclone.conf" ] || {
            echo 'First provision on Linux using: sh setup.sh host' >&2
            exit 1
        }

        command -v git >/dev/null || {
            echo 'Install git via GL Plug-ins first' >&2
            exit 1
        }

        command -v rclone >/dev/null || {
            echo 'Install rclone via GL Plug-ins first' >&2
            exit 1
        }

        rclone --config "$REPO/.local/rclone.conf" lsf onedrive: >/dev/null || {
            echo 'Cannot list OneDrive on router' >&2
            exit 1
        }

        LINE='15 3 * * * /bin/sh /tmp/mountd/disk1_part1/openwrt_rclone_cloud_sync/backup.sh run >> /tmp/onedrive-usb-backup.log 2>&1'

        if [ -r /etc/crontabs/root ] &&
           grep -Fqx "$LINE" /etc/crontabs/root; then
            echo 'Scheduled Tasks: expected cron entry found.'
        else
            echo 'ACTION REQUIRED: Add this line manually in LuCI → System → Scheduled Tasks:' >&2
            printf '%s\n' "$LINE" >&2
        fi

        echo 'First test: /bin/sh /tmp/mountd/disk1_part1/openwrt_rclone_cloud_sync/backup.sh dry-run'
        ;;

    *)
        echo 'Usage: sh setup.sh host|router' >&2
        exit 2
        ;;
esac
