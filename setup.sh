#!/bin/sh
# Run on Linux: sh setup.sh host
# Run on GL-MT3000: sh setup.sh router
set -eu
umask 077

REPO=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
RCLONE_BIN="$REPO/.local/bin/rclone"

case "$(basename "$REPO")" in
    openwrt_rclone_cloud_sync) ;;
    *)
        echo 'Repository directory must be named openwrt_rclone_cloud_sync' >&2
        exit 1
        ;;
esac

case "${1:-}" in
    host)
        [ -d "$REPO/.git" ] || {
            echo 'Clone the Git repository onto the USB first' >&2
            exit 1
        }

        for tool in curl gpg sha256sum unzip mktemp rclone; do
            command -v "$tool" >/dev/null 2>&1 || {
                echo "Install $tool on the Linux host first" >&2
                exit 1
            }
        done

        mkdir -p "$REPO/.local/bin"

        if [ ! -e "$REPO/.local/volume-id" ]; then
            (
                umask 077
                od -An -N16 -tx1 /dev/urandom |
                    tr -d ' \n' > "$REPO/.local/volume-id"
            )
        fi

        echo 'Checking the latest stable rclone release...'
        VERSION=$(
            curl --fail --silent --show-error --location \
                --proto '=https' --proto-redir '=https' \
                'https://downloads.rclone.org/version.txt'
        )
        VERSION=${VERSION#rclone }

        case "$VERSION" in
            v[0-9]*)
                case "$VERSION" in
                    *[!0-9.v]*)
                        echo "Unexpected rclone version: $VERSION" >&2
                        exit 1
                        ;;
                esac
                ;;
            *)
                echo "Unexpected rclone version: $VERSION" >&2
                exit 1
                ;;
        esac

        ARCHIVE="rclone-$VERSION-linux-arm64.zip"
        RELEASE_URL="https://downloads.rclone.org/$VERSION"

        TMP=$(mktemp -d)
        trap 'rm -rf "$TMP"' 0
        trap 'exit 1' 1 2 3 15

        mkdir -m 700 "$TMP/gnupg"

        echo "Downloading and verifying $ARCHIVE..."

        curl --fail --silent --show-error --location \
            --proto '=https' --proto-redir '=https' \
            "$RELEASE_URL/$ARCHIVE" \
            --output "$TMP/$ARCHIVE"

        curl --fail --silent --show-error --location \
            --proto '=https' --proto-redir '=https' \
            "$RELEASE_URL/SHA256SUMS" \
            --output "$TMP/SHA256SUMS"

        curl --fail --silent --show-error --location \
            --proto '=https' --proto-redir '=https' \
            'https://rclone.org/KEYS' \
            --output "$TMP/KEYS"

        gpg --batch --quiet --homedir "$TMP/gnupg" \
            --import "$TMP/KEYS"

        # Fingerprint documented in rclone's release-signing instructions.
        SIGNER=FBF737ECE9F8AB18604BD2AC93935E02FF3B54FA

        if ! gpg --batch --homedir "$TMP/gnupg" \
            --with-colons --fingerprint |
            grep -Fqx "fpr:::::::::$SIGNER:"; then
            echo 'Expected rclone release-signing key is absent' >&2
            exit 1
        fi

        VERIFY_STATUS=$(
            gpg --batch --homedir "$TMP/gnupg" \
                --status-fd 1 --verify "$TMP/SHA256SUMS" \
                2>/dev/null
        ) || {
            echo 'SHA256SUMS signature verification failed' >&2
            exit 1
        }

        if ! printf '%s\n' "$VERIFY_STATUS" |
            grep -F "[GNUPG:] VALIDSIG $SIGNER " >/dev/null; then
            echo 'SHA256SUMS was not signed by the expected key' >&2
            exit 1
        fi

        gpg --batch --quiet --homedir "$TMP/gnupg" \
            --decrypt "$TMP/SHA256SUMS" \
            > "$TMP/SHA256SUMS.verified"

        (
            cd "$TMP"
            sha256sum -c --ignore-missing SHA256SUMS.verified
        ) || {
            echo 'Downloaded rclone archive failed SHA256 verification' >&2
            exit 1
        }

        unzip -p "$TMP/$ARCHIVE" \
            "rclone-$VERSION-linux-arm64/rclone" \
            > "$TMP/rclone"

        [ -s "$TMP/rclone" ] || {
            echo 'Archive did not contain the Linux ARM64 rclone binary' >&2
            exit 1
        }

        # Stage alongside the existing binary; replace only after verification.
        cp "$TMP/rclone" "$RCLONE_BIN.new"
        chmod 700 "$RCLONE_BIN.new" 2>/dev/null || :
        mv -f "$RCLONE_BIN.new" "$RCLONE_BIN"

        echo "Placed $VERSION Linux ARM64 rclone at:"
        echo "  $RCLONE_BIN"
        echo 'It cannot be executed on an x86 Linux host; router setup tests it.'

        if [ ! -f "$REPO/.local/rclone.conf" ]; then
            : > "$REPO/.local/rclone.conf"
            echo 'Wizard: create a remote named exactly onedrive, sign in through your browser, select the drive, save and quit.'
            rclone --config "$REPO/.local/rclone.conf" config
        fi

        rclone --config "$REPO/.local/rclone.conf" \
            lsf onedrive: >/dev/null || {
            echo 'OneDrive listing failed on the Linux host' >&2
            exit 1
        }

        chmod 700 "$REPO/.local" "$REPO/.local/bin" 2>/dev/null || :
        chmod 600 \
            "$REPO/.local/rclone.conf" \
            "$REPO/.local/volume-id" \
            2>/dev/null || :

        echo 'USB provisioned. Never commit or share .local/.'
        echo 'Safely unmount it on Linux, insert it into the router, then run: sh setup.sh router'
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

        command -v git >/dev/null 2>&1 || {
            echo 'Install git via GL Plug-ins first' >&2
            exit 1
        }

        [ -f "$RCLONE_BIN" ] || {
            echo 'USB rclone binary missing; run: sh setup.sh host on Linux' >&2
            exit 1
        }

        echo 'Checking USB rclone binary:'
        "$RCLONE_BIN" version || {
            echo 'USB rclone cannot execute on this router.' >&2
            echo 'Check the USB mount options for noexec.' >&2
            exit 1
        }

        "$RCLONE_BIN" \
            --config "$REPO/.local/rclone.conf" \
            lsf onedrive: >/dev/null || {
            echo 'Cannot list OneDrive on the router' >&2
            exit 1
        }

        [ -t 0 ] || {
            echo 'Router setup needs an interactive SSH terminal for the download test' >&2
            exit 1
        }

        echo
        echo 'Enter the path of an existing, non-empty OneDrive file.'
        echo 'Use a path relative to the OneDrive root, for example:'
        echo '  Dokumente/example.jpg'
        printf 'OneDrive file path: '
        IFS= read -r TEST_FILE || {
            echo 'Could not read a file path' >&2
            exit 1
        }

        case "$TEST_FILE" in
            ''|/*|*:*)
                echo 'Enter a non-empty path relative to the OneDrive root' >&2
                exit 1
                ;;
        esac

        echo 'Reading the first 64 bytes; file contents go to /dev/null...'

        "$RCLONE_BIN" \
            --config "$REPO/.local/rclone.conf" \
            cat --head 64 "onedrive:$TEST_FILE" \
            > /dev/null || {
            echo 'OneDrive file-read test failed. Do not enable the backup cron job yet.' >&2
            exit 1
        }

        echo 'OneDrive listing and file-read tests passed.'
        echo 'No test file was saved to USB.'

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
