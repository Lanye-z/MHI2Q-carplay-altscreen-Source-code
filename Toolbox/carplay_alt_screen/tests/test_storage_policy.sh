#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
START="$ROOT/Toolbox/scripts/start_mmi_cockpit_carplay_rx_test.sh"
STOP="$ROOT/Toolbox/scripts/stop_mmi_cockpit_carplay_test.sh"
FINISH="$ROOT/Toolbox/scripts/finish_mmi_cockpit_carplay_test.sh"
INSTALL_TXN="$ROOT/Toolbox/scripts/altscreen_install_transaction.sh"
RESTORE_TXN="$ROOT/Toolbox/scripts/altscreen_restore_transaction.sh"
RESTORE_APPLY="$ROOT/Toolbox/scripts/altscreen_restore_apply.sh"
CHAIN="$ROOT/Toolbox/scripts/altscreen_chain_test.sh"
CTRL="$ROOT/Toolbox/scripts/altscreen_chain_test_universal.sh"
DIAG="$ROOT/Toolbox/scripts/altscreen_persistent_diag.sh"
ADAPT="$ROOT/Toolbox/scripts/altscreen_adaptive_diag.sh"
BOOT="$ROOT/Toolbox/scripts/altscreen_boot_diag.sh"
INSTALL="$ROOT/Toolbox/scripts/install_mmi_cockpit_carplay_rx.sh"
LAUNCH="$ROOT/Toolbox/carplay_alt_screen/mirror_display/release/start_vehicle.sh"
STOP_LAUNCH="$ROOT/Toolbox/carplay_alt_screen/mirror_display/release/stop_vehicle.sh"
PATHS="$ROOT/Toolbox/carplay_alt_screen/src/altscreen_paths.c"
fail(){ echo "STORAGE_POLICY_TEST=FAIL: $*" >&2; exit 1; }

for f in "$START" "$STOP" "$FINISH" "$INSTALL_TXN" "$RESTORE_TXN" "$RESTORE_APPLY" "$CHAIN" "$CTRL" "$DIAG" "$ADAPT" "$BOOT" "$INSTALL" "$LAUNCH" "$STOP_LAUNCH"; do
    sh -n "$f" || fail "shell syntax: $f"
done

# Critical vehicle operations must never require a nested /tmp directory.
grep -Fq 'tmp/altscreen_start_$$.clean' "$START" || fail "START scratch is not flat /tmp"
grep -Fq 'ROUTER_TMP="$(p /tmp/altscreen_router_child_install.$$)"' "$CHAIN" || fail "INSTALL router scratch is not flat /tmp"
grep -Fq 'PIDFILE="$TMP_ROOT/altscreen_mirror.pid"' "$LAUNCH" || fail "Mirror pid is not flat /tmp"
grep -Fq 'HOOK_LOG="$TMP_ROOT/altscreen_hook.log"' "$LAUNCH" || fail "Mirror hook log is not flat /tmp"
grep -Fq 'AUTOLOG=/tmp/altscreen_autostart.log' "$START" || fail "autostart log is not flat /tmp"
grep -Fq '#define ALTSCREEN_VOLATILE_ROOT "/tmp"' "$PATHS" || fail "native hook log root is not flat /tmp"

# Reboot-recoverable transactions and persistent logs belong on SD.
grep -Fq 'TXN_ROOT="$SD/install-transaction"' "$INSTALL_TXN" || fail "INSTALL transaction root is not on SD"
grep -Fq 'TXN="$TXN_ROOT/active"' "$INSTALL_TXN" || fail "INSTALL transaction active state is not reboot-recoverable"
grep -Fq "printf '%s\\n' 2 > \"\$TXN/FORMAT\"" "$INSTALL_TXN" ||
    fail "INSTALL transaction format version marker missing"
grep -Fq 'INSTALL_TRANSACTION=PREPARED persistent_state=PRE_INSTALL durable=YES' "$INSTALL_TXN" ||
    fail "INSTALL PREPARED marker is not durably synced"
grep -Fq 'cannot durably commit install transaction' "$INSTALL_TXN" ||
    fail "INSTALL COMMITTED marker is not durably synced"
grep -Fq 'reason=PREPARED_SYNC_FAILED production_changed=NO' "$INSTALL_TXN" ||
    fail "INSTALL does not fail closed when PREPARED sync fails"
grep -Fq 'SNAPSHOT_INTEGRITY=PASS' "$INSTALL_TXN" ||
    fail "INSTALL snapshot integrity gate missing"
grep -Fq 'INSTALL_ROLLBACK=REFUSED reason=SNAPSHOT_INTEGRITY_FAILED' "$INSTALL_TXN" ||
    fail "INSTALL may destructively roll back from a corrupt snapshot"
