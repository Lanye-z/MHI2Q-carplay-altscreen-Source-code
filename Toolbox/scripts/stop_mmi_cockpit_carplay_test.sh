#!/bin/sh
# MMI-Cockpit-Carplay GEM RESTORE ORIGINAL action.
# Disable/stop the integrated Mirror sidecar first, remove its boot loop, then let
# the canonical AltScreen controller restore the backed-up CarPlay files.
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
APP_SELF="$APP_BIN/stop_mmi_cockpit_carplay_test.sh"
# ALTSCREEN_FAKE_RECORD is host-test-only. Production always forwards from a
# legacy /eso GEM bootstrap to the owned /mnt/app runtime when it exists.
if { [ "$TESTING" != 1 ] || [ -z "${ALTSCREEN_FAKE_RECORD:-}" ]; } &&
   [ "$SCRIPTDIR" != "$APP_BIN" ] && [ -f "$APP_SELF" ] &&
   [ -f "$APP_BIN/altscreen_chain_test.sh" ]; then
    echo "APP_RUNTIME_FORWARD action=RESTORE from=$SCRIPTDIR to=/mnt/app/root/carplay-altscreen/bin"
    exec /bin/sh "$APP_SELF" "$@"
fi

CONTROLLER="$SCRIPTDIR/altscreen_chain_test.sh"
[ -f "$CONTROLLER" ] || { echo "FAIL: installed chain controller is missing: $CONTROLLER"; exit 127; }

RUNTIME="$DEVICE_ROOT/mnt/app/root/carplay-altscreen"
MIRROR="$RUNTIME/bin/mirror"
MIRROR_ENABLED="$RUNTIME/state/mirror.enabled"
OWNER="$MIRROR/.mmi-cockpit-carplay-mirror-owner"
PREVIOUS="$RUNTIME/tmp/mirror.previous"
PREVIOUS_OWNER="$PREVIOUS/.mmi-cockpit-carplay-mirror-owner"

# Legacy host fixtures have no Mirror runtime; keep their controller contract.
if [ "$TESTING" = 1 ] && [ ! -e "$MIRROR" ] && [ ! -e "$PREVIOUS" ]; then
    exec /bin/sh "$CONTROLLER" restore
fi

mount_app_rw(){ [ "$TESTING" = 1 ] || mount -uw /mnt/app; }
mount_app_ro(){ [ "$TESTING" = 1 ] || mount -ur /mnt/app; }
mount_system_rw(){ [ "$TESTING" = 1 ] || mount -uw /mnt/system; }
mount_system_ro(){ [ "$TESTING" = 1 ] || mount -ur /mnt/system; }
strip_block(){
    awk '
      $0 == "# BEGIN ALT111 MIRROR AUTOSTART" { if (inside || seen++) exit 9; inside=1; next }
      $0 == "# END ALT111 MIRROR AUTOSTART" { if (!inside) exit 9; inside=0; next }
      !inside { print }
      END { if (inside) exit 9 }
    ' "$1"
}

if [ -d "$MIRROR" ] && [ ! -f "$OWNER" ]; then
    echo "FAIL: refusing to remove unowned Mirror runtime: $MIRROR" >&2
    exit 1
fi
if [ -d "$PREVIOUS" ] && [ ! -f "$PREVIOUS_OWNER" ]; then
    echo "FAIL: refusing to remove unowned previous Mirror runtime: $PREVIOUS" >&2
    exit 1
fi
if [ -d "$MIRROR" ]; then
    mount_app_rw || { echo "FAIL: cannot mount /mnt/app writable to disable Mirror" >&2; exit 1; }
    rm -f "$MIRROR_ENABLED" || { mount_app_ro >/dev/null 2>&1 || true; echo "FAIL: cannot disable Mirror runtime" >&2; exit 1; }
    sync || true
    mount_app_ro || { echo "FAIL: cannot remount /mnt/app read-only" >&2; exit 1; }
    if [ -x "$MIRROR/stop_vehicle.sh" ]; then
        /bin/sh "$MIRROR/stop_vehicle.sh" || echo "WARN: Mirror stop reported an error; restore continues"
    fi
fi

STARTUP=""
for candidate in "$DEVICE_ROOT/mnt/system/etc/boot/startup.sh" "$DEVICE_ROOT/etc/boot/startup.sh"; do
    if [ -f "$candidate" ]; then STARTUP=$candidate; break; fi
done
if [ -n "$STARTUP" ]; then
    mount_system_rw || { echo "FAIL: cannot mount /mnt/system writable to remove Mirror autostart" >&2; exit 1; }
    CLEAN="$STARTUP.mirror.restore.$$"
    strip_block "$STARTUP" > "$CLEAN" || {
        rm -f "$CLEAN"; mount_system_ro >/dev/null 2>&1 || true; echo "FAIL: invalid Mirror autostart block" >&2; exit 1; }
    sh -n "$CLEAN" || {
        rm -f "$CLEAN"; mount_system_ro >/dev/null 2>&1 || true; echo "FAIL: startup.sh invalid after Mirror block removal" >&2; exit 1; }
    cp "$CLEAN" "$STARTUP" && chmod 755 "$STARTUP" || {
        rm -f "$CLEAN"; mount_system_ro >/dev/null 2>&1 || true; echo "FAIL: cannot publish startup.sh without Mirror block" >&2; exit 1; }
    rm -f "$CLEAN"
    sync || true
    mount_system_ro || { echo "FAIL: cannot remount /mnt/system read-only" >&2; exit 1; }
fi

/bin/sh "$CONTROLLER" restore
RESTORE_RC=$?
[ "$RESTORE_RC" -eq 0 ] || exit "$RESTORE_RC"

if [ -d "$MIRROR" ] || [ -d "$PREVIOUS" ]; then
    mount_app_rw || { echo "FAIL: originals restored but Mirror runtime directories could not be removed" >&2; exit 1; }
    [ ! -d "$MIRROR" ] || rm -rf "$MIRROR" || { mount_app_ro >/dev/null 2>&1 || true; echo "FAIL: cannot remove owned Mirror runtime" >&2; exit 1; }
    [ ! -d "$PREVIOUS" ] || rm -rf "$PREVIOUS" || { mount_app_ro >/dev/null 2>&1 || true; echo "FAIL: cannot remove owned previous Mirror runtime" >&2; exit 1; }
    sync || true
    mount_app_ro || { echo "FAIL: cannot remount /mnt/app read-only" >&2; exit 1; }
fi

echo "MIRROR_RUNTIME=REMOVED autostart=DISABLED previous=REMOVED"
echo "RESTORE=PASS integrated=AltScreen+Mirror reboot_required=YES"
exit 0
