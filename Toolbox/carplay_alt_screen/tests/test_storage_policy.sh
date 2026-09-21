#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
START="$ROOT/Toolbox/scripts/start_mmi_cockpit_carplay_rx_test.sh"
STOP="$ROOT/Toolbox/scripts/stop_mmi_cockpit_carplay_test.sh"
CHAIN="$ROOT/Toolbox/scripts/altscreen_chain_test.sh"
CTRL="$ROOT/Toolbox/scripts/altscreen_chain_test_universal.sh"
DIAG="$ROOT/Toolbox/scripts/altscreen_persistent_diag.sh"
ADAPT="$ROOT/Toolbox/scripts/altscreen_adaptive_diag.sh"
INSTALL="$ROOT/Toolbox/scripts/install_mmi_cockpit_carplay_rx.sh"
fail(){ echo "STORAGE_POLICY_TEST=FAIL: $*" >&2; exit 1; }

for f in "$START" "$STOP" "$CHAIN" "$CTRL" "$DIAG" "$ADAPT" "$INSTALL"; do
    sh -n "$f" || fail "shell syntax: $f"
done

grep -Fq '/tmp/MMI-Cockpit-Carplay/txn/start.$$' "$START" || fail "START transaction is not volatile"
grep -Fq '/tmp/MMI-Cockpit-Carplay/txn/restore.$$' "$STOP" || fail "RESTORE transaction is not volatile"
grep -Fq '/tmp/MMI-Cockpit-Carplay/txn' "$DIAG" || fail "diagnostics transaction is not volatile"
if grep -Fq 'CLEAN="$STARTUP.basevideo3' "$START" || grep -Fq 'CLEAN="$STARTUP.basevideo3' "$STOP"; then
    fail "BaseVideo transaction scratch still lives beside /mnt/system startup.sh"
fi
grep -Fq 'RUNTIME_ROLLBACK_SLOT_CLEANED=PASS' "$CHAIN" || fail "runtime rollback slot is not cleaned after successful INSTALL"
if grep -Fq 'mirror.previous' "$CHAIN"; then
    fail "new runtime still embeds a duplicate previous Mirror payload"
fi
grep -Fq 'PUBLISH_SKIP_IDENTICAL' "$CTRL" || fail "universal publish lacks no-op skip"
grep -Fq 'SYSTEM_WRITE_FAILED stage=copy' "$CTRL" || fail "universal publish lacks low-space diagnostic"
grep -Fq 'rm -f "$tmp"' "$CTRL" || fail "universal publish does not clean partial staging"
grep -Fq 'trusted original backup is absent' "$CTRL" || fail "native backup pollution guard missing"
grep -Fq 'trusted original Java HMI backup is absent' "$INSTALL" || fail "HMI backup pollution guard missing"
grep -Fq 'journal_storage=SD' "$START" || fail "START operation log does not prefer SD"
grep -Fq 'journal_storage=TMP' "$START" || fail "START operation log lacks /tmp fallback"
grep -Fq 'START_JOURNAL_FALLBACK=TMP reason=sd_write_failed' "$START" ||
    fail "START does not fall back to /tmp when an inserted SD is unwritable"
grep -Fq 'DEST_MODE=SD' "$ADAPT" || fail "adaptive log SD preference missing"
grep -Fq 'DEST_MODE=TMP' "$ADAPT" || fail "adaptive log /tmp fallback missing"
grep -Fq 'MMI-Cockpit-Carplay/backup' "$INSTALL" || fail "HMI original backup is not SD-scoped"
grep -Fq 'basevideo3.enabled' "$START" || fail "persistent boot demand marker missing"
grep -Fq 'diagnostics.enabled' "$DIAG" || fail "persistent diagnostics marker missing"

echo "STORAGE_POLICY_TEST=PASS logs=sd_preferred_tmp_fallback backups=sd txn=tmp persistent_state=mnt_app system=final_only"
