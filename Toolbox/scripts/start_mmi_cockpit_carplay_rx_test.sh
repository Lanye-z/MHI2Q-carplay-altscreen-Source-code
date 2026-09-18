#!/bin/sh
# Standalone BaseVideo3 START.
# Arms type111, persists the BaseVideo demand marker across reboot, and leaves
# terminal1/ctx80 ownership exclusively to the installed Java HMI controller.
set -u

BASE="$0"
RESOLVED=$(command -v -- "$BASE" 2>/dev/null)
[ -n "$RESOLVED" ] || RESOLVED="$BASE"
SCRIPTDIR=$(cd -P -- "$(dirname -- "$RESOLVED")" 2>/dev/null && pwd -P)
[ -n "$SCRIPTDIR" ] || { echo "FAIL: cannot resolve START directory"; exit 126; }

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
    if [ "$#" -gt 0 ]; then
        exec /bin/sh "$APP_SELF" "$@"
    else
        exec /bin/sh "$APP_SELF"
    fi
fi

CONTROLLER="$SCRIPTDIR/altscreen_chain_test.sh"
[ -f "$CONTROLLER" ] || { echo "FAIL: installed chain controller missing"; exit 127; }

RUNTIME="$DEVICE_ROOT/mnt/app/root/carplay-altscreen"
STATE="$RUNTIME/state"
ENABLED="$STATE/basevideo3.enabled"
JAR="$DEVICE_ROOT/mnt/app/eso/hmi/lsd/jars/carplay_hook.jar"
EXPECTED_SIZE=141858
EXPECTED_CKSUM=2378993239
ACTIVE="$DEVICE_ROOT/tmp/mmi-mirror-active"
READY="$DEVICE_ROOT/tmp/mmi-mirror-basevideo.ready"
STARTED="$DEVICE_ROOT/tmp/mmi-mirror-controller.started"

file_size(){ n=$(wc -c < "$1" 2>/dev/null) || { echo 0; return; }; set -- $n; echo "${1:-0}"; }
file_cksum(){ if command -v cksum >/dev/null 2>&1; then cksum < "$1" 2>/dev/null | awk '{print $1}'; else echo unavailable; fi; }
jar_valid(){
    [ -s "$JAR" ] || return 1
    [ "$(file_size "$JAR")" = "$EXPECTED_SIZE" ] || return 1
    sum=$(file_cksum "$JAR")
    [ "$sum" = unavailable ] || [ "$sum" = "$EXPECTED_CKSUM" ]
}
mount_app_rw(){ [ "$TESTING" = 1 ] || mount -uw /mnt/app; }
mount_app_ro(){ [ "$TESTING" = 1 ] || mount -ur /mnt/app; }
mount_system_rw(){ [ "$TESTING" = 1 ] || mount -uw /mnt/system; }
mount_system_ro(){ [ "$TESTING" = 1 ] || mount -ur /mnt/system; }

jar_valid || {
    echo "FAIL: standalone Java80 HMI JAR missing or mismatched"
    echo "expected_size=$EXPECTED_SIZE expected_cksum=$EXPECTED_CKSUM"
    [ -f "$JAR" ] && echo "actual_size=$(file_size "$JAR") actual_cksum=$(file_cksum "$JAR")"
    exit 1
}

STARTUP=""
for candidate in "$DEVICE_ROOT/mnt/system/etc/boot/startup.sh" "$DEVICE_ROOT/etc/boot/startup.sh"; do
    if [ -f "$candidate" ]; then STARTUP=$candidate; break; fi
done
[ -n "$STARTUP" ] || { echo "FAIL: startup.sh not found"; exit 1; }

strip_blocks(){
    awk '
      $0 == "# BEGIN ALT111 MIRROR AUTOSTART" { in_old=1; next }
      $0 == "# END ALT111 MIRROR AUTOSTART"   { in_old=0; next }
      $0 == "# BEGIN ALT111 BASEVIDEO3 AUTOSTART" { in_new=1; next }
      $0 == "# END ALT111 BASEVIDEO3 AUTOSTART"   { in_new=0; next }
      !in_old && !in_new { print }
      END { if (in_old || in_new) exit 9 }
    ' "$1"
}

CLEAN="$STARTUP.basevideo3.clean.$$"
BLOCK="$STARTUP.basevideo3.block.$$"
NEW="$STARTUP.basevideo3.new.$$"
ORIGINAL="$STARTUP.basevideo3.original.$$"
cleanup(){ rm -f "$CLEAN" "$BLOCK" "$NEW" "$ORIGINAL" 2>/dev/null || true; }

