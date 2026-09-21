#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
START="$ROOT/Toolbox/scripts/start_mmi_cockpit_carplay_rx_test.sh"
STOP="$ROOT/Toolbox/scripts/stop_mmi_cockpit_carplay_test.sh"
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

for f in "$START" "$STOP" "$CHAIN" "$CTRL" "$DIAG" "$ADAPT" "$BOOT" "$INSTALL" "$LAUNCH" "$STOP_LAUNCH"; do
    sh -n "$f" || fail "shell syntax: $f"
done

grep -Fq 'tmp/altscreen_start_$$.clean' "$START" || fail "START scratch is not flat /tmp"
grep -Fq 'ROUTER_TMP="$(p /tmp/altscreen_router_child_install.$$)"' "$CHAIN" || fail "INSTALL router scratch is not flat /tmp"
grep -Fq 'PIDFILE="$TMP_ROOT/altscreen_mirror.pid"' "$LAUNCH" || fail "Mirror pid is not flat /tmp"
grep -Fq 'HOOK_LOG="$TMP_ROOT/altscreen_hook.log"' "$LAUNCH" || fail "Mirror hook log is not flat /tmp"
grep -Fq 'AUTOLOG=/tmp/altscreen_autostart.log' "$START" || fail "autostart log is not flat /tmp"
grep -Fq '#define ALTSCREEN_VOLATILE_ROOT "/tmp"' "$PATHS" || fail "native hook log root is not flat /tmp"

grep -Fq 'MMI-Cockpit-Carplay/staging/restore-apply' "$STOP" || fail "RESTORE scratch is not SD staging"
grep -Fq 'STAGING_ROOT/controller-txn' "$CTRL" || fail "controller transaction is not SD staging"
grep -Fq 'MMI-Cockpit-Carplay/staging/diag-txn' "$DIAG" || fail "diagnostics transaction is not SD staging"
grep -Fq 'FLAT_PREFIX="$ROOT/tmp/altscreen_diag_$$"' "$BOOT" || fail "boot diagnostics scratch is not flat /tmp"

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
grep -Fq '[ "$size" = "$EXPECTED_SIZE" ] && [ "$sum" = "$EXPECTED_CKSUM" ] && return 0' "$INSTALL" ||
    fail "current package JAR identity is not recognized as managed"
grep -Fq 'journal_storage=SD' "$START" || fail "START operation log does not prefer SD"
grep -Fq 'journal_storage=TMP' "$START" || fail "START operation log lacks flat /tmp fallback"
grep -Fq 'DEST_MODE=SD' "$ADAPT" || fail "adaptive log SD preference missing"
grep -Fq 'DEST_MODE=TMP' "$ADAPT" || fail "adaptive log flat /tmp fallback missing"
grep -Fq 'basevideo3.enabled' "$START" || fail "persistent boot demand marker missing"
grep -Fq 'diagnostics.enabled' "$DIAG" || fail "persistent diagnostics marker missing"

echo "STORAGE_POLICY_TEST=PASS tmp=flat_files_only install_router=flat start_txn=flat mirror_runtime=flat hook_log=flat restore_scratch=sd controller_txn=sd diagnostics_txn=sd persistent_logs=sd"
