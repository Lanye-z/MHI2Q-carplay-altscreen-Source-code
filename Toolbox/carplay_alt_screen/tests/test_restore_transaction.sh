#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
WRAPPER="$ROOT/Toolbox/scripts/altscreen_restore_transaction.sh"
fail(){ echo "RESTORE_TRANSACTION_TEST=FAIL: $*" >&2; exit 1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/altscreen-restore-txn.XXXXXX")
trap 'rm -rf "$TMP"' 0 1 2 15
DEV="$TMP/device"
VOL="$TMP/sd"
SD="$VOL/MMI-Cockpit-Carplay"
SCRIPTS="$VOL/Toolbox/scripts"

mkdir -p \
  "$DEV/mnt/system/etc/boot" \
  "$DEV/mnt/system/etc/eso/production" \
  "$DEV/mnt/app/eso/hmi/lsd/jars" \
  "$DEV/mnt/app/root/carplay-altscreen/bin" \
  "$DEV/tmp" \
  "$SCRIPTS" \
  "$SD/state" \
  "$SD/backup/basevideo3-hmi-original"

printf '%s\n' '#!/bin/sh' 'echo stock-plus-v3-startup' > "$DEV/mnt/system/etc/boot/startup.sh"
printf '%s\n' 'PRE_RESTORE_SI' > "$DEV/mnt/system/etc/eso/production/smartphone_integrator.json"
printf '%s\n' 'PRE_RESTORE_DIO' > "$DEV/mnt/system/etc/eso/production/dio_manager.json"
printf '%s\n' 'PRE_RESTORE_PF' > "$DEV/mnt/system/etc/pf.conf"
printf '%s\n' 'PRE_RESTORE_JAR' > "$DEV/mnt/app/eso/hmi/lsd/jars/carplay_hook.jar"
printf '%s\n' 'PRE_RESTORE_RUNTIME' > "$DEV/mnt/app/root/carplay-altscreen/bin/marker"
printf '%s\n' 'PRE_RESTORE_STATE' > "$SD/state/ACTIVE"

HMI="$SD/backup/basevideo3-hmi-original"
printf '%s\n' '/mnt/app/eso/hmi/lsd/jars/carplay_hook.jar' > "$HMI/target"
printf '%s\n' 'ORIGINAL_JAR' > "$HMI/carplay_hook.jar"
cksum < "$HMI/carplay_hook.jar" > "$HMI/cksum"
touch "$HMI/present" "$HMI/COMPLETE"

cat > "$SCRIPTS/altscreen_chain_test.sh" <<'EOF'
#!/bin/sh
case "${1:-}" in
  restore-precheck) echo "RESTORE_PRECHECK=PASS"; exit 0 ;;
  *) exit 64 ;;
esac
EOF
chmod 755 "$SCRIPTS/altscreen_chain_test.sh"
cp "$ROOT/Toolbox/scripts/altscreen_sd_writable.sh" "$SCRIPTS/altscreen_sd_writable.sh"
chmod 755 "$SCRIPTS/altscreen_sd_writable.sh"

cat > "$SCRIPTS/altscreen_restore_apply.sh" <<EOF
#!/bin/sh
set -e
touch "$TMP/APPLY_RAN"
printf '%s\n' 'PARTIAL_SI' > "$DEV/mnt/system/etc/eso/production/smartphone_integrator.json"
printf '%s\n' 'PARTIAL_DIO' > "$DEV/mnt/system/etc/eso/production/dio_manager.json"
printf '%s\n' 'PARTIAL_PF' > "$DEV/mnt/system/etc/pf.conf"
printf '%s\n' 'PARTIAL_JAR' > "$DEV/mnt/app/eso/hmi/lsd/jars/carplay_hook.jar"
rm -rf "$DEV/mnt/app/root/carplay-altscreen"
rm -rf "$SD/state"
exit 23
EOF
chmod 755 "$SCRIPTS/altscreen_restore_apply.sh"

