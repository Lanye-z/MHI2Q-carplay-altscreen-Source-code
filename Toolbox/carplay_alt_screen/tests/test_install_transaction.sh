#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
WRAPPER="$ROOT/Toolbox/scripts/altscreen_install_transaction.sh"
fail(){ echo "INSTALL_TRANSACTION_TEST=FAIL: $*" >&2; exit 1; }

TMP=$(mktemp -d "${TMPDIR:-/tmp}/altscreen-install-txn.XXXXXX")
trap 'rm -rf "$TMP"' 0 1 2 15
DEV="$TMP/device"
VOL="$TMP/sd"
SD="$VOL/MMI-Cockpit-Carplay"
SCRIPTS="$VOL/Toolbox/scripts"
ART="$VOL/Toolbox/carplay_alt_screen"

mkdir -p \
  "$DEV/mnt/system/etc/boot" \
  "$DEV/mnt/system/etc/eso/production" \
  "$DEV/mnt/app/eso/hmi/lsd/jars" \
  "$DEV/mnt/app/root/lib-target" \
  "$DEV/tmp" \
  "$SCRIPTS" \
  "$ART/hmi" \
  "$ART/universal" \
  "$SD/state" \
  "$SD/backup/preexisting" \
  "$SD/staging/preexisting"

printf '%s\n' '#!/bin/sh' 'echo PRE_INSTALL_STARTUP' > "$DEV/mnt/system/etc/boot/startup.sh"
printf '%s\n' 'PRE_INSTALL_SI' > "$DEV/mnt/system/etc/eso/production/smartphone_integrator.json"
printf '%s\n' 'PRE_INSTALL_DIO' > "$DEV/mnt/system/etc/eso/production/dio_manager.json"
printf '%s\n' 'PRE_INSTALL_PF' > "$DEV/mnt/system/etc/pf.conf"
printf '%s\n' 'PRE_INSTALL_JAR' > "$DEV/mnt/app/eso/hmi/lsd/jars/carplay_hook.jar"
printf '%s\n' 'PRE_LIBTARGET' > "$DEV/mnt/app/root/lib-target/preexisting.so"
printf '%s\n' 'PRE_STATE' > "$SD/state/PRE"
printf '%s\n' 'PRE_BACKUP' > "$SD/backup/preexisting/KEEP"
printf '%s\n' 'PRE_STAGING' > "$SD/staging/preexisting/KEEP"

printf '%s\n' 'NEW_JAR' > "$ART/hmi/carplay_hook-basevideo3.jar"
printf '%s\n' 'NEW_HOOK' > "$ART/universal/libcarplay_altscreen.so"

cat > "$SCRIPTS/altscreen_preload.awk" <<'EOF'
{
  if (query != "" && index($0, query) > 0) found=1
}
END {
  if (query != "") exit(found ? 0 : 1)
  exit 0
}
EOF

cat > "$SCRIPTS/altscreen_chain_test.sh" <<'EOF'
#!/bin/sh
case "${1:-}" in
  restore-precheck) echo "RESTORE_PRECHECK=PASS profile=UNIVERSAL production_changed=NO"; exit 0 ;;
  *) exit 64 ;;
esac
EOF
chmod 755 "$SCRIPTS/altscreen_chain_test.sh"

# Unknown transaction actions must fail before any snapshot or mutation.
set +e
ALTSCREEN_CHAIN_TESTING=1 \
ALTSCREEN_CHAIN_ROOT="$DEV" \
ALTSCREEN_CHAIN_VOLUME="$VOL" \
/bin/sh "$WRAPPER" nonsense > "$TMP/bad-action.out" 2>&1
BAD_ACTION_RC=$?
set -e
[ "$BAD_ACTION_RC" -eq 2 ] || fail "unknown transaction action was not rejected with usage status"
[ "$(cat "$DEV/mnt/system/etc/eso/production/smartphone_integrator.json")" = PRE_INSTALL_SI ] ||
  fail "unknown transaction action changed production state"

