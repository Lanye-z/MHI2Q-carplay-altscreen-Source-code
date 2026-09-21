#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
CLEAN="$ROOT/Toolbox/scripts/altscreen_storage_recovery_cleanup.sh"
SCAN="$ROOT/Toolbox/scripts/altscreen_storage_recovery_scan.sh"
GEM="$ROOT/Toolbox/GEM/mqb-carplayAltScreenStorageRecovery.esd"

fail(){ echo "STORAGE_RECOVERY_CLEANUP_TEST=FAIL: $*" >&2; exit 1; }

sh -n "$CLEAN" || fail "cleanup shell syntax"
[ -s "$SCAN" ] || fail "scanner missing"
[ -s "$GEM" ] || fail "GEM missing"

grep -Fq 'CLEAN CONFIRMED LEGACY FILES' "$GEM" || fail "cleanup GEM action missing"
grep -Fq 'SD_BACKUP_REQUIRED=YES' "$CLEAN" || fail "SD backup safety contract missing"
grep -Fq 'STARTUP_UNCHANGED=YES' "$CLEAN" || fail "startup integrity contract missing"
grep -Fq 'CHAIN_TEST_OPERATION_LOCK_PRESENT' "$CLEAN" || fail "operation lock refusal missing"

tmp=$(mktemp -d)
live="$tmp/live"
vol="$tmp/vol"

mkdir -p \
    "$live/mnt/system/etc/boot" \
    "$live/mnt/system/etc/eso/production" \
    "$live/mnt/app/root/hooks" \
    "$live/mnt/app/root/carplay-altscreen/tmp/mirror.previous" \
    "$live/mnt/app/eso/hmi/lsd/jars" \
    "$live/tmp" \
    "$vol/Toolbox" \
    "$vol/MMI-Cockpit-Carplay/state"

printf '%s\n' '#!/bin/sh' 'echo stock-startup' > "$live/mnt/system/etc/boot/startup.sh"
printf '%s\n' 'boot' > "$live/mnt/system/etc/boot/boot.sh"
printf '%s\n' 'keep-me' > "$live/mnt/system/etc/boot/startup.sh.keep"
printf '%s\n' 'bad-name' > "$live/mnt/system/etc/boot/startup.sh.basevideo3.clean.notpid"

printf '%s\n' 'b-block' > "$live/mnt/system/etc/boot/startup.sh.basevideo3.block.101"
printf '%s\n' 'b-clean' > "$live/mnt/system/etc/boot/startup.sh.basevideo3.clean.102"
printf '%s\n' 'b-new' > "$live/mnt/system/etc/boot/startup.sh.basevideo3.new.103"
printf '%s\n' 'b-original' > "$live/mnt/system/etc/boot/startup.sh.basevideo3.original.104"

printf '%s\n' 'm-block' > "$live/mnt/system/etc/boot/startup.sh.mirror.block.201"
printf '%s\n' 'm-clean' > "$live/mnt/system/etc/boot/startup.sh.mirror.clean.202"
printf '%s\n' 'm-new' > "$live/mnt/system/etc/boot/startup.sh.mirror.new.203"
printf '%s\n' 'm-original' > "$live/mnt/system/etc/boot/startup.sh.mirror.original.204"

printf '%s\n' 'LD_PRELOAD=/mnt/app/root/carplay-altscreen/lib/libcarplay_altscreen.so' \
    > "$live/mnt/system/etc/eso/production/smartphone_integrator.json"
printf '%s\n' 'dio' > "$live/mnt/system/etc/eso/production/dio_manager.json"
printf '%s\n' 'pf' > "$live/mnt/system/etc/pf.conf"
printf '%s\n' 'legacy mirror hook' > "$live/mnt/app/root/hooks/libcp_mirror.so"
printf '%s\n' 'old mirror bin' > "$live/mnt/app/root/carplay-altscreen/tmp/mirror.previous/carplay-alt111-mirror-display"
printf '%s\n' 'old owner' > "$live/mnt/app/root/carplay-altscreen/tmp/mirror.previous/.mmi-cockpit-carplay-mirror-owner"

startup_before=$(cksum < "$live/mnt/system/etc/boot/startup.sh")
json_before=$(cksum < "$live/mnt/system/etc/eso/production/smartphone_integrator.json")

