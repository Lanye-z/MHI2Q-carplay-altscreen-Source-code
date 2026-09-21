#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
SCAN="$ROOT/Toolbox/scripts/altscreen_storage_recovery_scan.sh"
GEM="$ROOT/Toolbox/GEM/mqb-carplayAltScreenStorageRecovery.esd"

fail(){ echo "STORAGE_RECOVERY_SCAN_TEST=FAIL: $*" >&2; exit 1; }

sh -n "$SCAN" || fail "scanner shell syntax"
[ -s "$GEM" ] || fail "GEM page missing"

grep -Fq 'READ_ONLY_SCAN=YES' "$SCAN" || fail "read-only marker missing"
grep -Fq 'DELETE_PERFORMED=NO' "$SCAN" || fail "delete marker missing"
grep -Fq 'MMI-Cockpit-Carplay/logs/storage-recovery' "$SCAN" || fail "SD report path missing"
grep -Fq '/tmp/MMI-Cockpit-Carplay/logs/storage-recovery' "$SCAN" || fail "/tmp fallback missing"
grep -Fq 'SCAN STORAGE - READ ONLY' "$GEM" || fail "GEM scan action missing"
grep -Fq 'screen "MMI-Cockpit-Carplay Storage Recovery" Customization' "$GEM" || fail "GEM page is not parallel under Customization"

if grep -Eq '(^|[[:space:]])mount[[:space:]]' "$SCAN"; then
    fail "scanner must not mount or remount vehicle filesystems"
fi
if grep -Eq '(^|[[:space:]])rm[[:space:]]' "$SCAN"; then
    fail "scanner must not delete files"
fi
if grep -Eq '(^|[[:space:]])mv[[:space:]]' "$SCAN"; then
    fail "scanner must not move vehicle files"
fi
if grep -Eq '(^|[[:space:]])cp[[:space:]]' "$SCAN"; then
    fail "scanner must not copy vehicle files"
fi

tmp=$(mktemp -d)
live="$tmp/live"
vol="$tmp/vol"

mkdir -p \
    "$live/mnt/system/etc/boot" \
    "$live/mnt/system/etc/eso/production" \
    "$live/mnt/app/root/carplay-altscreen/lib" \
    "$live/mnt/app/root/hooks" \
    "$live/mnt/app/eso/hmi/lsd/jars" \
    "$live/tmp" \
    "$vol/Toolbox" \
    "$vol/MMI-Cockpit-Carplay/state" \
    "$vol/MMI-Cockpit-Carplay/backup" \
    "$vol/MMI-Cockpit-Carplay/staging"

printf '%s\n' '#!/bin/sh' > "$live/mnt/system/etc/boot/startup.sh"
printf '%s\n' 'legacy-clean' > "$live/mnt/system/etc/boot/startup.sh.basevideo3.clean.111"
printf '%s\n' 'stock-json' > "$live/mnt/system/etc/eso/production/smartphone_integrator.json"
printf '%s\n' 'partial-json' > "$live/mnt/system/etc/eso/production/.smartphone_integrator.json.new.222"
printf '%s\n' 'dio-json' > "$live/mnt/system/etc/eso/production/dio_manager.json"
printf '%s\n' 'pf' > "$live/mnt/system/etc/pf.conf"
printf '%s\n' 'jar' > "$live/mnt/app/eso/hmi/lsd/jars/carplay_hook.jar"
printf '%s\n' 'runtime' > "$live/mnt/app/root/carplay-altscreen/.mmi-cockpit-carplay-runtime-owner"
printf '%s\n' 'hook' > "$live/mnt/app/root/carplay-altscreen/lib/libcarplay_altscreen.so"
mkdir -p "$live/mnt/app/root/.carplay-altscreen.new.333"
printf '%s\n' 'partial-runtime' > "$live/mnt/app/root/.carplay-altscreen.new.333/partial"
mkdir -p "$live/mnt/app/root/.carplay-altscreen.previous"
printf '%s\n' 'old-runtime' > "$live/mnt/app/root/.carplay-altscreen.previous/.mmi-cockpit-carplay-runtime-owner"
printf '%s\n' 'legacy-hook' > "$live/mnt/app/root/hooks/libcarplay_altscreen.so"
printf '%s\n' 'child-log' > "$vol/MMI-Cockpit-Carplay/state/.child-install.444"