# PREPARED must be durably synced before APPLY. Inject a failing sync command and
# prove that the installer body is never entered.
cat > "$SCRIPTS/install_mmi_cockpit_carplay_rx.sh" <<EOF
#!/bin/sh
touch "$TMP/APPLY_RAN"
exit 0
EOF
chmod 755 "$SCRIPTS/install_mmi_cockpit_carplay_rx.sh"
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
/bin/sh "$WRAPPER" install > "$TMP/sync-fail.out" 2>&1
SYNC_RC=$?
set -e
[ "$SYNC_RC" -ne 0 ] || fail "PREPARED sync failure unexpectedly succeeded"
grep -Fq 'reason=PREPARED_SYNC_FAILED production_changed=NO' "$TMP/sync-fail.out" ||
  fail "PREPARED sync failure was not fail-closed"
[ ! -e "$TMP/APPLY_RAN" ] || fail "APPLY ran even though PREPARED was not durable"
[ ! -e "$SD/install-transaction/active" ] || fail "failed PREPARED snapshot was not cleaned"

# First APPLY deliberately dirties every class of state and fails.
cat > "$SCRIPTS/install_mmi_cockpit_carplay_rx.sh" <<EOF
#!/bin/sh
set -e
printf '%s\n' '#!/bin/sh' 'echo MUTATED_STARTUP' '# BEGIN ALTSCREEN DIAGNOSTICS' '# END ALTSCREEN DIAGNOSTICS' > "$DEV/mnt/system/etc/boot/startup.sh"
printf '%s\n' '/mnt/app/root/carplay-altscreen/lib/libcarplay_altscreen.so' > "$DEV/mnt/system/etc/eso/production/smartphone_integrator.json"
printf '%s\n' 'MUTATED_DIO' > "$DEV/mnt/system/etc/eso/production/dio_manager.json"
printf '%s\n' 'MUTATED_PF' > "$DEV/mnt/system/etc/pf.conf"
cp "$ART/hmi/carplay_hook-basevideo3.jar" "$DEV/mnt/app/eso/hmi/lsd/jars/carplay_hook.jar"
rm -rf "$DEV/mnt/app/root/lib-target"
mkdir -p "$DEV/mnt/app/root/carplay-altscreen/bin/mirror" "$DEV/mnt/app/root/carplay-altscreen/lib" "$DEV/mnt/app/root/carplay-altscreen/state"
printf '%s\n' 'owner=MMI-Cockpit-Carplay' > "$DEV/mnt/app/root/carplay-altscreen/.mmi-cockpit-carplay-runtime-owner"
cp "$ART/universal/libcarplay_altscreen.so" "$DEV/mnt/app/root/carplay-altscreen/lib/libcarplay_altscreen.so"
touch "$SD/state/INSTALLED"
printf '%s\n' UNIVERSAL > "$SD/state/firmware_profile.txt"
mkdir -p "$SD/backup/failure-created" "$SD/staging/failure-created"
touch "$SD/backup/failure-created/X" "$SD/staging/failure-created/X"
exit 23
EOF
chmod 755 "$SCRIPTS/install_mmi_cockpit_carplay_rx.sh"

set +e
ALTSCREEN_CHAIN_TESTING=1 \
ALTSCREEN_CHAIN_ROOT="$DEV" \
ALTSCREEN_CHAIN_VOLUME="$VOL" \
/bin/sh "$WRAPPER" install > "$TMP/fail.out" 2>&1
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "injected INSTALL failure unexpectedly succeeded"
grep -Fq 'INSTALL=ABORTED rollback=PASS persistent_state=PRE_INSTALL' "$TMP/fail.out" ||
  fail "failed INSTALL did not roll back to PRE_INSTALL"
grep -Fq 'INSTALL_ROLLBACK_VERIFY=PASS' "$TMP/fail.out" ||
  fail "rollback exact-state verification did not pass"

