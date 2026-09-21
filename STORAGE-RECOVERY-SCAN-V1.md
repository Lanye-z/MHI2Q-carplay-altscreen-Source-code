# Storage Recovery Scan V1

This branch is derived from `experiment/oem-layout-second-screen_v2` and exists only to inspect historical AltScreen / MMI-Cockpit-Carplay storage residue.

## Scope

The V1 recovery tool is **read-only with respect to vehicle persistent filesystems**.

It does not:

- remount `/mnt/system` writable;
- remount `/mnt/app` writable;
- delete files;
- move files;
- copy or overwrite vehicle files;
- attempt INSTALL, START, RESTORE, or cleanup.

It only reads known historical locations and writes a report.

## GEM page

A parallel `Customization` page is added:

`MMI-Cockpit-Carplay Storage Recovery`

The only action in V1 is:

`SCAN STORAGE - READ ONLY`

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

Deletion rules should only be added after a real vehicle scan has been reviewed.

## Recommended vehicle workflow

1. Put this branch/package on the SD card.
2. Open `Customization -> MMI-Cockpit-Carplay Storage Recovery`.
3. Run `SCAN STORAGE - READ ONLY`.
4. Copy the generated `storage_scan_*` directory from the SD card.
5. Review the report before implementing or running any cleanup action.