# PREPARED must be durable before APPLY. Force sync failure and prove that the
# restore APPLY helper never starts and production remains unchanged.
mkdir -p "$TMP/fakebin"
cat > "$TMP/fakebin/sync" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod 755 "$TMP/fakebin/sync"
set +e
PATH="$TMP/fakebin:$PATH" \
ALTSCREEN_CHAIN_TESTING=1 \
ALTSCREEN_CHAIN_ROOT="$DEV" \
ALTSCREEN_CHAIN_VOLUME="$VOL" \
/bin/sh "$WRAPPER" > "$TMP/sync-fail.txt" 2>&1
SYNC_RC=$?
set -e
[ "$SYNC_RC" -ne 0 ] || fail "PREPARED sync failure unexpectedly succeeded"
grep -Fq 'RESTORE=REFUSED reason=PREPARED_SYNC_FAILED production_changed=NO' "$TMP/sync-fail.txt" ||
  fail "PREPARED sync failure was not fail-closed"
[ ! -e "$TMP/APPLY_RAN" ] || fail "restore APPLY ran before PREPARED was durable"
[ "$(cat "$DEV/mnt/system/etc/eso/production/smartphone_integrator.json")" = PRE_RESTORE_SI ] ||
  fail "PREPARED sync failure changed production state"
[ ! -e "$SD/restore-transaction/active" ] ||
  fail "failed PREPARED transaction was not cleaned before APPLY"

set +e
ALTSCREEN_CHAIN_TESTING=1 \
ALTSCREEN_CHAIN_ROOT="$DEV" \
ALTSCREEN_CHAIN_VOLUME="$VOL" \
/bin/sh "$WRAPPER" > "$TMP/out.txt" 2>&1
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "injected APPLY failure unexpectedly returned success"
grep -Fq 'RESTORE=ABORTED rollback=PASS' "$TMP/out.txt" ||
  fail "handled APPLY failure did not report a successful rollback"
grep -Fq 'ROLLBACK_VERIFY=PASS' "$TMP/out.txt" ||
  fail "RESTORE rollback exact-state verification did not pass"

[ "$(cat "$DEV/mnt/system/etc/eso/production/smartphone_integrator.json")" = PRE_RESTORE_SI ] ||
  fail "smartphone_integrator.json was not rolled back"
[ "$(cat "$DEV/mnt/system/etc/eso/production/dio_manager.json")" = PRE_RESTORE_DIO ] ||
  fail "dio_manager.json was not rolled back"
[ "$(cat "$DEV/mnt/system/etc/pf.conf")" = PRE_RESTORE_PF ] ||
  fail "pf.conf was not rolled back"
[ "$(cat "$DEV/mnt/app/eso/hmi/lsd/jars/carplay_hook.jar")" = PRE_RESTORE_JAR ] ||
  fail "carplay_hook.jar was not rolled back"
[ "$(cat "$DEV/mnt/app/root/carplay-altscreen/bin/marker")" = PRE_RESTORE_RUNTIME ] ||
  fail "managed runtime was not rolled back"
[ "$(cat "$SD/state/ACTIVE")" = PRE_RESTORE_STATE ] ||
  fail "SD state was not rolled back"
[ -f "$SD/restore-transaction/active/ROLLED_BACK" ] ||
  fail "rollback terminal marker missing"

cat > "$SCRIPTS/altscreen_chain_test.sh" <<'EOF'
#!/bin/sh
exit 42
EOF
set +e
ALTSCREEN_CHAIN_TESTING=1 \
ALTSCREEN_CHAIN_ROOT="$DEV" \
ALTSCREEN_CHAIN_VOLUME="$VOL" \
/bin/sh "$WRAPPER" > "$TMP/out2.txt" 2>&1
RC2=$?
set -e
[ "$RC2" -ne 0 ] || fail "forced precheck failure unexpectedly returned success"
[ ! -e "$SD/restore-transaction/active" ] ||
  fail "terminal stale transaction was not cleaned before precheck"
