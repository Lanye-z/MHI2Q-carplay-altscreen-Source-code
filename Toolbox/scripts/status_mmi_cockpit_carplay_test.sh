#!/bin/sh
# MMI-Cockpit-Carplay GEM STATUS action.
# Report the canonical AltScreen controller state plus the integrated Mirror
# runtime/autostart state.
BASE="$0"
RESOLVED=$(command -v -- "$BASE" 2>/dev/null)
[ -n "$RESOLVED" ] || RESOLVED="$BASE"
SCRIPTDIR=$(cd -P -- "$(dirname -- "$RESOLVED")" 2>/dev/null && pwd -P)
[ -n "$SCRIPTDIR" ] || { echo "FAIL: cannot resolve installed launcher directory"; exit 126; }

TESTING=${ALTSCREEN_CHAIN_TESTING:-0}
DEVICE_ROOT=""
if [ "$TESTING" = 1 ]; then
    DEVICE_ROOT=${ALTSCREEN_CHAIN_ROOT:-}
    case "$DEVICE_ROOT" in /tmp/*|/var/tmp/*) ;; *) echo "FAIL: invalid ALTSCREEN_CHAIN_ROOT"; exit 2 ;; esac
fi
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
MIRROR="$RUNTIME/bin/mirror"
MIRROR_ENABLED="$RUNTIME/state/mirror.enabled"
if [ -x "$MIRROR/carplay-alt111-mirror-display" ] && [ -x "$MIRROR/start_vehicle.sh" ]; then
    echo "MIRROR_INSTALLED=YES path=/mnt/app/root/carplay-altscreen/bin/mirror"
else
    echo "MIRROR_INSTALLED=NO"
fi
[ -f "$MIRROR_ENABLED" ] && echo "MIRROR_AUTOSTART=ENABLED" || echo "MIRROR_AUTOSTART=DISABLED"
MIRROR_PID=""
MIRROR_VOLATILE_MODE=NONE
if [ -f "$DEVICE_ROOT/tmp/MMI-Cockpit-Carplay/mirror/pid" ]; then
    MIRROR_PID="$DEVICE_ROOT/tmp/MMI-Cockpit-Carplay/mirror/pid"; MIRROR_VOLATILE_MODE=NAMESPACE
elif [ -f "$DEVICE_ROOT/tmp/MMI-Cockpit-Carplay.mirror.pid" ]; then
    MIRROR_PID="$DEVICE_ROOT/tmp/MMI-Cockpit-Carplay.mirror.pid"; MIRROR_VOLATILE_MODE=FLAT_TMP
fi
if [ -n "$MIRROR_PID" ]; then
    PID=$(cat "$MIRROR_PID" 2>/dev/null || true)
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then echo "MIRROR_PROCESS=RUNNING pid=$PID volatile_mode=$MIRROR_VOLATILE_MODE"; else echo "MIRROR_PROCESS=STALE_PID volatile_mode=$MIRROR_VOLATILE_MODE"; fi
else
    echo "MIRROR_PROCESS=NOT_RUNNING"
fi
if [ -f "$DEVICE_ROOT/tmp/MMI-Cockpit-Carplay/mirror/ready" ] || [ -f "$DEVICE_ROOT/tmp/MMI-Cockpit-Carplay.mirror.ready" ]; then echo "MIRROR_FIRST_FRAME=READY"; else echo "MIRROR_FIRST_FRAME=WAITING"; fi
echo "MIRROR_SOURCE=private111_window58 sink=displayable3 context=76"
exit "$STATUS_RC"