out="$tmp/cleanup.out"
ALTSCREEN_RECOVERY_TESTING=1 \
ALTSCREEN_RECOVERY_ROOT="$live" \
ALTSCREEN_RECOVERY_VOLUME="$vol" \
sh "$CLEAN" > "$out" 2>&1 || {
    cat "$out" >&2
    fail "cleanup execution"
}

grep -Fq 'CLEANUP=PASS' "$out" || fail "cleanup PASS missing"
grep -Fq 'STARTUP_UNCHANGED=YES' "$out" || fail "startup unchanged marker missing"
grep -Fq 'POST_SCAN=PASS' "$out" || fail "post scan did not pass"

for f in \
    startup.sh.basevideo3.block.101 \
    startup.sh.basevideo3.clean.102 \
    startup.sh.basevideo3.new.103 \
    startup.sh.basevideo3.original.104 \
    startup.sh.mirror.block.201 \
    startup.sh.mirror.clean.202 \
    startup.sh.mirror.new.203 \
    startup.sh.mirror.original.204; do
    [ ! -e "$live/mnt/system/etc/boot/$f" ] || fail "whitelisted startup temp still exists: $f"
done

[ -f "$live/mnt/system/etc/boot/startup.sh" ] || fail "live startup removed"
[ -f "$live/mnt/system/etc/boot/boot.sh" ] || fail "boot.sh removed"
[ -f "$live/mnt/system/etc/boot/startup.sh.keep" ] || fail "unrelated startup file removed"
[ -f "$live/mnt/system/etc/boot/startup.sh.basevideo3.clean.notpid" ] ||
    fail "non-numeric pseudo candidate removed"

startup_after=$(cksum < "$live/mnt/system/etc/boot/startup.sh")
json_after=$(cksum < "$live/mnt/system/etc/eso/production/smartphone_integrator.json")
[ "$startup_before" = "$startup_after" ] || fail "startup content changed"
[ "$json_before" = "$json_after" ] || fail "smartphone_integrator content changed"

[ ! -e "$live/mnt/app/root/hooks/libcp_mirror.so" ] || fail "unreferenced legacy mirror hook remains"
[ ! -e "$live/mnt/app/root/carplay-altscreen/tmp/mirror.previous" ] || fail "legacy mirror.previous remains"

last="$vol/MMI-Cockpit-Carplay/logs/storage-recovery/LAST_CLEANUP.txt"
[ -s "$last" ] || fail "LAST_CLEANUP pointer missing"
run=$(cat "$last")
[ -f "$run/CLEANUP_COMPLETE" ] || fail "cleanup completion marker missing"
[ -s "$run/delete_manifest.txt" ] || fail "delete manifest missing"
[ -s "$run/delete_results.txt" ] || fail "delete results missing"
[ -s "$run/DF.before.txt" ] || fail "DF.before missing"
[ -s "$run/DF.after.txt" ] || fail "DF.after missing"
[ -s "$run/checksums.before.txt" ] || fail "checksums.before missing"
[ -s "$run/checksums.after.txt" ] || fail "checksums.after missing"
[ -s "$run/POST_SCAN.txt" ] || fail "post-scan log missing"

grep -Fq 'DELETE=PASS path=/mnt/system/etc/boot/startup.sh.basevideo3.clean.102' "$run/delete_results.txt" ||
    fail "basevideo3 deletion not logged"
grep -Fq 'DELETE=PASS path=/mnt/system/etc/boot/startup.sh.mirror.clean.202' "$run/delete_results.txt" ||
    fail "mirror deletion not logged"
grep -Fq 'DELETE=PASS path=/mnt/app/root/hooks/libcp_mirror.so' "$run/delete_results.txt" ||
    fail "mirror hook deletion not logged"
grep -Fq 'DELETE=PASS path=/mnt/app/root/carplay-altscreen/tmp/mirror.previous' "$run/delete_results.txt" ||
    fail "mirror.previous deletion not logged"

backup=$(grep '^BACKUP_DIR=' "$out" | tail -n 1 | cut -d= -f2-)
[ -f "$backup/BACKUP_COMPLETE" ] || fail "backup completion marker missing"
[ -f "$backup/protected/startup.sh" ] || fail "protected live startup backup missing"
[ "$(cksum < "$backup/protected/startup.sh")" = "$startup_before" ] ||
    fail "protected live startup backup checksum mismatch"