[ "$(cat "$DEV/mnt/system/etc/eso/production/smartphone_integrator.json")" = PRE_RESTORE_SI ] ||
  fail "precheck failure changed production state"

# A corrupt FORMAT=2 PREPARED snapshot must not be trusted for rollback. Keep
# the evidence and leave production untouched instead of deleting live state.
mkdir -p "$SD/restore-transaction/active/files" "$SD/restore-transaction/active/dirs" "$SD/restore-transaction/active/meta"
printf '%s\n' 2 > "$SD/restore-transaction/active/FORMAT"
printf '%s\n' "$DEV/mnt/system/etc/boot/startup.sh" > "$SD/restore-transaction/active/startup.path"
touch "$SD/restore-transaction/active/PREPARED"
PRE_CORRUPT_SI=$(cksum < "$DEV/mnt/system/etc/eso/production/smartphone_integrator.json")
set +e
ALTSCREEN_CHAIN_TESTING=1 \
ALTSCREEN_CHAIN_ROOT="$DEV" \
ALTSCREEN_CHAIN_VOLUME="$VOL" \
/bin/sh "$WRAPPER" > "$TMP/corrupt.txt" 2>&1
CORRUPT_RC=$?
set -e
[ "$CORRUPT_RC" -ne 0 ] || fail "corrupt RESTORE snapshot unexpectedly recovered"
grep -Fq 'ROLLBACK=REFUSED reason=SNAPSHOT_INTEGRITY_FAILED' "$TMP/corrupt.txt" ||
  fail "corrupt RESTORE snapshot was not rejected before rollback"
[ "$(cksum < "$DEV/mnt/system/etc/eso/production/smartphone_integrator.json")" = "$PRE_CORRUPT_SI" ] ||
  fail "corrupt RESTORE snapshot recovery modified production state"
[ -d "$SD/restore-transaction/active" ] ||
  fail "corrupt RESTORE transaction evidence was discarded"

# Real recovery regression: reproduce the vehicle state where the live
# smartphone_integrator still has our LD_PRELOAD but the runtime owner marker
# is gone. First cover an empty unowned runtime skeleton (the old restore bug),
# then cover a completely missing runtime.
MIX_DEV="$TMP/mixed-device"
MIX_VOL="$TMP/mixed-sd"
MIX_SD="$MIX_VOL/MMI-Cockpit-Carplay"
MIX_SCRIPTS="$MIX_VOL/Toolbox/scripts"
MIX_NATIVE="$MIX_SD/backup/original"
mkdir -p \
  "$MIX_DEV/mnt/system/etc/boot" \
  "$MIX_DEV/mnt/system/etc/eso/production" \
  "$MIX_DEV/mnt/app/eso/hmi/lsd/jars" \
  "$MIX_DEV/mnt/app/root/carplay-altscreen/lib" \
  "$MIX_DEV/tmp" \
  "$MIX_SCRIPTS" \
  "$MIX_VOL/Toolbox/carplay_alt_screen/universal" \
  "$MIX_SD/state" \
  "$MIX_NATIVE/files" \
  "$MIX_SD/backup/basevideo3-hmi-original" \
  "$MIX_SD/backup/universal-hook-original" \
  "$MIX_SD/backup/firewall-original"

for name in altscreen_chain_test.sh altscreen_chain_test_universal.sh altscreen_restore_apply.sh altscreen_persistent_diag.sh altscreen_sd_writable.sh; do
  cp "$ROOT/Toolbox/scripts/$name" "$MIX_SCRIPTS/$name"
  chmod 755 "$MIX_SCRIPTS/$name"
done

