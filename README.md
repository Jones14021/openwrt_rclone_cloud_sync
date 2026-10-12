# GL-MT3000 OneDrive → USB: native rclone, Git-on-USB

This directory is **the contents to commit to** `https://github.com/Jones14021/openwrt_rclone_cloud_sync`. It assumes a single USB partition, mounted automatically by **GL.iNet firmware 4.11.0** at `/tmp/mountd/disk1_part1`, containing a Git clone named `openwrt_rclone_cloud_sync`. Scripts execute **in place from USB**; `git pull` updates them without installing copies to router flash. This is a OneDrive-to-USB *download*, not an upload.

## 1. USB, file system, and mounting

GL firmware the default automount typically uses `/tmp/mountd/disk1_part1` (the drive contents are on USB, although its mountpoint directory is under RAM-backed `/tmp`). This README uses that exact location. Plug in the USB first and on the router check:

```sh
ls -la /tmp/mountd/ /tmp/mountd/disk1_part1/
grep ' /tmp/mountd/disk1_part1 ' /proc/mounts
df -h /tmp/mountd/disk1_part1
```

**Never** create `/tmp/mountd/disk1_part1` manually or clone to it unless `/proc/mounts` confirms it is a real USB mount. If missing, reseat the drive, refresh the GL Network Storage page, inspect `logread | grep -i mount` and `ls /dev/sd*`, then fix GL's own storage/automount facility. This package relies on the existing GL hotplug automount, waits for no new storage itself, and never tries a second manual mount (which can conflict with GL's Samba/WebDAV mounts). `mount-check.sh` insists on a RW `/dev/sd*` partition mounted at this path, a `.git` clone and a provisioning marker. If unavailable at scheduled time, cron skips the run safely; it does not catch up later. The assumption of one USB makes GL's `disk1_part1` name predictable **for this setup**, but this name is not a physical-drive identifier; check it again after firmware changes.

**Use ext4 if possible.** Reformat on your Linux PC *before cloning* (formatting destroys existing contents), and ensure this GL firmware can mount ext4. FAT32 technically allows a repository and backups of small files using `sh script.sh`, but it has no real per-file Unix mode/owner protection, a single-file limit just below 4 GiB, coarse timestamps, no ext4-style journal, and the OAuth token is exposed to anyone who can read the drive. The code accepts FAT32 so you can test, but do **not** rely on the shown 30 GB FAT stick for important backups, especially if OneDrive contains large files. The approximately 30 GB stick can hold at most ~15 GB cloud data for `current` plus `monthly`, and rollover may require **temporarily three full copies** (~10 GB cloud data, before overhead). `--modify-window 2s` helps with FAT timestamp granularity, but cannot address its file-size or permission limits. For Windows access to an ext4 disk, restore over the LAN from a carefully scoped share or via an ext4-capable Linux host; don't expose the secret folder.

## 2. Install and clone

On the GL admin page: **Applications → Plug-ins → Update**, then search for and install **`git`** and **`rclone`**. This firmware is a customized OpenWrt 21.02 snapshot; use its own Plug-ins UI rather than mixing release feeds. Verify through SSH: `git --version; rclone version`. If a package is not offered, do not assume it was installed; stop and diagnose. Packages, their configuration, and the cron entry necessarily reside on router flash; *scripts, Git checkout, OAuth token, logs of actual data, and all backup files* stay on USB (transient run logs/locks use `/tmp` RAM).

After the files in this bundle have been committed to the stated GitHub repository, put the empty, mounted drive on your Linux computer and **clone into its root** (replace the mount path with your real Linux mountpoint):

```sh
USB=/run/media/$USER/INTENSO  # example only: inspect `findmnt` before running
findmnt "$USB"
git clone https://github.com/Jones14021/openwrt_rclone_cloud_sync "$USB/openwrt_rclone_cloud_sync"
cd "$USB/openwrt_rclone_cloud_sync"
# Only needed on FAT32 / filesystems that cannot retain executable bits:
git config core.filemode false
```

Do not blindly use the example Linux mount path, which differs across distros. Git's `core.filemode false` only suppresses false mode changes in Git; it does *not* secure token files on FAT. All runtime paths are anchored to the router's USB mount path above; there are no copies in `/root` or `/mnt`. Make sure `.gitignore` includes `.local/` and `backup/`; **never commit** `.local/rclone.conf` or backed-up data.

## 3. Provision from Linux and router

On the Linux host, while USB is attached and you have a browser and rclone installed:

```sh
cd "$USB/openwrt_rclone_cloud_sync"
sh ./setup.sh host
```

The wizard creates a remote named **exactly** `onedrive` in the untracked `.local/rclone.conf`, performs interactive browser authentication and verifies a listing. It also creates a USB-only marker `.local/volume-id`. If you already have an rclone remote under another name, import its credentials under `onedrive` using rclone on the Linux host; do not edit JSON tokens by hand. See `rclone.conf.example` for an intentionally invalid example. Avoid backing up your own tokens into the public repo. Safely eject the USB from Linux, insert in router, wait for GL automount, and in SSH:

```sh
sh /tmp/mountd/disk1_part1/openwrt_rclone_cloud_sync/mount-check.sh
sh /tmp/mountd/disk1_part1/openwrt_rclone_cloud_sync/setup.sh router
sh /tmp/mountd/disk1_part1/openwrt_rclone_cloud_sync/backup.sh dry-run
```