[ -f "$backup/files/system_boot/startup.sh.basevideo3.clean.102" ] ||
    fail "system candidate backup missing"
[ -f "$backup/files/app_hooks/libcp_mirror.so" ] || fail "mirror hook backup missing"
[ -f "$backup/files/runtime_tmp/mirror.previous/carplay-alt111-mirror-display" ] ||
    fail "mirror.previous backup missing"

# A live reference must protect libcp_mirror.so while still allowing safe system cleanup.
live2="$tmp/live-ref"
vol2="$tmp/vol-ref"
mkdir -p \
    "$live2/mnt/system/etc/boot" \
    "$live2/mnt/system/etc/eso/production" \
    "$live2/mnt/app/root/hooks" \
    "$live2/tmp" \
    "$vol2/Toolbox" \
    "$vol2/MMI-Cockpit-Carplay/state"
printf '%s\n' '#!/bin/sh' > "$live2/mnt/system/etc/boot/startup.sh"
printf '%s\n' 'tmp' > "$live2/mnt/system/etc/boot/startup.sh.mirror.clean.301"
printf '%s\n' 'LD_PRELOAD=/legacy/path/libcp_mirror.so' \
    > "$live2/mnt/system/etc/eso/production/smartphone_integrator.json"
printf '%s\n' 'dio' > "$live2/mnt/system/etc/eso/production/dio_manager.json"
printf '%s\n' 'pf' > "$live2/mnt/system/etc/pf.conf"
printf '%s\n' 'still referenced' > "$live2/mnt/app/root/hooks/libcp_mirror.so"

ALTSCREEN_RECOVERY_TESTING=1 \
ALTSCREEN_RECOVERY_ROOT="$live2" \
ALTSCREEN_RECOVERY_VOLUME="$vol2" \
sh "$CLEAN" > "$tmp/ref.out" 2>&1 || {
    cat "$tmp/ref.out" >&2
    fail "referenced-hook cleanup execution"
}
[ -f "$live2/mnt/app/root/hooks/libcp_mirror.so" ] || fail "referenced mirror hook was deleted"
[ ! -f "$live2/mnt/system/etc/boot/startup.sh.mirror.clean.301" ] ||
    fail "safe system temp was not cleaned when hook was protected"
run2=$(cat "$vol2/MMI-Cockpit-Carplay/logs/storage-recovery/LAST_CLEANUP.txt")
grep -Fq 'LIVE_CONFIG_REFERENCE' "$run2/skipped_files.txt" ||
    fail "referenced hook skip reason not logged"

# An operation lock must refuse cleanup before deleting anything.
live3="$tmp/live-lock"
vol3="$tmp/vol-lock"
mkdir -p \
    "$live3/mnt/system/etc/boot" \
    "$live3/mnt/system/etc/eso/production" \
    "$live3/tmp" \
    "$vol3/Toolbox" \
    "$vol3/MMI-Cockpit-Carplay/state/.chain_test.lock"
printf '%s\n' '#!/bin/sh' > "$live3/mnt/system/etc/boot/startup.sh"
printf '%s\n' 'must-remain' > "$live3/mnt/system/etc/boot/startup.sh.basevideo3.clean.401"
printf '%s\n' 'json' > "$live3/mnt/system/etc/eso/production/smartphone_integrator.json"
printf '%s\n' 'dio' > "$live3/mnt/system/etc/eso/production/dio_manager.json"
printf '%s\n' 'pf' > "$live3/mnt/system/etc/pf.conf"

if ALTSCREEN_RECOVERY_TESTING=1 \
   ALTSCREEN_RECOVERY_ROOT="$live3" \
   ALTSCREEN_RECOVERY_VOLUME="$vol3" \
   sh "$CLEAN" > "$tmp/lock.out" 2>&1; then
    fail "cleanup unexpectedly succeeded with operation lock"
fi
grep -Fq 'CHAIN_TEST_OPERATION_LOCK_PRESENT' "$tmp/lock.out" ||
    fail "operation lock refusal reason missing"
[ -f "$live3/mnt/system/etc/boot/startup.sh.basevideo3.clean.401" ] ||
    fail "operation-lock refusal deleted a candidate"

echo "STORAGE_RECOVERY_CLEANUP_TEST=PASS backup_before_delete=1 exact_whitelist=1 logs=1 startup_unchanged=1 mirror_guard=1 lock_guard=1 post_scan=1"