printf '%s\n' '#!/bin/sh' 'echo stock-startup' > "$MIX_DEV/mnt/system/etc/boot/startup.sh"
printf '%s\n' 'LIVE_INSTALLED_SI LD_PRELOAD=/mnt/app/root/carplay-altscreen/lib/libcarplay_altscreen.so' > "$MIX_DEV/mnt/system/etc/eso/production/smartphone_integrator.json"
printf '%s\n' 'LIVE_INSTALLED_DIO' > "$MIX_DEV/mnt/system/etc/eso/production/dio_manager.json"
printf '%s\n' 'LIVE_INSTALLED_PF' > "$MIX_DEV/mnt/system/etc/pf.conf"
printf '%s\n' 'LIVE_INSTALLED_JAR' > "$MIX_DEV/mnt/app/eso/hmi/lsd/jars/carplay_hook.jar"

: > "$MIX_NATIVE/manifest.txt"
: > "$MIX_NATIVE/overlay_present.txt"
printf '%s\n' '/mnt/app/root/carplay-altscreen/lib' > "$MIX_NATIVE/overlay_dir.txt"

mix_native_member(){
  rel=$1
  value=$2
  member="$MIX_NATIVE/files/$(echo "$rel" | tr '/' '_')"
  printf '%s\n' "$value" > "$member"
  cksum < "$member" > "$member.cksum"
  printf '%s\n' "$rel" >> "$MIX_NATIVE/manifest.txt"
}
mix_native_member /eso/bin/apps/dio_manager ORIGINAL_DIO_BINARY
mix_native_member /eso/lib/libairplay.so ORIGINAL_LIBAIRPLAY
mix_native_member /armle/usr/lib/libNmeBaseClasses.so ORIGINAL_NME
mix_native_member /mnt/system/etc/eso/production/smartphone_integrator.json ORIGINAL_SI
mix_native_member /mnt/system/etc/eso/production/dio_manager.json ORIGINAL_DIO_JSON
touch "$MIX_NATIVE/COMPLETE"

MIX_HMI="$MIX_SD/backup/basevideo3-hmi-original"
printf '%s\n' '/mnt/app/eso/hmi/lsd/jars/carplay_hook.jar' > "$MIX_HMI/target"
printf '%s\n' 'ORIGINAL_JAR' > "$MIX_HMI/carplay_hook.jar"
cksum < "$MIX_HMI/carplay_hook.jar" > "$MIX_HMI/cksum"
touch "$MIX_HMI/present" "$MIX_HMI/COMPLETE"

MIX_HOOK="$MIX_SD/backup/universal-hook-original"
printf '%s\n' '/mnt/app/root/carplay-altscreen/lib/libcarplay_altscreen.so' > "$MIX_HOOK/path"
printf '%s\n' 0 > "$MIX_HOOK/present"
touch "$MIX_HOOK/COMPLETE"

MIX_FW="$MIX_SD/backup/firewall-original"
printf '%s\n' 'ORIGINAL_PF' > "$MIX_FW/pf.conf"
cksum < "$MIX_FW/pf.conf" > "$MIX_FW/pf.conf.cksum"
printf '%s\n' '/mnt/system/etc/pf.conf' > "$MIX_FW/path"
touch "$MIX_FW/COMPLETE"

set +e
ALTSCREEN_CHAIN_TESTING=1 \
ALTSCREEN_CHAIN_ROOT="$MIX_DEV" \
ALTSCREEN_CHAIN_VOLUME="$MIX_VOL" \
/bin/sh "$WRAPPER" > "$TMP/mixed-unowned.txt" 2>&1
MIX_RC=$?
set -e
[ "$MIX_RC" -eq 0 ] || { cat "$TMP/mixed-unowned.txt" >&2; [ ! -f "$MIX_SD/logs/restore-transaction.log" ] || cat "$MIX_SD/logs/restore-transaction.log" >&2; fail "mixed unowned-runtime recovery failed"; }
grep -Fq 'RESTORE_RECOVERY_MODE=MIXED_PRELOAD_UNOWNED_RUNTIME_RESIDUE' "$TMP/mixed-unowned.txt" ||
  fail "mixed unowned-runtime state was not detected"