[ "$(sed -n '2p' "$DEV/mnt/system/etc/boot/startup.sh")" = 'echo PRE_INSTALL_STARTUP' ] || fail "startup not rolled back"
[ "$(cat "$DEV/mnt/system/etc/eso/production/smartphone_integrator.json")" = PRE_INSTALL_SI ] || fail "smartphone_integrator not rolled back"
[ "$(cat "$DEV/mnt/system/etc/eso/production/dio_manager.json")" = PRE_INSTALL_DIO ] || fail "dio_manager not rolled back"
[ "$(cat "$DEV/mnt/system/etc/pf.conf")" = PRE_INSTALL_PF ] || fail "pf.conf not rolled back"
[ "$(cat "$DEV/mnt/app/eso/hmi/lsd/jars/carplay_hook.jar")" = PRE_INSTALL_JAR ] || fail "HMI JAR not rolled back"
[ ! -e "$DEV/mnt/app/root/carplay-altscreen" ] || fail "runtime residue remained after rollback"
[ "$(cat "$DEV/mnt/app/root/lib-target/preexisting.so")" = PRE_LIBTARGET ] || fail "lib-target not rolled back"
[ -f "$SD/state/PRE" ] && [ ! -e "$SD/state/INSTALLED" ] || fail "SD state not rolled back"
[ -f "$SD/backup/preexisting/KEEP" ] && [ ! -e "$SD/backup/failure-created" ] || fail "SD backup tree not rolled back"
[ -f "$SD/staging/preexisting/KEEP" ] && [ ! -e "$SD/staging/failure-created" ] || fail "SD staging tree not rolled back"
[ -f "$SD/install-transaction/active/ROLLED_BACK" ] || fail "rollback terminal marker missing"

ALTSCREEN_CHAIN_TESTING=1 \
ALTSCREEN_CHAIN_ROOT="$DEV" \
ALTSCREEN_CHAIN_VOLUME="$VOL" \
/bin/sh "$WRAPPER" recover > "$TMP/recover.out" 2>&1
grep -Fq 'INSTALL_RECOVERY=PASS' "$TMP/recover.out" || fail "terminal stale transaction cleanup failed"
[ ! -e "$SD/install-transaction/active" ] || fail "terminal stale transaction was not cleaned"

# A corrupt PREPARED snapshot must never trigger destructive rollback.
mkdir -p "$SD/install-transaction/active/files" "$SD/install-transaction/active/dirs"
printf '%s\n' "$DEV/mnt/system/etc/boot/startup.sh" > "$SD/install-transaction/active/startup.path"
touch "$SD/install-transaction/active/PREPARED"
PRE_CORRUPT_SI=$(cksum < "$DEV/mnt/system/etc/eso/production/smartphone_integrator.json")
set +e
ALTSCREEN_CHAIN_TESTING=1 \
ALTSCREEN_CHAIN_ROOT="$DEV" \
ALTSCREEN_CHAIN_VOLUME="$VOL" \
/bin/sh "$WRAPPER" recover > "$TMP/corrupt-recover.out" 2>&1
CORRUPT_RC=$?
set -e
[ "$CORRUPT_RC" -ne 0 ] || fail "corrupt PREPARED snapshot unexpectedly recovered"
grep -Fq 'INSTALL_ROLLBACK=REFUSED reason=SNAPSHOT_INTEGRITY_FAILED' "$TMP/corrupt-recover.out" ||
  fail "corrupt snapshot was not rejected before rollback"
[ "$(cksum < "$DEV/mnt/system/etc/eso/production/smartphone_integrator.json")" = "$PRE_CORRUPT_SI" ] ||
  fail "corrupt snapshot recovery modified production state"
[ -d "$SD/install-transaction/active" ] || fail "corrupt transaction evidence was discarded"
rm -rf "$SD/install-transaction/active"

# A dead child-controller lock must be reaped before snapshot, not permanently
# block future INSTALL attempts.
mkdir -p "$SD/state/.chain_test.lock"
printf '%s\n' 'MMI-Cockpit-Carplay-Universal' > "$SD/state/.chain_test.lock/owner"
printf '%s\n' '99999999' > "$SD/state/.chain_test.lock/pid"
printf '%s\n' 'test' > "$SD/state/.chain_test.lock/action"

