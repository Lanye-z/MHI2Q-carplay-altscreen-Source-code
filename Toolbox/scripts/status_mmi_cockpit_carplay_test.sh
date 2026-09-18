#!/bin/sh
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
    if [ "$#" -gt 0 ]; then exec /bin/sh "$APP_SELF" "$@"; else exec /bin/sh "$APP_SELF"; fi
fi

CONTROLLER="$SCRIPTDIR/altscreen_chain_test.sh"
[ -f "$CONTROLLER" ] || { echo "FAIL: installed chain controller missing"; exit 127; }
/bin/sh "$CONTROLLER" status
STATUS_RC=$?

RUNTIME="$DEVICE_ROOT/mnt/app/root/carplay-altscreen"
JAR="$DEVICE_ROOT/mnt/app/eso/hmi/lsd/jars/carplay_hook.jar"
ENABLED="$RUNTIME/state/basevideo3.enabled"
ACTIVE="$DEVICE_ROOT/tmp/mmi-mirror-active"
DEST_READY="$DEVICE_ROOT/tmp/mmi-mirror-basevideo.ready"
STARTED="$DEVICE_ROOT/tmp/mmi-mirror-controller.started"
JAVA_LOG="$DEVICE_ROOT/tmp/mmi-mirror-controller.log"
MIRROR="$RUNTIME/bin/mirror"
MIRROR_PID="$DEVICE_ROOT/tmp/MMI-Cockpit-Carplay/mirror/pid"
MIRROR_LOG="$DEVICE_ROOT/tmp/MMI-Cockpit-Carplay/mirror/mirror.log"
EXPECTED_SIZE=141858
EXPECTED_CKSUM=2378993239

file_size(){ n=$(wc -c < "$1" 2>/dev/null) || { echo 0; return; }; set -- $n; echo "${1:-0}"; }
file_cksum(){ if command -v cksum >/dev/null 2>&1; then cksum < "$1" 2>/dev/null | awk '{print $1}'; else echo unavailable; fi; }

echo "=== Context80 Readback V1 ==="
echo "SOURCE_PATH=private111_stock_omx_cscreenrender window=58 role=producer_only"
echo "READBACK_PIPELINE=ENABLED capture=screen_read_window cpu_format=BGRA8888"
echo "DESTINATION=displayable3_gles role=sole_consumer"
echo "CONTEXT_POLICY=JAVA_ONLY context=80 composite=98,101,102,3 native_dmdt=0 sidecar_dmdt=0"
echo "AVCC_OBSERVER=NON_AUTHORITATIVE decoder_truth=stock_render_posts_plus_readback"

if [ -s "$JAR" ]; then
    SIZE=$(file_size "$JAR"); SUM=$(file_cksum "$JAR")
    if [ "$SIZE" = "$EXPECTED_SIZE" ] && { [ "$SUM" = unavailable ] || [ "$SUM" = "$EXPECTED_CKSUM" ]; }; then
        echo "HMI_CONTROL_PLANE=PASS size=$SIZE cksum=$SUM"
    else
        echo "HMI_CONTROL_PLANE=FAIL reason=identity_mismatch size=$SIZE cksum=$SUM"
        [ "$STATUS_RC" -ne 0 ] || STATUS_RC=1
    fi
else
    echo "HMI_CONTROL_PLANE=FAIL reason=jar_missing"
    [ "$STATUS_RC" -ne 0 ] || STATUS_RC=1
fi

[ -f "$ENABLED" ] && echo "READBACK_ENABLE=ENABLED" || echo "READBACK_ENABLE=DISABLED"
[ -f "$ACTIVE" ] && echo "JAVA80_DEMAND=YES" || echo "JAVA80_DEMAND=NO"

MIRROR_RUNNING=0
PID=""
if [ -f "$MIRROR_PID" ]; then
    PID=$(cat "$MIRROR_PID" 2>/dev/null || true)
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then MIRROR_RUNNING=1; fi
fi
[ "$MIRROR_RUNNING" = 1 ] && echo "READBACK_SIDECAR=RUNNING pid=$PID" || echo "READBACK_SIDECAR=NOT_RUNNING"
[ -x "$MIRROR/carplay-alt111-mirror-display" ] && echo "READBACK_BINARY=INSTALLED" || echo "READBACK_BINARY=MISSING"

HOOK_LOG=""
for candidate in "$DEVICE_ROOT/tmp/MMI-Cockpit-Carplay/altscreen_hook.log" "$DEVICE_ROOT/tmp/MMI-Cockpit-Carplay.altscreen_hook.log" "$DEVICE_ROOT/tmp/altscreen_hook.log"; do
    [ -f "$candidate" ] && { HOOK_LOG=$candidate; break; }
done
SOURCE_READY=0
if [ -n "$HOOK_LOG" ] && grep -q 'PHASE=NATIVE_111_FIRST_REAL_FRAME.*result=POSTED' "$HOOK_LOG" 2>/dev/null; then
    SOURCE_READY=1
    echo "NATIVE_FRAME_READY=YES meaning=Window58_stock_post"
else
    echo "NATIVE_FRAME_READY=NO"
fi

DEST=0
if [ -f "$DEST_READY" ]; then
    DEST=1
    echo "DEST_FRAME_READY=YES meaning=readback_plus_first_gles_present"
    cat "$DEST_READY" 2>/dev/null || true
else
    echo "DEST_FRAME_READY=NO"
fi

[ -f "$STARTED" ] && echo "JAVA_CONTROLLER=STARTED" || echo "JAVA_CONTROLLER=NOT_STARTED"
CTXREQ=0
if [ -f "$JAVA_LOG" ]; then
    if grep -q 'ownership acquired -> ctx80' "$JAVA_LOG" 2>/dev/null; then
        CTXREQ=1
        echo "JAVA_CTX80_REQUEST=YES"
    else
        echo "JAVA_CTX80_REQUEST=NO"
    fi
    echo "JAVA80_LOG_TAIL_BEGIN"
    tail -n 30 "$JAVA_LOG" 2>/dev/null || true
    echo "JAVA80_LOG_TAIL_END"
else
    echo "JAVA_CTX80_REQUEST=UNKNOWN log_missing=1"
fi

if [ -f "$MIRROR_LOG" ]; then
    echo "READBACK_LOG_TAIL_BEGIN"
    tail -n 40 "$MIRROR_LOG" 2>/dev/null || true
    echo "READBACK_LOG_TAIL_END"
fi

if [ "$SOURCE_READY" = 1 ] && [ "$DEST" = 1 ] && [ "$MIRROR_RUNNING" = 1 ] && [ "$CTXREQ" = 1 ]; then
    echo "PHYSICAL_ROUTE_READY=SOFTWARE_CHAIN_COMPLETE human_vc_confirmation_required=YES"
else
    echo "PHYSICAL_ROUTE_READY=NO source=$SOURCE_READY destination=$DEST sidecar=$MIRROR_RUNNING java80=$CTXREQ"
fi
exit "$STATUS_RC"