grep -Fq 'INSTALL_ROLLBACK=PASS persistent_state=PRE_INSTALL' "$INSTALL_TXN" || fail "INSTALL rollback contract missing"
grep -Fq 'INSTALL_VERIFY=PASS' "$INSTALL_TXN" || fail "INSTALL final verifier missing"
grep -Fq 'restore-precheck' "$INSTALL_TXN" ||
    fail "INSTALL final verifier does not verify the native recovery set"
grep -Fq 'verify_hmi_backup' "$INSTALL_TXN" ||
    fail "INSTALL final verifier does not validate HMI recovery backup"
grep -Fq 'verify_boot_backup' "$INSTALL_TXN" ||
    fail "INSTALL final verifier does not validate boot diagnostics backup"
grep -Fq 'INSTALL=PASS transaction=COMMITTED' "$INSTALL_TXN" || fail "INSTALL commit marker missing"
grep -Fq 'ALTS_INSTALL_TXN_ACTIVE=1' "$INSTALL_TXN" || fail "INSTALL transaction APPLY re-entry marker missing"
grep -Fq 'transactional INSTALL wrapper missing' "$INSTALL" || fail "top-level INSTALL does not require transaction wrapper"
grep -Fq 'install transaction is active; START is blocked' "$CHAIN" || fail "START is not blocked during INSTALL transaction"
grep -Fq 'install_transaction_cleanup_terminal' "$CHAIN" ||
    fail "terminal COMMITTED/ROLLED_BACK INSTALL transaction can still block START"
grep -Fq 'INSTALL_TRANSACTION=TERMINAL_STALE' "$CHAIN" ||
    fail "STATUS cannot distinguish terminal stale INSTALL transaction"
grep -Fq 'ACTIVE_INSTALL_TRANSACTION=DETECTED' "$RESTORE_TXN" || fail "RESTORE does not recover interrupted INSTALL first"
grep -Fq "printf '%s\\n' 2 > \"\$TXN/FORMAT\"" "$RESTORE_TXN" ||
    fail "RESTORE transaction format version marker missing"
grep -Fq 'RESTORE_TRANSACTION=PREPARED durable=YES' "$RESTORE_TXN" ||
    fail "RESTORE PREPARED marker is not durably synced"
grep -Fq 'RESTORE=REFUSED reason=PREPARED_SYNC_FAILED production_changed=NO' "$RESTORE_TXN" ||
    fail "RESTORE does not fail closed when PREPARED sync fails"
grep -Fq 'ROLLBACK=REFUSED reason=SNAPSHOT_INTEGRITY_FAILED' "$RESTORE_TXN" ||
    fail "RESTORE may destructively roll back from a corrupt snapshot"
grep -Fq 'ROLLBACK_VERIFY=PASS' "$RESTORE_TXN" ||
    fail "RESTORE rollback exact-state verification missing"
grep -Fq 'cannot durably commit restore transaction' "$RESTORE_TXN" ||
    fail "RESTORE COMMITTED marker is not durably synced"
grep -Fq 'restore-transaction/active' "$RESTORE_TXN" || fail "RESTORE transaction is not reboot-recoverable on SD"
grep -Fq 'staging/restore-apply' "$RESTORE_APPLY" || fail "RESTORE APPLY scratch is not SD staging"
grep -Fq 'STAGING_ROOT/controller-txn' "$CTRL" || fail "controller scratch is not SD staging"
grep -Fq 'staging/diag-txn' "$DIAG" || fail "diagnostics transaction is not SD staging"
grep -Fq 'FLAT_PREFIX="$ROOT/tmp/altscreen_diag_$$"' "$BOOT" || fail "boot diagnostics scratch is not flat /tmp"
grep -Fq 'CURSOR_PREFIX="$ROOT/tmp/altscreen_diag_cursor"' "$BOOT" ||
    fail "boot diagnostic dedupe cursor is not flat volatile /tmp"
if grep -Fq '.capture-cursors' "$BOOT"; then
    fail "boot diagnostic dedupe cursor still writes persistent metadata to SD"
fi
grep -Fq 'flat_file_signature' "$BOOT" ||
    fail "wheel event snapshot lacks change detection"

# Legacy namespace references are allowed only for read/cleanup compatibility.
for f in "$START" "$STOP" "$CHAIN" "$CTRL" "$DIAG" "$ADAPT" "$BOOT" "$LAUNCH" "$STOP_LAUNCH"; do
    if grep -E 'mkdir( -p)? .*tmp/MMI-Cockpit-Carplay|ensure_dirs .*tmp/MMI-Cockpit-Carplay|TXN[^=]*=.*tmp/MMI-Cockpit-Carplay' "$f" >/dev/null 2>&1; then
        fail "nested /tmp write dependency remains in $f"
    fi
done

