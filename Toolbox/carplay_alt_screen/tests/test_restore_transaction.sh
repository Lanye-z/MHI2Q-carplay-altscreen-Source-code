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
printf '%s\n' 'PARTIAL_SI' > "$DEV/mnt/system/etc/eso/production/smartphone_integrator.json"
printf '%s\n' 'PARTIAL_DIO' > "$DEV/mnt/system/etc/eso/production/dio_manager.json"
printf '%s\n' 'PARTIAL_PF' > "$DEV/mnt/system/etc/pf.conf"
printf '%s\n' 'PARTIAL_JAR' > "$DEV/mnt/app/eso/hmi/lsd/jars/carplay_hook.jar"
rm -rf "$DEV/mnt/app/root/carplay-altscreen"
rm -rf "$SD/state"
exit 23
EOF
chmod 755 "$SCRIPTS/altscreen_restore_apply.sh"

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

echo "RESTORE_TRANSACTION_TEST=PASS precheck_fail_closed=1 apply_failure_rollback=1 stale_terminal_cleanup=1"