grep -Fq 'OVERLAY_BASELINE=ABSENT no_runtime_dir_synthesis=YES' "$MIX_SD/logs/restore-transaction.log" ||
  fail "restore did not record the no-synthesis overlay path"
grep -Fq 'RUNTIME_EMPTY_RESIDUE_REMOVED=PASS' "$MIX_SD/logs/restore-transaction.log" ||
  fail "empty unowned runtime residue was not safely removed"
grep -Fq 'RESTORE_MIXED_STATE_RECOVERY=PASS' "$TMP/mixed-unowned.txt" ||
  fail "mixed-state recovery success marker missing"
[ "$(cat "$MIX_DEV/mnt/system/etc/eso/production/smartphone_integrator.json")" = ORIGINAL_SI ] ||
  fail "mixed-state recovery did not restore stock smartphone_integrator.json"
[ ! -e "$MIX_DEV/mnt/app/root/carplay-altscreen" ] ||
  fail "mixed-state recovery left runtime residue"

# Same trusted backups must also recover the even more reduced state seen after
# rollback: preload config remains but the runtime directory is already absent.
printf '%s\n' 'LIVE_INSTALLED_SI LD_PRELOAD=/mnt/app/root/carplay-altscreen/lib/libcarplay_altscreen.so' > "$MIX_DEV/mnt/system/etc/eso/production/smartphone_integrator.json"
printf '%s\n' 'LIVE_INSTALLED_JAR_2' > "$MIX_DEV/mnt/app/eso/hmi/lsd/jars/carplay_hook.jar"
rm -rf "$MIX_DEV/mnt/app/root/carplay-altscreen"
rm -f "$MIX_SD/state/RESTORE_PENDING_REBOOT" 2>/dev/null || true

set +e
ALTSCREEN_CHAIN_TESTING=1 \
ALTSCREEN_CHAIN_ROOT="$MIX_DEV" \
ALTSCREEN_CHAIN_VOLUME="$MIX_VOL" \
/bin/sh "$WRAPPER" > "$TMP/mixed-missing.txt" 2>&1
MIX_RC2=$?
set -e
[ "$MIX_RC2" -eq 0 ] || { cat "$TMP/mixed-missing.txt" >&2; [ ! -f "$MIX_SD/logs/restore-transaction.log" ] || cat "$MIX_SD/logs/restore-transaction.log" >&2; fail "mixed missing-runtime recovery failed"; }
grep -Fq 'RESTORE_RECOVERY_MODE=MIXED_PRELOAD_RUNTIME_MISSING' "$TMP/mixed-missing.txt" ||
  fail "mixed missing-runtime state was not detected"
grep -Fq 'RESTORE_MIXED_STATE_RECOVERY=PASS' "$TMP/mixed-missing.txt" ||
  fail "missing-runtime recovery success marker missing"
[ "$(cat "$MIX_DEV/mnt/system/etc/eso/production/smartphone_integrator.json")" = ORIGINAL_SI ] ||
  fail "missing-runtime recovery did not restore stock smartphone_integrator.json"
[ "$(cat "$MIX_DEV/mnt/app/eso/hmi/lsd/jars/carplay_hook.jar")" = ORIGINAL_JAR ] ||
  fail "missing-runtime recovery did not restore stock HMI JAR"
[ ! -e "$MIX_DEV/mnt/app/root/carplay-altscreen" ] ||
  fail "missing-runtime recovery recreated runtime"

echo "RESTORE_TRANSACTION_TEST=PASS prepared_sync_fail_closed=1 precheck_fail_closed=1 apply_failure_rollback=1 exact_rollback_verify=1 stale_terminal_cleanup=1 corrupt_snapshot_non_destructive=1 mixed_unowned_runtime_recovery=1 mixed_missing_runtime_recovery=1"