`setup.sh router` verifies the mount, Git and rclone, lists OneDrive, and idempotently appends **one** daily 03:15 cron entry to `/etc/crontabs/root` before restarting cron. That's the minimal unavoidable router-local configuration; it does not copy or install any project code or credentials there. You can instead place the same cron line manually in LuCI **System → Scheduled Tasks**. Do not put crontab syntax in **System → Startup → Local Startup**. Its schedule is:

```cron
15 3 * * * /bin/sh /tmp/mountd/disk1_part1/openwrt_rclone_cloud_sync/backup.sh run >> /tmp/onedrive-usb-backup.log 2>&1
```

Run the real backup only after reviewing the dry-run log:

```sh
tail -n 60 /tmp/onedrive-usb-backup.log
sh /tmp/mountd/disk1_part1/openwrt_rclone_cloud_sync/backup.sh run >> /tmp/onedrive-usb-backup.log 2>&1
echo "exit=$?"
```

If an interactive dry run does not redirect output, you will see it in the terminal. The daily cron log is in `/tmp` (RAM, lost on reboot) so a missing USB can never cause shell redirection to write backup logs to internal flash. You can inspect `backup/current/` and `backup/monthly/YYYY-MM/` on USB. The first download is full; subsequent syncs transfer changed files. On the first successful backup each month, an independent full USB-to-USB snapshot is created; only after publishing the new one is the previous month removed. `--max-delete 100` blocks unexpected mass deletions, **not changed/encrypted files**. A remote reported as empty causes an abort.

## 4. Modes and updating

| Path in the repository | Ext4 mode | Why |
|---|---|---|
| `README.md`, `.gitignore`, `rclone.conf.example` | `0644` | Public project text; example is not a token. |
| `setup.sh`, `backup.sh`, `mount-check.sh` | `0755` | Conventional tracked executable scripts; `sh file.sh` works even without executable bit. |
| `.local/`, `backup/` | `0700` directories | Non-public state and backups, created by scripts with umask `077`. |
| `.local/rclone.conf`, `.local/volume-id` | `0600` | Real OAuth credentials and local USB marker. |
| `backup/current/`, `backup/monthly/` and their files | `0700` dirs / `0600` files where possible | Locally downloaded data; exact mode can vary for recovered metadata. |

On ext4, set script modes in your local Git repository before commit (`chmod 755 *.sh; git add --chmod=+x *.sh`) and check `git ls-files -s`; `setup.sh host` attempts `0600` on the config. On FAT32, `chmod` cannot give individual files effective independent permissions: visible modes come from the mount options. **Do not treat a displayed `-rw-------` as an access-control guarantee if the USB is removed and read elsewhere.** Keep Samba/WebDAV WAN access off, avoid sharing USB root or `.local`, and consider disabling the file services altogether. The screenshot has LAN Samba and WebDAV enabled; verify shares/users explicitly. This setup does not alter those settings.

To update, when no backup is running:

```sh
cd /tmp/mountd/disk1_part1/openwrt_rclone_cloud_sync
sh ./mount-check.sh
git status --short
git pull --ff-only
```

The next cron run uses the updated USB scripts; no reinstallation needed. Never `git pull` while a backup runs, and never put `.local/` or `backup/` into version control. If the repo is on FAT, `git config core.filemode false` on the router checkout can quiet spurious status changes. Pull only trusted changes: these scripts run as router root. If updating on Linux, safely eject before inserting in router.

## 5. Unplugging, power loss, and recovery

- Before intentional removal, ensure no backup is running, run `sync` on the router and use GL's **Eject** control shown in Network Storage. Never pull it during a `git pull` or `rclone` run.
- On a surprise unplug, `mount-check.sh` fails at start and the job polls `/proc/mounts` every two seconds while rclone syncs or a monthly snapshot copies. The script attempts to stop the active process and checks the mount again before rotation. That *reduces* the window in which the auto-unmounted path might receive writes into `/tmp` RAM; it cannot eliminate all races. The output may be partial and the USB filesystem may need repair on a Linux PC. Check `df`, `grep ... /proc/mounts`, logs, and mount state before retrying. USB on `/tmp/mountd` prevents unintended writes to persistent router flash in this design; filling RAM can still disrupt the router if an unplug happens in a narrow race.
- A power loss cannot be fixed in software. A sync may have partly changed `backup/current/`; `.new-YYYY-MM/` may contain an incomplete monthly snapshot. The *previous published month* is left alone until the new month is fully copied and renamed; after power recovery and filesystem checking, rerun the job. If failure happens during deletion of the old month, a partly deleted old month may remain alongside the newly published month. No snapshot is guaranteed on the very first run before it finishes. Ext4 with a clean unmount and reliable power is preferable to FAT for recovery.
- For ransomware, the current mirror can import encrypted files, and a single monthly snapshot can age out. This is not immutable, offline or offsite protection. Preserve the USB and stop cron on suspicion; maintain a separate disconnected or truly immutable versioned backup. Restore to a clean computer, not automatically back to OneDrive.

References: [GL Network Storage](https://docs.gl-inet.com/router/en/4/interface_guide/network_storage/), [GL Plug-ins](https://docs.gl-inet.com/router/en/4/interface_guide/plugins/), [GL automount discussion](https://forum.gl-inet.com/t/why-is-external-storage-device-auto-mounted-at-tmp-mountd-disk1-part1/35177), [Git filemode](https://git-scm.com/docs/git-config), [rclone sync](https://rclone.org/commands/rclone_sync/), [OpenWrt cron](https://openwrt.org/docs/guide-user/base-system/cron).
