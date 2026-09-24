#!/bin/sh
set -eu

fail(){ echo "RESCUE_TEST=FAIL $*" >&2; exit 1; }
ROOT_TMP=$(mktemp -d)
trap 'rm -rf "$ROOT_TMP"' 0 1 2 15
DEV="$ROOT_TMP/device"
VOL="$ROOT_TMP/volume"
PROJECT="$VOL/MMI-Cockpit-Carplay"
RESCUE="Toolbox/scripts/altscreen_runtime_rescue.sh"

mkdir -p "$DEV/mnt/app/root/carplay-altscreen/bin/mirror" \
         "$DEV/mnt/system/etc/boot" \
         "$DEV/mnt/system/etc/eso/production" \
         "$DEV/mnt/app/eso/hmi/lsd/jars" \
         "$VOL" "$PROJECT/backup/original/files" "$PROJECT/backup/firewall-original" \
         "$PROJECT/backup/universal-hook-original" "$PROJECT/backup/basevideo3-hmi-original" \
         "$PROJECT/backup/boot-diagnostics" "$PROJECT/state"
ln -s "$PWD/Toolbox" "$VOL/Toolbox"

# Recognizable legacy/unowned runtime: no owner marker on purpose.
printf '%s\n' '#!/bin/sh' 'exit 0' > "$DEV/mnt/app/root/carplay-altscreen/bin/altscreen_chain_test.sh"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$DEV/mnt/app/root/carplay-altscreen/bin/mirror/start_vehicle.sh"
printf '%s\n' 'legacy-payload' > "$DEV/mnt/app/root/carplay-altscreen/bin/legacy.dat"

# Canonical V3.4 universal OEM recovery set.
cat > "$PROJECT/backup/original/manifest.txt" <<'EOF'
/eso/bin/apps/dio_manager
/eso/lib/libairplay.so
/armle/usr/lib/libNmeBaseClasses.so
/mnt/system/etc/eso/production/smartphone_integrator.json
/mnt/system/etc/eso/production/dio_manager.json
EOF
: > "$PROJECT/backup/original/overlay_present.txt"
printf '%s\n' '/mnt/app/root/carplay-altscreen/lib' > "$PROJECT/backup/original/overlay_dir.txt"

make_native(){
    rel=$1
    name=$(printf '%s' "$rel" | tr '/' '_')
    file="$PROJECT/backup/original/files/$name"
    printf 'OEM:%s\n' "$rel" > "$file"
    cksum < "$file" > "$file.cksum"
    live="$DEV$rel"
    mkdir -p "$(dirname "$live")"
    cp "$file" "$live"
}
while IFS= read -r rel; do make_native "$rel"; done < "$PROJECT/backup/original/manifest.txt"
touch "$PROJECT/backup/original/COMPLETE"

printf '%s\n' 'stock-pf' > "$PROJECT/backup/firewall-original/pf.conf"
cksum < "$PROJECT/backup/firewall-original/pf.conf" > "$PROJECT/backup/firewall-original/pf.conf.cksum"
touch "$PROJECT/backup/firewall-original/COMPLETE"
cp "$PROJECT/backup/firewall-original/pf.conf" "$DEV/mnt/system/etc/pf.conf"

printf '%s\n' '/mnt/app/root/hooks/libcarplay_altscreen.so' > "$PROJECT/backup/universal-hook-original/path"
printf '%s\n' '0' > "$PROJECT/backup/universal-hook-original/present"
touch "$PROJECT/backup/universal-hook-original/COMPLETE"

printf '%s\n' '/mnt/app/eso/hmi/lsd/jars/carplay_hook.jar' > "$PROJECT/backup/basevideo3-hmi-original/target"
touch "$PROJECT/backup/basevideo3-hmi-original/absent"
touch "$PROJECT/backup/basevideo3-hmi-original/COMPLETE"

printf '%s\n' '#!/bin/sh' 'echo stock-startup' > "$DEV/mnt/system/etc/boot/startup.sh"
cp "$DEV/mnt/system/etc/boot/startup.sh" "$PROJECT/backup/boot-diagnostics/startup.sh"
cksum < "$PROJECT/backup/boot-diagnostics/startup.sh" > "$PROJECT/backup/boot-diagnostics/startup.cksum"
printf '%s\n' '/mnt/system/etc/boot/startup.sh' > "$PROJECT/backup/boot-diagnostics/path"
touch "$PROJECT/backup/boot-diagnostics/COMPLETE"

run_rescue(){
    action=$1
    ALTSCREEN_RESCUE_TESTING=1 \
    ALTSCREEN_RESCUE_ROOT="$DEV" \
    ALTSCREEN_RESCUE_VOLUME="$VOL" \
      /bin/sh "$RESCUE" "$action"
}

# Uppercase-only legacy backup must not be accepted, because V3.4 RESTORE
# resolves the canonical lowercase path.
mv "$PROJECT/backup/original" "$PROJECT/backup/ORIGINAL"
if run_rescue check > "$ROOT_TMP/uppercase.log" 2>&1; then
    fail "uppercase-only ORIGINAL unexpectedly accepted"
fi
grep -Fq 'reason=CANONICAL_ORIGINAL_MISSING' "$ROOT_TMP/uppercase.log" ||
    fail "uppercase-only rejection reason missing"
mv "$PROJECT/backup/ORIGINAL" "$PROJECT/backup/original"

run_rescue check > "$ROOT_TMP/check1.log" 2>&1 ||
    fail "initial CHECK failed"
