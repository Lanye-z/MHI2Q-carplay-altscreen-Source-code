#!/bin/sh
# BaseVideo3 native visible-probe START wrapper.
# private111 stays inside stock ScreenStream/OMX/CScreenRender and posts directly
# to a managed ID_STRING="3" window. Java/HMI remains the sole ctx80 writer.
# Mirror readback/GLES and native dmdt routing are deliberately disabled.

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
APP_SELF="$APP_BIN/start_mmi_cockpit_carplay_rx_test.sh"
if [ "$SCRIPTDIR" != "$APP_BIN" ] && [ -f "$APP_SELF" ] && [ -f "$APP_BIN/altscreen_chain_test.sh" ]; then
    echo "APP_RUNTIME_FORWARD action=START from=$SCRIPTDIR to=/mnt/app/root/carplay-altscreen/bin"
    exec /bin/sh "$APP_SELF" "$@"
fi

CONTROLLER="$SCRIPTDIR/altscreen_chain_test.sh"
[ -f "$CONTROLLER" ] || { echo "FAIL: installed chain controller is missing: $CONTROLLER"; exit 127; }

RUNTIME="$DEVICE_ROOT/mnt/app/root/carplay-altscreen"
MIRROR="$RUNTIME/bin/mirror"
MIRROR_ENABLED="$RUNTIME/state/mirror.enabled"

mount_app_rw(){ [ "$TESTING" = 1 ] || mount -uw /mnt/app; }
mount_app_ro(){ [ "$TESTING" = 1 ] || mount -ur /mnt/app; }
mount_system_rw(){ [ "$TESTING" = 1 ] || mount -uw /mnt/system; }
mount_system_ro(){ [ "$TESTING" = 1 ] || mount -ur /mnt/system; }

strip_mirror_block(){
    awk '
      $0 == "# BEGIN ALT111 MIRROR AUTOSTART" { if (inside || seen++) exit 9; inside=1; next }
      $0 == "# END ALT111 MIRROR AUTOSTART" { if (!inside) exit 9; inside=0; next }
      !inside { print }
      END { if (inside) exit 9 }
    ' "$1"
}

if [ -x "$MIRROR/stop_vehicle.sh" ]; then
    /bin/sh "$MIRROR/stop_vehicle.sh" >/dev/null 2>&1 || true
fi

if [ -f "$MIRROR_ENABLED" ]; then
    mount_app_rw || { echo "FAIL: cannot mount /mnt/app to disable stale Mirror"; exit 1; }
    rm -f "$MIRROR_ENABLED" || { mount_app_ro >/dev/null 2>&1 || true; echo "FAIL: cannot disable stale Mirror marker"; exit 1; }
    sync >/dev/null 2>&1 || true
    mount_app_ro >/dev/null 2>&1 || true
fi

STARTUP=""
for candidate in "$DEVICE_ROOT/mnt/system/etc/boot/startup.sh" "$DEVICE_ROOT/etc/boot/startup.sh"; do
    if [ -f "$candidate" ]; then STARTUP=$candidate; break; fi
done
if [ -n "$STARTUP" ] && grep -q '^# BEGIN ALT111 MIRROR AUTOSTART$' "$STARTUP" 2>/dev/null; then
    CLEAN="$STARTUP.native-direct.clean.$$"
    mount_system_rw || { echo "FAIL: cannot mount /mnt/system to remove stale Mirror autostart"; exit 1; }
    if ! strip_mirror_block "$STARTUP" > "$CLEAN"; then
        rm -f "$CLEAN" 2>/dev/null || true
        mount_system_ro >/dev/null 2>&1 || true
        echo "FAIL: invalid stale Mirror autostart block" >&2
        exit 1
    fi
    sh -n "$CLEAN" || {
        rm -f "$CLEAN" 2>/dev/null || true
        mount_system_ro >/dev/null 2>&1 || true
        echo "FAIL: startup.sh invalid after removing Mirror block" >&2
        exit 1
    }
    cp "$CLEAN" "$STARTUP" && chmod 755 "$STARTUP" || {
        rm -f "$CLEAN" 2>/dev/null || true
        mount_system_ro >/dev/null 2>&1 || true
        echo "FAIL: cannot publish startup.sh without Mirror block" >&2
        exit 1
    }
    rm -f "$CLEAN" 2>/dev/null || true
    sync >/dev/null 2>&1 || true
    mount_system_ro >/dev/null 2>&1 || true
fi

rm -f "$DEVICE_ROOT/tmp/mmi-mirror-basevideo.ready" 2>/dev/null || true

ALTSCREEN_INTEGRATED_START=1 /bin/sh "$CONTROLLER" start
RC=$?
[ "$RC" -eq 0 ] || exit "$RC"

echo "MIRROR_POLICY=DISABLED readback=0 bgra=0 gles=0"
echo "DISPLAY_PATH=BASEVIDEO3_NATIVE source=private111_stock_omx_cscreenrender displayable=3"
echo "WINDOW_POLICY=STOCK_CSCREENRENDER manager=screen_manage_window force_visible=1"
echo "CONTEXT_POLICY=JAVA_ONLY context=80 native_dmdt=0"
echo "READY_MARKER=/tmp/mmi-mirror-basevideo.ready first_successful_stock_post_only=1"
echo "START=PASS integrated=AltScreen+BaseVideo3VisibleProbe reboot_required=YES"
exit 0
