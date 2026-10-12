# GL-MT3000 OneDrive → USB (native rclone)

This is the **native OpenWrt package** variant. There is no Dockerfile, container runtime, image, or Docker-specific configuration. A scheduled script mirrors OneDrive **down** to `current/` and stores one dated `monthly/YYYY-MM/` USB copy. Nothing is uploaded to OneDrive by the script. Data is **not encrypted** at rest.

## Behavior and ransomware limits

- Every successful daily `rclone sync onedrive: current/` downloads changed/new files, deletes local files removed from OneDrive, and scans the file tree. Identical files are not downloaded again. `--max-delete 100` blocks runs with more than 100 deletions; it does **not** detect ransomware overwrites with the same names.
- On the first *successful* run of a new calendar month, the script fully copies `current/` to a new independent monthly folder, then deletes the previous monthly folder. It does not refresh the month's snapshot afterward. Budget approximately two copies, and temporarily around three during rollover. If copying fails, the prior month is retained, and an incomplete staging directory is retried on the next successful run.
- **Not ransomware-proof:** an infected Windows/macOS client can sync encrypted files to OneDrive, and the daily mirror will download them. An older monthly copy may save you **until it is rotated**, but if ransomware reaches OneDrive before the next monthly snapshot, that snapshot may capture the damage and delete the older copy. A compromised router, exposed SMB USB share, stolen USB drive, or someone with router root can alter/delete both copies. They share one physical disk; no immutable/offline backup exists here.
- Keep another *offline/disconnected or genuinely immutable* backup with multiple restore points; verify restores. Do not export `monthly/` or `.onedrive-backup/` as writable SMB shares. For OneDrive restore/version history, review your account's Microsoft 365 features and retention separately; they are not provided by this project.

## 1. Prepare GL-MT3000

1. Use a USB drive formatted as ext4 (formatting destroys existing files), connected to the router's USB-A port. Configure **persistent mount by UUID** to `/mnt/onedrive-backup` using the fstab/USB storage facilities of *your installed firmware*. The router ships with customized OpenWrt; check what your particular GL firmware offers. Don't reflash firmware or mix official OpenWrt package feeds into GL vendor firmware just for this. Choose stable power and a large enough disk (roughly 2× cloud size; up to 3× at rollover).
2. SSH into router as root, verify its time zone/NTP and **actual** package manager, available flash and USB mount:

   ```sh
   cat /etc/openwrt_release
   command -v opkg || command -v apk
   df -h /overlay /mnt/onedrive-backup
   grep ' /mnt/onedrive-backup ' /proc/mounts
   date
   ```

   Do not proceed if `/mnt/onedrive-backup` is merely an unmounted directory. You may use another *direct mountpoint* under `/mnt` by setting `BACKUP_ROOT=/mnt/yourmount` both manually and in cron, and adjusting provisioning paths.
3. Install rclone from **that firmware's configured repositories**, not from a mismatched OpenWrt release. Pick *one* block after checking package availability and flash space:

   ```sh
   opkg update && opkg install rclone   # only on opkg-based firmware with rclone in its feed
   # OR
   apk update && apk add rclone       # only on apk-based firmware with rclone in its feed
   rclone version
   ```

   If the package isn't available, stop rather than installing a random binary/build over the system. This native-only bundle cannot operate until a compatible rclone binary is installed.

## 2. Provision OneDrive on a PC

Use a recent rclone on a computer with a browser. In the extracted bundle run:

```sh
chmod +x provision.sh
./provision.sh ./rclone.conf
```

In rclone's wizard: new remote `n`, name **exactly** `onedrive`, storage `onedrive`, authorize with your browser, choose the intended personal/business drive, keep it and quit. The script tests access to `onedrive:` and sets file mode 600; it does **not** print or fabricate an OAuth token. `rclone.conf.example` contains invalid placeholders only. If you have a working `onedrive:` config already, use that file (locate it with `rclone config file`). This OAuth file holds sensitive tokens and must remain **writable** by router root so rclone can save refreshed tokens. You can choose the backend's documented read-only `access_scopes` during advanced configuration if supported by your account; default wizard permissions may include write access even though the backup script never writes to the remote. Test access before relying on it.

On the router, only *after confirming that the USB is mounted*:

```sh
mkdir -p /mnt/onedrive-backup/.onedrive-backup
: > /mnt/onedrive-backup/.onedrive-backup-volume
chmod 700 /mnt/onedrive-backup/.onedrive-backup
```

