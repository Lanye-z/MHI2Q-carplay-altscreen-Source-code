#!/bin/sh
# Standalone BaseVideo3 STATUS.
set -u

BASE="$0"
RESOLVED=$(command -v -- "$BASE" 2>/dev/null)
[ -n "$RESOLVED" ] || RESOLVED="$BASE"
SCRIPTDIR=$(cd -P -- "$(dirname -- "$RESOLVED")" 2>/dev/null && pwd -P)
[ -n "$SCRIPTDIR" ] || { echo "FAIL: cannot resolve STATUS directory"; exit 126; }

TESTING=${ALTSCREEN_CHAIN_TESTING:-0}
DEVICE_ROOT=""
if [ "$TESTING" = 1 ]; then DEVICE_ROOT=${ALTSCREEN_CHAIN_ROOT:-}; fi

APP_BIN="$DEVICE_ROOT/mnt/app/root/carplay-altscreen/bin"
APP_SELF="$APP_BIN/status_mmi_cockpit_carplay_test.sh"
if [ "$SCRIPTDIR" != "$APP_BIN" ] && [ -f "$APP_SELF" ] && [ -f "$APP_BIN/altscreen_chain_test.sh" ]; then
    echo "APP_RUNTIME_FORWARD action=STATUS from=$SCRIPTDIR to=/mnt/app/root/carplay-altscreen/bin"
    exec /bin/sh "$APP_SELF" "$@"
fi

CONTROLLER="$SCRIPTDIR/altscreen_chain_test.sh"
[ -f "$CONTROLLER" ] || { echo "FAIL: installed chain controller missing"; exit 127; }
/bin/sh "$CONTROLLER" status
STATUS_RC=$?

RUNTIME="$DEVICE_ROOT/mnt/app/root/carplay-altscreen"
ENABLED="$RUNTIME/state/basevideo3.enabled"
JAR="$DEVICE_ROOT/mnt/app/eso/hmi/lsd/jars/carplay_hook.jar"
ACTIVE="$DEVICE_ROOT/tmp/mmi-mirror-active"
READY="$DEVICE_ROOT/tmp/mmi-mirror-basevideo.ready"
STARTED="$DEVICE_ROOT/tmp/mmi-mirror-controller.started"
JAVA_LOG="$DEVICE_ROOT/tmp/mmi-mirror-controller.log"
EXPECTED_SIZE=141858
EXPECTED_CKSUM=2378993239

file_size(){ n=$(wc -c < "$1" 2>/dev/null) || { echo 0; return; }; set -- $n; echo "${1:-0}"; }
file_cksum(){ if command -v cksum >/dev/null 2>&1; then cksum < "$1" 2>/dev/null | awk '{print $1}'; else echo unavailable; fi; }

echo "=== Standalone CarPlay Second Screen / BaseVideo3 ==="
echo "DISPLAY_PATH=BASEVIDEO3_NATIVE source=private111_stock_omx_cscreenrender displayable=3"
echo "NATIVE_BUFFER_OWNER=STOCK_OMX"
echo "NATIVE_WINDOW_OWNER=STOCK_CSCREENRENDER_PLUS_screen_manage_window"
echo "WINDOW_VISIBLE_POLICY=FORCED_PRIVATE_ONLY value=1"
echo "CONTEXT_POLICY=JAVA_ONLY context=80 composite=98,101,102,3 native_dmdt=0"
echo "READBACK_PIPELINE=DISABLED screen_read_window=0 bgra=0 gles=0"
echo "MMI_MIRROR_SIDECAR=NOT_REQUIRED"

if [ -s "$JAR" ]; then
    SIZE=$(file_size "$JAR")
    SUM=$(file_cksum "$JAR")
    if [ "$SIZE" = "$EXPECTED_SIZE" ] && { [ "$SUM" = unavailable ] || [ "$SUM" = "$EXPECTED_CKSUM" ]; }; then
        echo "HMI_CONTROL_PLANE=PASS target=/mnt/app/eso/hmi/lsd/jars/carplay_hook.jar size=$SIZE cksum=$SUM"
    else
        echo "HMI_CONTROL_PLANE=FAIL reason=identity_mismatch size=$SIZE cksum=$SUM"
        [ "$STATUS_RC" -ne 0 ] || STATUS_RC=1
    fi
else
    echo "HMI_CONTROL_PLANE=FAIL reason=jar_missing"
    [ "$STATUS_RC" -ne 0 ] || STATUS_RC=1
fi

[ -f "$ENABLED" ] && echo "BASEVIDEO3_ENABLE=ENABLED" || echo "BASEVIDEO3_ENABLE=DISABLED"
[ -f "$ACTIVE" ] && echo "BASEVIDEO3_ACTIVE_MARKER=YES legacy_abi_name=/tmp/mmi-mirror-active" || echo "BASEVIDEO3_ACTIVE_MARKER=NO"
if [ -f "$READY" ]; then
    echo "BASEVIDEO3_READY=YES"
    cat "$READY" 2>/dev/null || true
else
    echo "BASEVIDEO3_READY=NO"
fi
if [ -f "$STARTED" ]; then
    echo "JAVA_CONTROLLER=STARTED"
    cat "$STARTED" 2>/dev/null || true
else
    echo "JAVA_CONTROLLER=NOT_STARTED"
fi

HOOK_LOG=""
for candidate in "$DEVICE_ROOT/tmp/MMI-Cockpit-Carplay/altscreen_hook.log" "$DEVICE_ROOT/tmp/MMI-Cockpit-Carplay.altscreen_hook.log" "$DEVICE_ROOT/tmp/altscreen_hook.log"; do
    [ -f "$candidate" ] && { HOOK_LOG=$candidate; break; }
done
if [ -n "$HOOK_LOG" ]; then
    echo "NATIVE_EVIDENCE_BEGIN"
    grep '\[MAIN110\].*PHASE=CSCREEN_CONFIG' "$HOOK_LOG" 2>/dev/null | tail -n 1 || true
    grep '\[ALT111\].*PHASE=NATIVE_111_ATTACH' "$HOOK_LOG" 2>/dev/null | tail -n 1 || true
    grep 'PHASE=BASEVIDEO3_WINDOW_PROBE' "$HOOK_LOG" 2>/dev/null | tail -n 4 || true
    grep 'PHASE=BASEVIDEO3_FORCE_VISIBLE' "$HOOK_LOG" 2>/dev/null | tail -n 1 || true
    grep '\[BASEVIDEO3\].*PHASE=BASEVIDEO3_READY' "$HOOK_LOG" 2>/dev/null | tail -n 1 || true
    echo "NATIVE_EVIDENCE_END"
fi

if [ -f "$JAVA_LOG" ]; then
    echo "JAVA80_LOG_BEGIN"
    tail -n 20 "$JAVA_LOG" 2>/dev/null || true
    echo "JAVA80_LOG_END"
fi

exit "$STATUS_RC"
