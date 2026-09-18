#!/bin/sh
# BaseVideo3 native visible-probe STATUS wrapper.
BASE="$0"
RESOLVED=$(command -v -- "$BASE" 2>/dev/null)
[ -n "$RESOLVED" ] || RESOLVED="$BASE"
SCRIPTDIR=$(cd -P -- "$(dirname -- "$RESOLVED")" 2>/dev/null && pwd -P)
[ -n "$SCRIPTDIR" ] || { echo "FAIL: cannot resolve installed status directory"; exit 126; }

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
[ -f "$CONTROLLER" ] || { echo "FAIL: installed chain controller is missing: $CONTROLLER"; exit 127; }
/bin/sh "$CONTROLLER" status
STATUS_RC=$?

RUNTIME="$DEVICE_ROOT/mnt/app/root/carplay-altscreen"
MIRROR_ENABLED="$RUNTIME/state/mirror.enabled"
echo "DISPLAY_PATH=BASEVIDEO3_NATIVE source=private111_stock_omx_cscreenrender displayable=3"
echo "NATIVE_BUFFER_OWNER=STOCK_OMX"
echo "NATIVE_WINDOW_OWNER=STOCK_CSCREENRENDER_PLUS_screen_manage_window"
echo "WINDOW_VISIBLE_POLICY=FORCED_PRIVATE_ONLY value=1"
echo "CONTEXT_POLICY=JAVA_ONLY context=80 native_dmdt=0"
echo "READBACK_PIPELINE=DISABLED screen_read_window=0 bgra=0 gles=0"
if [ -f "$MIRROR_ENABLED" ]; then
    echo "MIRROR_POLICY=FAIL reason=stale_mirror_enabled"
    [ "$STATUS_RC" -ne 0 ] || STATUS_RC=1
else
    echo "MIRROR_POLICY=DISABLED"
fi

HOOK_LOG=""
for candidate in "$DEVICE_ROOT/tmp/MMI-Cockpit-Carplay/altscreen_hook.log" "$DEVICE_ROOT/tmp/altscreen_hook.log"; do
    [ -f "$candidate" ] && { HOOK_LOG=$candidate; break; }
done
READY="$DEVICE_ROOT/tmp/mmi-mirror-basevideo.ready"
if [ -f "$READY" ]; then
    echo "BASEVIDEO3_READY=YES"
    cat "$READY" 2>/dev/null || true
else
    echo "BASEVIDEO3_READY=NO"
fi
if [ -n "$HOOK_LOG" ]; then
    grep '\[MAIN110\].*PHASE=CSCREEN_CONFIG' "$HOOK_LOG" 2>/dev/null | tail -n 1 || true
    grep '\[ALT111\].*PHASE=NATIVE_111_ATTACH' "$HOOK_LOG" 2>/dev/null | tail -n 1 || true
    grep 'PHASE=BASEVIDEO3_WINDOW_PROBE' "$HOOK_LOG" 2>/dev/null | tail -n 4 || true
    grep 'PHASE=BASEVIDEO3_FORCE_VISIBLE' "$HOOK_LOG" 2>/dev/null | tail -n 1 || true
    grep '\[BASEVIDEO3\].*PHASE=BASEVIDEO3_READY' "$HOOK_LOG" 2>/dev/null | tail -n 1 || true
fi
exit "$STATUS_RC"
