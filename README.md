# GL-MT3000 OneDrive → USB: native rclone, Git-on-USB

This directory is **the contents to commit to** `https://github.com/Jones14021/openwrt_rclone_cloud_sync`. It assumes a single USB partition, mounted automatically by **GL.iNet firmware 4.11.0** at `/tmp/mountd/disk1_part1`, containing a Git clone named `openwrt_rclone_cloud_sync`. Scripts execute **in place from USB**; `git pull` updates them without installing copies to router flash. This is a OneDrive-to-USB *download*, not an upload.

## 1. USB, file system, and mounting

GL firmware the default automount typically uses `/tmp/mountd/disk1_part1` (the drive contents are on USB, although its mountpoint directory is under RAM-backed `/tmp`). This README uses that exact location. Plug in the USB first and on the router check:

```sh
ls -la /tmp/mountd/ /tmp/mountd/disk1_part1/
grep ' /tmp/mountd/disk1_part1 ' /proc/mounts
df -h /tmp/mountd/disk1_part1
```

**Never** create `/tmp/mountd/disk1_part1` manually or clone to it unless `/proc/mounts` confirms that it is a real USB mount.

If the mount is missing, reseat the drive, refresh the GL Network Storage page, inspect `logread | grep -i mount` and `ls /dev/sd*`, then fix GL's own storage/automount facility. This package relies on GL's existing hotplug automount. It does not attempt a second manual mount, which could conflict with GL's Samba/WebDAV mounts.

`mount-check.sh` insists on a read-write `/dev/sd*` partition mounted at this path, a `.git` clone, and a provisioning marker. If the USB is unavailable at the scheduled time, cron skips the run safely; it does not catch up later. The assumption of one USB makes GL's `disk1_part1` name predictable **for this setup**, but the name is not a physical-drive identifier. Check it again after firmware changes.

>Tip: Use exFAT if you want to not bother with file permissions and potentially use the disk on Windows systems for recovering data.

**Use ext4 if possible.** Reformat on your Linux PC *before cloning*—formatting destroys existing contents—and ensure this GL firmware can mount ext4. FAT32 technically allows a repository and backups of small files using `sh script.sh`, but it has no real per-file Unix mode/owner protection, a single-file limit just below 4 GiB, coarse timestamps, and no ext4-style journal. The OAuth token is exposed to anyone who can read the drive.

The code accepts FAT32 so you can test, but do **not** rely on the shown 30 GB FAT stick for important backups, especially if OneDrive contains large files. The approximately 30 GB stick can hold at most around 15 GB of cloud data for `current` plus `monthly`; rollover may require **temporarily three full copies**—around 10 GB of cloud data before overhead. `--modify-window 2s` helps with FAT timestamp granularity but cannot address its file-size or permission limits.

For Windows access to an ext4 disk, restore over the LAN from a carefully scoped share or via an ext4-capable Linux host. Do not expose the secret folder.

## 2. Install and clone

On the GL admin page, open **Applications → Plug-ins**, update the package list, then search for and install **`git`**, **git-http** and **`rclone`**. Verify through SSH:

```sh
git --version
rclone version
```

If either package is not offered or installation fails, do not assume it was installed; stop and diagnose.

Packages, their configuration, and the manually added cron entry necessarily reside on the router. The project scripts, Git checkout, OAuth token, and all backup files stay on USB. Transient run logs and locks use `/tmp` RAM.

After the files in this project have been committed to the GitHub repository, put the empty, mounted drive on your Linux computer and **clone into its root**. Replace the example mount path with your real Linux mountpoint:

```sh
USB=/run/media/$USER/INTENSO  # Example only: inspect your mount first
findmnt "$USB"

git clone [https://github.com/Jones14021/openwrt_rclone_cloud_sync](https://github.com/Jones14021/openwrt_rclone_cloud_sync) \
    "$USB/openwrt_rclone_cloud_sync"

cd "$USB/openwrt_rclone_cloud_sync"

# Only needed on FAT32 or a filesystem that cannot retain executable bits:
git config core.filemode false
```

Do not blindly use the example Linux mount path, which differs across distributions. Git's `core.filemode false` only suppresses false mode changes in Git; it does *not* secure token files on FAT.

All runtime paths are anchored to the router's USB mount path above. There are no copies in `/root` or `/mnt`. Ensure `.gitignore` includes `.local/` and `backup/`. **Never commit** `.local/rclone.conf` or backed-up data.

## 3. Provision on Linux

On the Linux host, while the USB is attached and you have a browser and rclone installed:

```sh
cd "$USB/openwrt_rclone_cloud_sync"
sh ./setup.sh host
```

The wizard creates a remote named **exactly** `onedrive` in the untracked `.local/rclone.conf`, performs interactive browser authentication, and verifies a listing. It also creates a USB-only marker, `.local/volume-id`.

If you already have an rclone remote under another name, import its credentials under `onedrive` using rclone on the Linux host; do not edit JSON tokens by hand. `rclone.conf.example` is intentionally invalid. Never put the real configuration into the public repository.

Safely eject the USB from Linux, insert it into the router, and wait for GL's automount.

## 4. Verify on the router

Over SSH, run:

```sh
sh /tmp/mountd/disk1_part1/openwrt_rclone_cloud_sync/mount-check.sh
sh /tmp/mountd/disk1_part1/openwrt_rclone_cloud_sync/setup.sh router
sh /tmp/mountd/disk1_part1/openwrt_rclone_cloud_sync/backup.sh dry-run
```

`setup.sh router` verifies the mount, checks that Git and rclone are installed, and lists OneDrive. **It does not create, modify, enable, or restart a cron job.**

