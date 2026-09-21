# Storage Recovery Scan V1

This branch is derived from `experiment/oem-layout-second-screen_v2` and provides a recovery toolbox for historical AltScreen / MMI-Cockpit-Carplay storage residue. It keeps the original read-only scanner and adds one reviewed, SD-backed cleanup action.

## Scope

The **SCAN** action remains read-only with respect to vehicle persistent filesystems.

The **CLEAN** action is intentionally narrow. It only removes the reviewed legacy files listed below, after copying every target to SD and verifying the backup. It refuses to run without a writable Toolbox SD card, when the AltScreen operation lock is present, or when the live startup file cannot be checksummed.

Neither action performs INSTALL, START, RESTORE, or rewrites the live `startup.sh` / JSON / firewall configuration.

## GEM page

A parallel `Customization` page is added:

`MMI-Cockpit-Carplay Storage Recovery`

The page contains two actions:

- `SCAN STORAGE - READ ONLY`
- `CLEAN CONFIRMED LEGACY FILES`

The cleanup button logs every candidate, backup, deletion, skip and refusal.

## Report destination

Preferred:

`<SD>/MMI-Cockpit-Carplay/logs/storage-recovery/storage_scan_<timestamp>_<pid>/`

Fallback when SD is absent or unwritable:

`/tmp/MMI-Cockpit-Carplay/logs/storage-recovery/storage_scan_<timestamp>_<pid>/`

The report contains:

- raw `df` output for `/mnt/system`, `/mnt/app`, `/tmp`, and SD;
- directory listings and `du` output for the historical locations touched by the project;
- candidate historical transaction/staging files;
- rollback copies that require manual review;
- legacy hooks/markers that require manual review;
- protected/current live files;
- checksums for key live files;
- live references to AltScreen-related startup/config entries;
- SD state, backup, and staging directory listings.

## Scanned vehicle locations

- `/mnt/system/etc/boot`
- `/etc/boot` (alternate startup location used by some builds)
- `/mnt/system/etc/eso/production`
- `/mnt/system/etc`
- `/mnt/app/root`
- `/mnt/app/root/carplay-altscreen`
- `/mnt/app/root/hooks`
- `/mnt/app/root/lib-target`
- `/mnt/app/eso/hmi/lsd/jars`
- `/tmp/MMI-Cockpit-Carplay`

The scanner also lists the current SD-side:

- `MMI-Cockpit-Carplay/state`
- `MMI-Cockpit-Carplay/backup`
- `MMI-Cockpit-Carplay/staging`

## Candidate classes

The scanner intentionally does **not** decide what may be deleted.

It only classifies evidence as:

- `TEMP_CANDIDATE` — historical transaction/staging naming;
- `ROLLBACK_REVIEW` — previous-runtime or previous-mirror rollback data;
- `LEGACY_REVIEW` — historical hooks/markers that may still be referenced;
- `SD_REVIEW` — old SD transaction/staging data, including operation-lock evidence.

Historical HMI JAR staging, legacy `lib-target`/`hooks` atomic staging, BaseVideo3 boot scratch, diagnostics scratch, firewall scratch, and previous-runtime rollback paths are explicitly included in the candidate scan.

The generated summary always states:

`CLASSIFICATION=SCAN_ONLY_NOT_DELETE_AUTHORITY`

The reviewed cleanup whitelist is:

- `/mnt/system/etc/boot/startup.sh.basevideo3.{block,clean,new,original}.<numeric PID>`
- `/mnt/system/etc/boot/startup.sh.mirror.{block,clean,new,original}.<numeric PID>`
- `/mnt/app/root/hooks/libcp_mirror.so` only when the MMI Mirror runtime is absent and no live config references the hook
- `/mnt/app/root/carplay-altscreen/tmp/mirror.previous` only when the MMI Mirror runtime is absent

No other scanned candidate is deleted by this cleanup action.

Before deletion, each target is backed up under:

`<SD>/MMI-Cockpit-Carplay/cleanup-backup/cleanup_<timestamp>_<pid>/`

Cleanup logs are written under:

`<SD>/MMI-Cockpit-Carplay/logs/storage-recovery/cleanup_<timestamp>_<pid>/`

The cleanup report includes `DF.before.txt`, `DF.after.txt`, `delete_manifest.txt`, `delete_results.txt`, `skipped_files.txt`, live checksums before/after, a completion marker, and the automatic post-clean scan output.

## Recommended vehicle workflow

1. Put this branch/package on the SD card and update the Toolbox scripts/GEM.
2. Open `Customization -> MMI-Cockpit-Carplay Storage Recovery`.
3. Run `SCAN STORAGE - READ ONLY` when a fresh inventory is desired.
4. Run `CLEAN CONFIRMED LEGACY FILES` only for the reviewed historical residue described above.
5. Wait for `CLEANUP=PASS`, `STARTUP_UNCHANGED=YES`, and `POST_SCAN=PASS`.
6. Review or share the complete `logs/storage-recovery/cleanup_*` directory. The deleted originals remain recoverable from `cleanup-backup/cleanup_*` on the SD card.
