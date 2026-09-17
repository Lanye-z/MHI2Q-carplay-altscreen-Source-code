#!/bin/sh
# MMI-Cockpit-Carplay GEM START action (RX entry point).
#
# START is one transaction: arm the AltScreen controller, enable the installed
# Mirror runtime and publish its boot loop. Any Mirror-side failure restores the
# exact startup.sh bytes, removes .enabled, then asks the canonical controller to
# restore the CarPlay transaction so a partial START cannot masquerade as active.
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

ALTSCREEN_INTEGRATED_START=1 /bin/sh "$CONTROLLER" start
CHAIN_RC=$?
[ "$CHAIN_RC" -eq 0 ] || exit "$CHAIN_RC"

RUNTIME="$DEVICE_ROOT/mnt/app/root/carplay-altscreen"
MIRROR="$RUNTIME/bin/mirror"
MIRROR_ENABLED="$RUNTIME/state/mirror.enabled"
OWNER="$MIRROR/.mmi-cockpit-carplay-mirror-owner"
PREVIOUS="$RUNTIME/tmp/mirror.previous"
PREVIOUS_OWNER="$PREVIOUS/.mmi-cockpit-carplay-mirror-owner"
RUNTIME_PREVIOUS="$DEVICE_ROOT/mnt/app/root/.carplay-altscreen.previous"
LEGACY_MIRROR="$DEVICE_ROOT/mnt/app/root/carplay-alt111-mirror"
LEGACY_MIRROR_PREVIOUS="$DEVICE_ROOT/mnt/app/root/.carplay-alt111-mirror.previous"

# Existing controller-only host fixtures deliberately carry no sidecar. A real
# vehicle is fail-closed: START requires the runtime installed by integrated INSTALL.
if [ ! -x "$MIRROR/start_vehicle.sh" ] || [ ! -x "$MIRROR/carplay-alt111-mirror-display" ] || [ ! -f "$OWNER" ]; then
    if [ "$TESTING" = 1 ] && [ ! -e "$MIRROR" ]; then
        echo "MIRROR_AUTOSTART=TEST_FIXTURE_ABSENT integration_skipped=1"
        exit 0
    fi
    echo "FAIL: integrated Mirror runtime is missing or unowned; run INSTALL again" >&2
    /bin/sh "$CONTROLLER" restore >/dev/null 2>&1 || echo "WARN: automatic AltScreen restore failed; use RESTORE ORIGINAL before reboot"
    exit 1
fi
if [ -e "$PREVIOUS" ] && [ ! -f "$PREVIOUS_OWNER" ]; then
    echo "FAIL: refusing to remove unowned previous Mirror runtime: $PREVIOUS" >&2
    /bin/sh "$CONTROLLER" restore >/dev/null 2>&1 || echo "WARN: automatic AltScreen restore failed; use RESTORE ORIGINAL before reboot"
    exit 1
fi

STARTUP=""
for candidate in "$DEVICE_ROOT/mnt/system/etc/boot/startup.sh" "$DEVICE_ROOT/etc/boot/startup.sh"; do
    if [ -f "$candidate" ]; then STARTUP=$candidate; break; fi
done
if [ -z "$STARTUP" ]; then
    echo "FAIL: startup.sh not found for Mirror autostart" >&2
    /bin/sh "$CONTROLLER" restore >/dev/null 2>&1 || echo "WARN: automatic AltScreen restore failed; use RESTORE ORIGINAL before reboot"
    exit 1
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

APP_RW=0
SYSTEM_RW=0
ENABLED_CREATED=0
BOOT_TOUCHED=0
CLEAN="$STARTUP.mirror.clean.$$"
BLOCK="$STARTUP.mirror.block.$$"
NEW="$STARTUP.mirror.new.$$"
ORIGINAL="$STARTUP.mirror.original.$$"
cleanup_temps(){ rm -f "$CLEAN" "$BLOCK" "$NEW" "$ORIGINAL" 2>/dev/null || true; }
rollback_start(){
    if [ "$BOOT_TOUCHED" = 1 ] && [ -f "$ORIGINAL" ]; then
        if [ "$SYSTEM_RW" != 1 ]; then
            if mount_system_rw >/dev/null 2>&1; then SYSTEM_RW=1; fi
        fi
        if [ "$SYSTEM_RW" = 1 ]; then
            cp "$ORIGINAL" "$STARTUP" >/dev/null 2>&1 && chmod 755 "$STARTUP" >/dev/null 2>&1 && sync >/dev/null 2>&1 ||
                echo "WARN: could not restore exact startup.sh bytes during START rollback"
        else
            echo "WARN: could not remount /mnt/system to restore startup.sh during START rollback"
        fi
    fi
    if [ "$SYSTEM_RW" = 1 ]; then mount_system_ro >/dev/null 2>&1 || true; SYSTEM_RW=0; fi

    if [ "$ENABLED_CREATED" = 1 ]; then
        if [ "$APP_RW" != 1 ]; then
            if mount_app_rw >/dev/null 2>&1; then APP_RW=1; fi
        fi
        if [ "$APP_RW" = 1 ]; then
            rm -f "$MIRROR_ENABLED" >/dev/null 2>&1 || true
            sync >/dev/null 2>&1 || true
        else
            echo "WARN: could not remount /mnt/app to clear Mirror .enabled during START rollback"
        fi
    fi
    if [ "$APP_RW" = 1 ]; then mount_app_ro >/dev/null 2>&1 || true; APP_RW=0; fi
    cleanup_temps
    echo "WARN: Mirror autostart setup failed; restoring AltScreen transaction"
    /bin/sh "$CONTROLLER" restore >/dev/null 2>&1 || echo "WARN: automatic AltScreen restore failed; use RESTORE ORIGINAL before reboot"
}

