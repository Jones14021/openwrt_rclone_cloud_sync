#!/bin/sh
set -eu
umask 077
OUT=${1:-./rclone.conf}
[ ! -e "$OUT" ] || { echo "Refusing to overwrite existing file: $OUT" >&2; exit 1; }
command -v rclone >/dev/null 2>&1 || { echo 'Install rclone on the browser-equipped computer first.' >&2; exit 1; }
: > "$OUT"
chmod 600 "$OUT"
echo 'Use rclone wizard: n -> name onedrive -> storage onedrive -> browser login -> select your drive -> confirm -> q.'
if ! rclone --config "$OUT" config; then
    echo "Wizard failed. Inspect/delete incomplete file: $OUT" >&2
    exit 1
fi
if ! rclone --config "$OUT" lsf onedrive: >/dev/null; then
    echo "Could not list onedrive:. Fix it with rclone --config FILE config" >&2
    exit 1
fi
chmod 600 "$OUT"
printf 'Config ready: %s. Treat it as a secret; transfer it securely to USB.\n' "$OUT"
