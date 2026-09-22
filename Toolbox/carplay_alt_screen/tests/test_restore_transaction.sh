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

echo "RESTORE_TRANSACTION_TEST=PASS prepared_sync_fail_closed=1 precheck_fail_closed=1 apply_failure_rollback=1 exact_rollback_verify=1 stale_terminal_cleanup=1 corrupt_snapshot_non_destructive=1"