mount_app_rw || { rollback_start; echo "FAIL: cannot mount /mnt/app writable" >&2; exit 1; }
APP_RW=1
# INSTALL may retain one owned rollback copy until the next safe app-RW phase.
# START is that phase, so retire it before arming the runtime.
if [ -d "$PREVIOUS" ]; then
    [ -f "$PREVIOUS_OWNER" ] || { rollback_start; echo "FAIL: previous Mirror runtime lost ownership marker" >&2; exit 1; }
    rm -rf "$PREVIOUS" || { rollback_start; echo "FAIL: cannot retire previous Mirror runtime" >&2; exit 1; }
fi
if [ -d "$RUNTIME_PREVIOUS" ]; then
    [ -f "$RUNTIME_PREVIOUS/.mmi-cockpit-carplay-runtime-owner" ] || { rollback_start; echo "FAIL: previous unified runtime lost ownership marker" >&2; exit 1; }
    rm -rf "$RUNTIME_PREVIOUS" || { rollback_start; echo "FAIL: cannot retire previous unified runtime" >&2; exit 1; }
fi
for legacy in "$LEGACY_MIRROR" "$LEGACY_MIRROR_PREVIOUS"; do
    if [ -d "$legacy" ]; then
        [ -f "$legacy/.mmi-cockpit-carplay-mirror-owner" ] || { rollback_start; echo "FAIL: legacy Mirror runtime is unowned: $legacy" >&2; exit 1; }
        rm -rf "$legacy" || { rollback_start; echo "FAIL: cannot retire legacy Mirror runtime: $legacy" >&2; exit 1; }
    fi
done
touch "$MIRROR_ENABLED" || { rollback_start; echo "FAIL: cannot enable Mirror runtime" >&2; exit 1; }
ENABLED_CREATED=1
if ! mount_app_ro; then rollback_start; echo "FAIL: cannot remount /mnt/app read-only" >&2; exit 1; fi
APP_RW=0

mount_system_rw || { rollback_start; echo "FAIL: cannot mount /mnt/system writable" >&2; exit 1; }
SYSTEM_RW=1
cp "$STARTUP" "$ORIGINAL" || { rollback_start; echo "FAIL: cannot snapshot startup.sh before Mirror autostart" >&2; exit 1; }
strip_block "$STARTUP" > "$CLEAN" || { rollback_start; echo "FAIL: invalid existing Mirror autostart block" >&2; exit 1; }
cat > "$BLOCK" <<'MIRROR_BOOT'
# BEGIN ALT111 MIRROR AUTOSTART
(
    RUNTIME=/mnt/app/root/carplay-altscreen
    MIRROR="$RUNTIME/bin/mirror"
    ENABLED="$RUNTIME/state/mirror.enabled"
    while [ -f "$ENABLED" ]; do
        if [ -x "$MIRROR/start_vehicle.sh" ]; then
            MIRROR_PARENT=/tmp/MMI-Cockpit-Carplay
            MIRROR_TMP="$MIRROR_PARENT/mirror"
            [ -d "$MIRROR_PARENT" ] || mkdir "$MIRROR_PARENT" >/dev/null 2>&1 || true
            [ ! -d "$MIRROR_PARENT" ] || [ -d "$MIRROR_TMP" ] || mkdir "$MIRROR_TMP" >/dev/null 2>&1 || true
            if [ -d "$MIRROR_TMP" ]; then MIRROR_LOG="$MIRROR_TMP/autostart.log"; else MIRROR_LOG=/tmp/MMI-Cockpit-Carplay.mirror.autostart.log; fi
            if ( : >> "$MIRROR_LOG" ) 2>/dev/null; then
                /bin/sh "$MIRROR/start_vehicle.sh" >> "$MIRROR_LOG" 2>&1 || true
            else
                /bin/sh "$MIRROR/start_vehicle.sh" >/dev/null 2>&1 || true
            fi
        fi
        sleep 2
    done
) > /dev/null 2>&1 < /dev/null &
# END ALT111 MIRROR AUTOSTART
MIRROR_BOOT
awk 'FNR==NR {block=block $0 "\n"; next}
     FNR==1 {if ($0 ~ /^#!/) {print; printf "%s",block; next} printf "%s",block}
     {print}' "$BLOCK" "$CLEAN" > "$NEW" || {
        rollback_start; echo "FAIL: cannot compose Mirror autostart" >&2; exit 1; }
sh -n "$NEW" || { rollback_start; echo "FAIL: Mirror autostart makes startup.sh invalid" >&2; exit 1; }
cp "$NEW" "$STARTUP" || { rollback_start; echo "FAIL: cannot publish Mirror autostart" >&2; exit 1; }
BOOT_TOUCHED=1
chmod 755 "$STARTUP" || { rollback_start; echo "FAIL: cannot chmod startup.sh" >&2; exit 1; }
sync || { rollback_start; echo "FAIL: sync failed after Mirror autostart" >&2; exit 1; }
if ! mount_system_ro; then rollback_start; echo "FAIL: cannot remount /mnt/system read-only" >&2; exit 1; fi
SYSTEM_RW=0
cleanup_temps

echo "MIRROR_AUTOSTART=ENABLED runtime=/mnt/app/root/carplay-altscreen/bin/mirror source=window58"
echo "START=PASS integrated=AltScreen+Mirror reboot_required=YES"
exit 0