It also checks `/etc/crontabs/root` for the *exact* cron entry shown below. If present, it says so. If absent, it prints the entry you need to add. This check is informational: an absent entry does not prevent manual backup testing.

## 5. Add the schedule manually

In the GL admin interface, open **Advanced Settings → LuCI → System → Scheduled Tasks**. Add this single line for a daily run at 03:15, and save it:

```cron
15 3 * * * /bin/sh /tmp/mountd/disk1_part1/openwrt_rclone_cloud_sync/backup.sh run >> /tmp/onedrive-usb-backup.log 2>&1
```

Do **not** put that crontab line in **System → Startup → Local Startup**.

After saving, check that LuCI retained the line:

```sh
grep -F 'openwrt_rclone_cloud_sync/backup.sh' /etc/crontabs/root
sh /tmp/mountd/disk1_part1/openwrt_rclone_cloud_sync/setup.sh router
```

If you edited the crontab but the task is not taking effect, restart cron manually:

```sh
/etc/init.d/cron restart
```

The check in `setup.sh router` requires the **exact** line above. If you intentionally change the schedule, command, or log path, it will say the expected entry is missing even if your alternative is valid. It will never replace your entry or add a duplicate.

A powered-off router misses its scheduled run. When it comes back, inspect the log and run a backup manually if needed.

## 6. First backup and normal operation

Review the dry run before starting the real download:

```sh
sh /tmp/mountd/disk1_part1/openwrt_rclone_cloud_sync/backup.sh dry-run \
    > /tmp/onedrive-usb-backup.log 2>&1

echo "dry-run exit=$?"
tail -n 60 /tmp/onedrive-usb-backup.log
```

Then run the backup:

```sh
sh /tmp/mountd/disk1_part1/openwrt_rclone_cloud_sync/backup.sh run \
    >> /tmp/onedrive-usb-backup.log 2>&1

echo "run exit=$?"
```

The log is in `/tmp`—RAM, lost on reboot—rather than redirected to a path on the USB. A shell opens its redirection **before** the script can check whether USB is mounted; redirecting directly to a missing USB mountpoint could otherwise write to the router's internal filesystem.

Inspect `backup/current/` and `backup/monthly/YYYY-MM/` on the USB. The first OneDrive download is full; subsequent syncs transfer changed files. On the first successful backup each month, the script makes an independent full USB-to-USB snapshot. Only after publishing the new snapshot does it remove the previous month.

A remote reported as empty causes the backup to abort.

## 7. File modes and updates

| Path in the repository | Ext4 mode | Purpose |
|---|---:|---|
| `README.md`, `.gitignore`, `rclone.conf.example` | `0644` | Project text; the example is not a token |
| `setup.sh`, `backup.sh`, `mount-check.sh` | `0755` | Tracked executable scripts; `sh file.sh` also works without an executable bit |
| `.local/`, `backup/` | `0700` directories | Non-public state and backups |
| `.local/rclone.conf`, `.local/volume-id` | `0600` | OAuth credentials and USB marker |
| `backup/current/`, `backup/monthly/` and their files | Restrictive where supported | Backup data; exact modes may vary |

On ext4, set script modes in your Git checkout before committing:

```sh
chmod 755 setup.sh backup.sh mount-check.sh
git add --chmod=+x setup.sh backup.sh mount-check.sh
git ls-files -s
```

`setup.sh host` attempts to set `0600` on the real config. On FAT32, `chmod` cannot provide effective independent permissions per file; visible modes come from mount options. Do not regard a displayed `-rw-------` as protection if someone removes and reads the USB elsewhere.

Keep Samba/WebDAV WAN access off, avoid sharing the USB root or `.local/`, and consider disabling file services if they are not needed. The screenshot shows LAN Samba and WebDAV enabled. This project does not change those settings.

To update the code on the router, **only when no backup is running**:

```sh
cd /tmp/mountd/disk1_part1/openwrt_rclone_cloud_sync
sh ./mount-check.sh
git status --short
git pull --ff-only
```

The next cron run uses the updated USB scripts; no project-file installation is required. Never put `.local/` or `backup/` into version control. On FAT32, `git config core.filemode false` in the checkout can quiet spurious mode changes. Pull only trusted changes: these scripts run as router root.

If updating the USB on Linux instead, safely eject it before reinserting it into the router.

## 8. Removal, power loss, and recovery

- Before intentional removal, ensure no backup or `git pull` is running, run `sync` on the router, and use GL's **Eject** control in Network Storage.
- If USB disappears during a run, the script checks the mount and polls `/proc/mounts` every two seconds during rclone sync and monthly copying. It attempts to stop the active operation and checks again before rotation. This reduces, but **cannot eliminate**, the race in which an auto-unmounted path might receive writes into `/tmp` RAM.
- After a surprise removal, `backup/current/` may be incomplete and the filesystem may need repair on a Linux PC. Check the mount, filesystem, and logs before retrying.
- After a power cut, `.new-YYYY-MM/` may be an incomplete monthly snapshot. The previous published month is retained until a new snapshot has been copied and renamed. On recovery, check the filesystem and rerun the job. No snapshot is guaranteed if the very first backup never finished.
- For ransomware, `current/` can import encrypted files, and a single monthly snapshot can age out. This is not immutable, offline, or offsite protection. On suspicion, stop the scheduled task and preserve the USB; maintain a separate disconnected or genuinely immutable versioned backup. Restore to a clean computer, not automatically back to OneDrive.

References: [GL Network Storage](https://docs.gl-inet.com/router/en/4/interface_guide/network_storage/), [GL Plug-ins](https://docs.gl-inet.com/router/en/4/interface_guide/plugins/), [rclone sync](https://rclone.org/commands/rclone_sync/), [OpenWrt cron](https://openwrt.org/docs/guide-user/base-system/cron).