From the PC, replace the example address with your router's real LAN address:

```sh
scp ./rclone.conf root@192.168.8.1:/mnt/onedrive-backup/.onedrive-backup/rclone.conf
scp ./backup.sh root@192.168.8.1:/root/onedrive-backup.sh
```

Back on the router:

```sh
chmod 600 /mnt/onedrive-backup/.onedrive-backup/rclone.conf
chmod 700 /root/onedrive-backup.sh
rclone --config /mnt/onedrive-backup/.onedrive-backup/rclone.conf lsf onedrive:
```

Keep the router's admin interface and SSH off the public internet; keep the USB config directory out of file shares. The marker guards against writing to an unmounted mountpoint; it does not authenticate a physical drive.

## 3. Test, schedule, monitor

Run **dry-run** first, read the proposed transfers/deletions, then run the real download:

```sh
/root/onedrive-backup.sh dry-run > /tmp/onedrive-backup.log 2>&1
echo "dry-run exit=$?"
tail -n 50 /tmp/onedrive-backup.log
/root/onedrive-backup.sh run >> /tmp/onedrive-backup.log 2>&1
echo "run exit=$?"
ls -la /mnt/onedrive-backup/current /mnt/onedrive-backup/monthly
```

Note: a dry-run still contacts OneDrive and may refresh the token stored in the config; it does not touch `current/` or `monthly/`. `/tmp` logs are in RAM, not a potentially unmounted USB directory, and disappear after reboot. Do not redirect the cron log to `/mnt/onedrive-backup/backup.log`: the shell opens redirections **before** the script checks the mount, risking writes to the router's internal flash.

In the GL admin UI open **Advanced Settings → LuCI → System → Scheduled Tasks** and insert a daily 03:15 task (end with a newline):

```cron
15 3 * * * /root/onedrive-backup.sh run >> /tmp/onedrive-backup.log 2>&1
```

Save and on the router use `/etc/init.d/cron enable; /etc/init.d/cron restart`. **LuCI → System → Startup → Local Startup is NOT where you paste cron syntax.** If you want a boot-time catch-up, use a separate startup command that waits for USB, internet, and NTP; this bundle intentionally does not auto-start before those prerequisites. A powered-off router misses a cron run: check logs and run manually when it returns. Recheck rclone, cron, the USB mount, and the script after firmware upgrades.

For legitimate bulk deletions above 100, investigate first and temporarily run `MAX_DELETE=500 /root/onedrive-backup.sh dry-run`, then `MAX_DELETE=500 /root/onedrive-backup.sh run`. This limit cannot spot mass encryption of existing files; do not treat a successful job as a clean bill of health. If you detect ransomware, **stop the cron job immediately and preserve the USB disk and monthly snapshot** before further runs. Restore sample files to a clean computer only after identifying when infection started. Do not open unknown executables from compromised backups.

## 4. Restore and further protection

`current/` is your latest mirror; `monthly/YYYY-MM/` is a point-in-time copy from the first successful run of that month. Copy files from the chosen folder to a **clean separate computer**, not back into OneDrive automatically. Check both folders regularly and test that restored documents open. Monthly copy is a **full local USB-to-USB copy**, not incremental, so allow time for it to finish; the first cloud download is also substantial. An unexpected disk-full error leaves `current/` potentially incomplete while the previous monthly snapshot survives. A failed `sync` can likewise partially change `current/`.

The USB remains online and writable by the router. To protect against ransomware and router compromise, maintain a separate offline drive that is disconnected except during controlled backup, or an independent immutable versioned backup service. Microsoft 365 subscribers may also have OneDrive-wide restore for changes within the preceding 30 days; confirm availability for your plan and account. Do not mistake ext4 permissions or `chattr +i` under a root-run script for protection against an attacker who controls router root.

References: [OpenWrt cron](https://openwrt.org/docs/guide-user/base-system/cron), [rclone sync](https://rclone.org/commands/rclone_sync/), [OneDrive remote and OAuth scopes](https://rclone.org/onedrive/), [CISA ransomware backup guidance](https://www.cisa.gov/stopransomware/ransomware-guide), [OneDrive restore](https://support.microsoft.com/en-us/onedrive/restore-your-onedrive), [GL-MT3000 hardware](https://openwrt.org/toh/gl.inet/gl-mt3000).