grep -Fq 'RESCUE_STATE=LEGACY_UNOWNED_RECOGNIZED safe_to_quarantine=YES' "$ROOT_TMP/check1.log" ||
    fail "initial CHECK did not authorize quarantine"

# A second unrelated/unowned rollback slot should make the real V3.4
# restore-precheck fail. Quarantine must then roll itself back.
mkdir -p "$DEV/mnt/app/root/.carplay-altscreen.previous"
printf '%s\n' foreign > "$DEV/mnt/app/root/.carplay-altscreen.previous/foreign"
if run_rescue quarantine > "$ROOT_TMP/quarantine_rollback.log" 2>&1; then
    fail "quarantine unexpectedly succeeded with unsafe previous runtime"
fi
[ -d "$DEV/mnt/app/root/carplay-altscreen" ] ||
    fail "failed precheck did not restore original runtime path"
[ ! -e "$DEV/mnt/app/root/.carplay-altscreen.rescue-v1" ] ||
    fail "failed precheck left quarantine behind"
grep -Fq 'QUARANTINE_ROLLBACK=PASS' "$ROOT_TMP/quarantine_rollback.log" ||
    fail "quarantine rollback PASS marker missing"
rm -rf "$DEV/mnt/app/root/.carplay-altscreen.previous"

run_rescue quarantine > "$ROOT_TMP/quarantine.log" 2>&1 ||
    fail "valid quarantine failed"
[ ! -e "$DEV/mnt/app/root/carplay-altscreen" ] ||
    fail "active runtime still exists after quarantine"
[ -d "$DEV/mnt/app/root/.carplay-altscreen.rescue-v1" ] ||
    fail "quarantine directory missing"
grep -Fq 'RESTORE_READINESS=PASS' "$ROOT_TMP/quarantine.log" ||
    fail "V3.4 restore preflight did not pass"
grep -Fq 'QUARANTINE=PASS' "$ROOT_TMP/quarantine.log" ||
    fail "quarantine PASS marker missing"

run_rescue check > "$ROOT_TMP/check2.log" 2>&1 ||
    fail "post-quarantine CHECK failed"
grep -Fq 'RESCUE_STATE=QUARANTINED' "$ROOT_TMP/check2.log" ||
    fail "post-quarantine state mismatch"

# Simulate the committed OEM RESTORE result. The live OEM files already match
# the trusted backups; only the persistent transaction marker is added.
touch "$PROJECT/state/RESTORE_PENDING_REBOOT"
rm -f "$PROJECT/state/INSTALLED"
run_rescue check > "$ROOT_TMP/check3.log" 2>&1 ||
    fail "OEM-restored CHECK failed"
grep -Fq 'OEM_VERIFY=PASS' "$ROOT_TMP/check3.log" ||
    fail "OEM verification did not pass"
grep -Fq 'safe_to_delete=YES' "$ROOT_TMP/check3.log" ||
    fail "OEM-restored state not marked safe-to-delete"

run_rescue delete > "$ROOT_TMP/delete.log" 2>&1 ||
    fail "guarded final delete failed"
[ ! -e "$DEV/mnt/app/root/.carplay-altscreen.rescue-v1" ] ||
    fail "quarantine still exists after delete"
[ -f "$PROJECT/rescue-backup/runtime-residue-v1/COMPLETE" ] ||
    fail "final SD rescue backup COMPLETE missing"
[ -f "$PROJECT/rescue-backup/runtime-residue-v1/payload/bin/legacy.dat" ] ||
    fail "final SD rescue backup payload incomplete"
grep -Fq 'RESCUE_BACKUP=PASS' "$ROOT_TMP/delete.log" ||
    grep -Fq 'RESCUE_BACKUP=REUSED' "$ROOT_TMP/delete.log" ||
    fail "final SD backup PASS marker missing"
grep -Fq 'DELETE_QUARANTINE=PASS' "$ROOT_TMP/delete.log" ||
    fail "delete PASS marker missing"

run_rescue restore-backup > "$ROOT_TMP/restore_backup.log" 2>&1 ||
    fail "restore-backup failed"
[ -f "$DEV/mnt/app/root/.carplay-altscreen.rescue-v1/bin/legacy.dat" ] ||
    fail "SD backup did not recreate quarantine"
grep -Fq 'RESTORE_SD_BACKUP=PASS' "$ROOT_TMP/restore_backup.log" ||
    fail "restore-backup PASS marker missing"

run_rescue restore > "$ROOT_TMP/restore_quarantine.log" 2>&1 ||
    fail "restore quarantine to active path failed"
[ -f "$DEV/mnt/app/root/carplay-altscreen/bin/legacy.dat" ] ||
    fail "restored active runtime payload missing"
[ ! -e "$DEV/mnt/app/root/.carplay-altscreen.rescue-v1" ] ||
    fail "quarantine remains after restore"

for f in \
  runtime-residue-rescue-check.log \
  runtime-residue-rescue-check.previous.log \
  runtime-residue-rescue-quarantine.log \
  runtime-residue-rescue-quarantine.previous.log \
  runtime-residue-rescue-delete.log \
  runtime-residue-rescue-restore-backup.log \
  runtime-residue-rescue-restore.log
do
    [ -f "$PROJECT/logs/rescue/$f" ] || fail "expected rescue log missing: $f"
done

echo "RUNTIME_RESCUE_TEST=PASS quarantine=REVERSIBLE v34_restore_preflight=PASS oem_delete_gate=PASS sd_backup=PASS"