APP_RW=0
SYSTEM_RW=0
STARTUP_CHANGED=0
ENABLED_CREATED=0
rollback(){
    if [ "$STARTUP_CHANGED" = 1 ] && [ -f "$ORIGINAL" ]; then
        [ "$SYSTEM_RW" = 1 ] || { mount_system_rw >/dev/null 2>&1 && SYSTEM_RW=1; }
        [ "$SYSTEM_RW" != 1 ] || { cp "$ORIGINAL" "$STARTUP" >/dev/null 2>&1 || true; chmod 755 "$STARTUP" >/dev/null 2>&1 || true; }
    fi
    [ "$SYSTEM_RW" != 1 ] || { mount_system_ro >/dev/null 2>&1 || true; SYSTEM_RW=0; }
    if [ "$ENABLED_CREATED" = 1 ]; then
        [ "$APP_RW" = 1 ] || { mount_app_rw >/dev/null 2>&1 && APP_RW=1; }
        [ "$APP_RW" != 1 ] || rm -f "$ENABLED" >/dev/null 2>&1 || true
    fi
    [ "$APP_RW" != 1 ] || { mount_app_ro >/dev/null 2>&1 || true; APP_RW=0; }
    rm -f "$ACTIVE" "$READY" 2>/dev/null || true
    cleanup
}
fail(){ msg=$1; rollback; echo "FAIL: $msg" >&2; exit 1; }

mount_app_rw || fail "cannot mount /mnt/app writable"
APP_RW=1
mkdir -p "$STATE" || fail "cannot create runtime state directory"
touch "$ENABLED" || fail "cannot enable BaseVideo3 boot demand"
ENABLED_CREATED=1
sync >/dev/null 2>&1 || true
mount_app_ro || fail "cannot remount /mnt/app read-only"
APP_RW=0

mount_system_rw || fail "cannot mount /mnt/system writable"
SYSTEM_RW=1
cp "$STARTUP" "$ORIGINAL" || fail "cannot snapshot startup.sh"
strip_blocks "$STARTUP" > "$CLEAN" || fail "invalid existing BaseVideo3/Mirror autostart block"
cat > "$BLOCK" <<'BASEVIDEO3_BOOT'
# BEGIN ALT111 BASEVIDEO3 AUTOSTART
if [ -f /mnt/app/root/carplay-altscreen/state/basevideo3.enabled ]; then
    rm -f /tmp/mmi-mirror-basevideo.ready >/dev/null 2>&1 || true
    touch /tmp/mmi-mirror-active >/dev/null 2>&1 || true
fi
# END ALT111 BASEVIDEO3 AUTOSTART
BASEVIDEO3_BOOT
awk 'FNR==NR {b=b $0 "\n"; next} FNR==1 {if ($0 ~ /^#!/) {print; printf "%s",b; next} printf "%s",b} {print}' "$BLOCK" "$CLEAN" > "$NEW" ||
    fail "cannot compose BaseVideo3 autostart"
sh -n "$NEW" || fail "BaseVideo3 autostart makes startup.sh invalid"
cp "$NEW" "$STARTUP" || fail "cannot publish BaseVideo3 autostart"
chmod 755 "$STARTUP" || fail "cannot chmod startup.sh"
STARTUP_CHANGED=1
sync >/dev/null 2>&1 || true
mount_system_ro || fail "cannot remount /mnt/system read-only"
SYSTEM_RW=0

rm -f "$READY" 2>/dev/null || true
touch "$ACTIVE" || fail "cannot publish current-boot BaseVideo demand"

ALTSCREEN_INTEGRATED_START=1 /bin/sh "$CONTROLLER" start
RC=$?
[ "$RC" -eq 0 ] || { rollback; exit "$RC"; }

cleanup
echo "DISPLAY_PATH=BASEVIDEO3_NATIVE source=private111_stock_omx_cscreenrender displayable=3"
echo "HMI_CONTROL_PLANE=JAVA80 context=80 composite=98,101,102,3"
echo "CONTEXT_POLICY=JAVA_ONLY native_dmdt=0"
echo "BASEVIDEO3_BOOT_DEMAND=ENABLED marker=/tmp/mmi-mirror-active"
echo "READY_MARKER=/tmp/mmi-mirror-basevideo.ready first_successful_stock_post_only=1"
if [ -f "$STARTED" ]; then echo "JAVA_CONTROLLER=OBSERVED current_boot=YES"; else echo "JAVA_CONTROLLER=NOT_YET_OBSERVED current_boot=NO_or_reboot_pending"; fi
echo "MMI_MIRROR_SIDECAR=DISABLED"
echo "START=PASS integrated=AltScreen+BaseVideo3+Java80 reboot_required=YES"
exit 0