# Second APPLY creates the exact committed V3.1 contract.
cat > "$SCRIPTS/install_mmi_cockpit_carplay_rx.sh" <<EOF
#!/bin/sh
set -e
printf '%s\n' '#!/bin/sh' 'echo INSTALLED' '# BEGIN ALTSCREEN DIAGNOSTICS' '# END ALTSCREEN DIAGNOSTICS' > "$DEV/mnt/system/etc/boot/startup.sh"
printf '%s\n' '/mnt/app/root/carplay-altscreen/lib/libcarplay_altscreen.so' > "$DEV/mnt/system/etc/eso/production/smartphone_integrator.json"
cp "$ART/hmi/carplay_hook-basevideo3.jar" "$DEV/mnt/app/eso/hmi/lsd/jars/carplay_hook.jar"
rm -rf "$DEV/mnt/app/root/.carplay-altscreen.new" "$DEV/mnt/app/root/.carplay-altscreen.previous"
mkdir -p "$DEV/mnt/app/root/carplay-altscreen/bin/mirror" "$DEV/mnt/app/root/carplay-altscreen/lib" "$DEV/mnt/app/root/carplay-altscreen/state"
printf '%s\n' 'owner=MMI-Cockpit-Carplay' 'runtime=carplay-altscreen' > "$DEV/mnt/app/root/carplay-altscreen/.mmi-cockpit-carplay-runtime-owner"
cp "$ART/universal/libcarplay_altscreen.so" "$DEV/mnt/app/root/carplay-altscreen/lib/libcarplay_altscreen.so"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$DEV/mnt/app/root/carplay-altscreen/bin/mirror/start_vehicle.sh"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$DEV/mnt/app/root/carplay-altscreen/bin/mirror/carplay-alt111-mirror-display"
chmod 755 "$DEV/mnt/app/root/carplay-altscreen/bin/mirror/start_vehicle.sh" "$DEV/mnt/app/root/carplay-altscreen/bin/mirror/carplay-alt111-mirror-display"
touch "$DEV/mnt/app/root/carplay-altscreen/state/diagnostics.enabled"
touch "$SD/state/INSTALLED"
rm -f "$SD/state/RESTORE_PENDING_REBOOT"
printf '%s\n' UNIVERSAL > "$SD/state/firmware_profile.txt"
HMI="$SD/backup/basevideo3-hmi-original"
mkdir -p "$HMI"
printf '%s\n' '/mnt/app/eso/hmi/lsd/jars/carplay_hook.jar' > "$HMI/target"
printf '%s\n' 'PRE_INSTALL_JAR' > "$HMI/carplay_hook.jar"
cksum < "$HMI/carplay_hook.jar" > "$HMI/cksum"
touch "$HMI/present" "$HMI/COMPLETE"

BOOT="$SD/backup/boot-diagnostics"
mkdir -p "$BOOT"
printf '%s\n' '#!/bin/sh' 'echo PRE_INSTALL_STARTUP' > "$BOOT/startup.sh"
cksum < "$BOOT/startup.sh" > "$BOOT/startup.cksum"
printf '%s\n' '/mnt/system/etc/boot/startup.sh' > "$BOOT/path"
touch "$BOOT/COMPLETE"

# The real controller verifies original/firewall/universal recovery sets. The
# fixture controller returns RESTORE_PRECHECK=PASS for those three sets.
exit 0
EOF
chmod 755 "$SCRIPTS/install_mmi_cockpit_carplay_rx.sh"

ALTSCREEN_CHAIN_TESTING=1 \
ALTSCREEN_CHAIN_ROOT="$DEV" \
ALTSCREEN_CHAIN_VOLUME="$VOL" \
/bin/sh "$WRAPPER" install > "$TMP/success.out" 2>&1

grep -Fq 'CHAIN_LOCK_STALE_RECOVERED reason=dead_pid old_pid=99999999' "$TMP/success.out" ||
  fail "dead child-controller lock was not reaped before INSTALL"
grep -Fq 'INSTALL_VERIFY=PASS' "$TMP/success.out" || fail "committed INSTALL final verifier did not pass"
grep -Fq 'INSTALL=PASS transaction=COMMITTED persistent_state=INSTALLED' "$TMP/success.out" ||
  fail "committed INSTALL marker missing"
[ ! -e "$SD/install-transaction/active" ] || fail "committed transaction directory was not cleaned"
[ -f "$DEV/mnt/app/root/carplay-altscreen/.mmi-cockpit-carplay-runtime-owner" ] || fail "runtime owner missing after commit"
[ -f "$SD/state/INSTALLED" ] || fail "installed marker missing after commit"

echo "INSTALL_TRANSACTION_TEST=PASS invalid_action=1 prepared_sync_fail_closed=1 apply_failure_rollback=1 exact_preinstall_verify=1 corrupt_snapshot_non_destructive=1 stale_recovery=1 stale_chain_lock_reap=1 recovery_set_verify=1 final_verify_commit=1"