snapshot_tree(){
    find "$1" -type f -exec cksum {} \; | sort
}

before=$(snapshot_tree "$live")

out="$tmp/scan.out"
ALTSCREEN_RECOVERY_TESTING=1 \
ALTSCREEN_RECOVERY_ROOT="$live" \
ALTSCREEN_RECOVERY_VOLUME="$vol" \
sh "$SCAN" > "$out" 2>&1 || {
    cat "$out" >&2
    fail "scanner execution"
}

after=$(snapshot_tree "$live")
[ "$before" = "$after" ] || fail "scanner modified simulated vehicle files"

grep -Fq 'STORAGE_RECOVERY_SCAN=PASS' "$out" || fail "PASS marker missing"
grep -Fq 'READ_ONLY_SCAN=YES' "$out" || fail "stdout read-only marker missing"
grep -Fq 'DELETE_PERFORMED=NO' "$out" || fail "stdout delete marker missing"
grep -Fq 'OUTPUT_STORAGE=SD' "$out" || fail "SD output was not preferred"

last="$vol/MMI-Cockpit-Carplay/logs/storage-recovery/LAST_SCAN.txt"
[ -s "$last" ] || fail "LAST_SCAN pointer missing"
report=$(cat "$last")
[ -f "$report/SCAN_COMPLETE" ] || fail "scan completion marker missing"
[ -s "$report/SUMMARY.txt" ] || fail "summary missing"
[ -s "$report/project_candidates.txt" ] || fail "candidate report missing"
[ -s "$report/DF.txt" ] || fail "df report missing"
[ -s "$report/system_boot.txt" ] || fail "system boot listing missing"
[ -s "$report/app_root.txt" ] || fail "app root listing missing"
[ -s "$report/sd_backup.txt" ] || fail "SD backup listing missing"

grep -Fq '/mnt/system/etc/boot/startup.sh.basevideo3.clean.111' "$report/project_candidates.txt" ||
    fail "historical startup temp not detected"
grep -Fq '/mnt/system/etc/eso/production/.smartphone_integrator.json.new.222' "$report/project_candidates.txt" ||
    fail "historical JSON staging not detected"
grep -Fq '/mnt/app/root/.carplay-altscreen.new.333' "$report/project_candidates.txt" ||
    fail "historical runtime staging not detected"
grep -Fq '/mnt/app/root/.carplay-altscreen.previous' "$report/project_candidates.txt" ||
    fail "rollback review entry not detected"
grep -Fq 'CLASSIFICATION=SCAN_ONLY_NOT_DELETE_AUTHORITY' "$report/SUMMARY.txt" ||
    fail "scan-only classification missing"

live2="$tmp/live-no-sd"
mkdir -p "$live2/mnt/system/etc/boot" "$live2/mnt/app/root" "$live2/tmp"
printf '%s\n' '#!/bin/sh' > "$live2/mnt/system/etc/boot/startup.sh"

out2="$tmp/scan-no-sd.out"
ALTSCREEN_RECOVERY_TESTING=1 \
ALTSCREEN_RECOVERY_ROOT="$live2" \
ALTSCREEN_RECOVERY_VOLUME="" \
sh "$SCAN" > "$out2" 2>&1 || {
    cat "$out2" >&2
    fail "/tmp fallback execution"
}

grep -Fq 'OUTPUT_STORAGE=TMP' "$out2" || fail "/tmp fallback not selected"
[ -s "$live2/tmp/MMI-Cockpit-Carplay/logs/storage-recovery/LAST_SCAN.txt" ] ||
    fail "/tmp LAST_SCAN pointer missing"

echo "STORAGE_RECOVERY_SCAN_TEST=PASS read_only=1 sd_preferred=1 tmp_fallback=1 historical_candidates=1"