grep -Fq 'RUNTIME_ROLLBACK_SLOT_CLEANED=PASS' "$CHAIN" || fail "runtime rollback slot cleanup missing"
grep -Fq 'PUBLISH_SKIP_IDENTICAL' "$CTRL" || fail "universal publish lacks no-op skip"
grep -Fq 'trusted original backup is absent' "$CTRL" || fail "native backup pollution guard missing"
grep -Fq 'trusted original Java HMI backup is absent' "$INSTALL" || fail "HMI backup pollution guard missing"
grep -Fq 'live_managed_install_detected' "$INSTALL" || fail "HMI managed-install detector missing"
grep -Fq 'same_bytes "$JAR_SOURCE" "$JAR_TARGET"' "$INSTALL" ||
    fail "current package JAR identity is not recognized as managed"
grep -Fq 'historical_managed_jar' "$INSTALL" ||
    fail "historical managed-JAR classifier missing"
grep -Fq 'com/luka/carplay/cluster/WheelZoomBridge.class' "$INSTALL" ||
    fail "previous V3 JAR detection is not stable across CI rebuild checksums"
grep -Fq '[ "$current_package_jar" != YES ] && historical_managed_jar "$JAR_TARGET"' "$INSTALL" ||
    fail "current-package and historical-JAR reasons can overlap"

# INSTALL must explain exactly which managed residue triggered fail-closed.
grep -Fq 'RUNTIME_OWNER_PRESENT=' "$INSTALL" || fail "INSTALL does not report runtime-owner residue"
grep -Fq 'SMARTPHONE_INTEGRATOR_HOOK=' "$INSTALL" || fail "INSTALL does not report smartphone_integrator residue"
grep -Fq 'CURRENT_PACKAGE_JAR_PRESENT=' "$INSTALL" || fail "INSTALL does not report current-package JAR residue"
grep -Fq 'KNOWN_MANAGED_JAR_PRESENT=' "$INSTALL" || fail "INSTALL does not report historical managed-JAR residue"
grep -Fq 'LIVE_MANAGED_SUMMARY=MANAGED reasons=' "$INSTALL" || fail "INSTALL managed-residue summary missing"
grep -Fq 'NATIVE_REINSTALL_PRECHECK=FAIL reason=SMARTPHONE_INTEGRATOR_PRELOAD_PRESENT' "$CTRL" ||
    fail "native reinstall guard does not name residual preload"

# Every mutating GEM operation must journal the whole wrapper transaction to SD.
grep -Fq 'OP_BEGIN action=INSTALL' "$INSTALL" || fail "INSTALL SD operation journal missing"
grep -Fq 'journal_base="$journal_dir/install_${journal_stamp}"' "$INSTALL" || fail "INSTALL journal naming missing"
grep -Fq 'OP_BEGIN action=RESTORE_ORIGINAL' "$STOP" || fail "RESTORE ORIGINAL SD operation journal missing"
grep -Fq 'journal_base="$journal_dir/restore_${journal_stamp}"' "$STOP" || fail "RESTORE journal naming missing"
grep -Fq 'RESTORE_JOURNAL_FALLBACK=TMP reason=sd_write_failed' "$STOP" ||
    fail "RESTORE operation journal lacks non-blocking /tmp fallback"
grep -Fq 'OP_BEGIN action=STORE_LOGS_RESTORE' "$FINISH" || fail "STORE LOGS + RESTORE SD operation journal missing"
grep -Fq 'journal_base="$journal_dir/store_restore_${journal_stamp}"' "$FINISH" || fail "STORE+RESTORE journal naming missing"
grep -Fq 'STORE_RESTORE_JOURNAL_FALLBACK=TMP reason=sd_write_failed' "$FINISH" ||
    fail "STORE+RESTORE operation journal lacks non-blocking /tmp fallback"

grep -Fq 'journal_storage=SD' "$START" || fail "START operation log does not prefer SD"
grep -Fq 'journal_storage=TMP' "$START" || fail "START operation log lacks flat /tmp fallback"
grep -Fq 'DEST_MODE=SD' "$ADAPT" || fail "adaptive log SD preference missing"
grep -Fq 'DEST_MODE=TMP' "$ADAPT" || fail "adaptive log flat /tmp fallback missing"
grep -Fq 'basevideo3.enabled' "$START" || fail "persistent boot demand marker missing"
grep -Fq 'diagnostics.enabled' "$DIAG" || fail "persistent diagnostics marker missing"

echo "STORAGE_POLICY_TEST=PASS tmp=flat_files_only install_router=flat start_txn=flat install_txn=sd_reboot_recoverable_exact_rollback prepared_durable=1 snapshot_integrity=1 terminal_nonblocking=1 recovery_set_verify=1 install_ops=sd_fail_closed restore_ops=sd_preferred_tmp_fallback mirror_runtime=flat hook_log=flat restore_txn=sd_reboot_recoverable persistent_logs=sd managed_residue_reasons=explicit"
