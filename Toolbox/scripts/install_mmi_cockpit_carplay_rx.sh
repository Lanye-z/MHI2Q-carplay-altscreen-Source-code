#!/bin/sh
# MMI-Cockpit-Carplay GEM INSTALL action.
#
# INSTALL is one operator transaction: the canonical AltScreen controller installs
# the CarPlay type111 overlay, then this launcher installs the matching Mirror
# sidecar runtime. START/reboot later enables both. Mirror replacement keeps one
# owned previous runtime until the whole /mnt/app transaction is safely read-only.
BASE="$0"
RESOLVED=$(command -v -- "$BASE" 2>/dev/null)
[ -n "$RESOLVED" ] || RESOLVED="$BASE"
SCRIPTDIR=$(cd -P -- "$(dirname -- "$RESOLVED")" 2>/dev/null && pwd -P)
[ -n "$SCRIPTDIR" ] || { echo "FAIL: cannot resolve installed installer directory"; exit 126; }

TESTING=${ALTSCREEN_CHAIN_TESTING:-0}
if [ "$TESTING" = 1 ]; then
    VOLUME=${ALTSCREEN_CHAIN_VOLUME:-}
    [ -n "$VOLUME" ] || { echo "FAIL: ALTSCREEN_CHAIN_TESTING=1 requires ALTSCREEN_CHAIN_VOLUME"; exit 1; }
    DEVICE_ROOT=${ALTSCREEN_CHAIN_ROOT:-}
    case "$DEVICE_ROOT" in /tmp/*|/var/tmp/*) ;; *) echo "FAIL: invalid ALTSCREEN_CHAIN_ROOT"; exit 2 ;; esac
else
    DEVICE_ROOT=""
    VOLUME=""
    for candidate in /net/mmx/fs/sda0 /net/mmx/fs/sda1 /net/mmx/fs/sdb0 /net/mmx/fs/sdb1 /fs/sda0 /fs/sda1 /fs/sdb0 /fs/sdb1; do
        if [ -d "$candidate/Toolbox" ]; then VOLUME=$candidate; break; fi
    done
fi

[ -n "$VOLUME" ] || { echo "FAIL: no Toolbox SD card discovered"; exit 1; }
[ -d "$VOLUME/Toolbox" ] || { echo "FAIL: selected SD lacks a root-level Toolbox: $VOLUME"; exit 1; }

CONTROLLER="$VOLUME/Toolbox/scripts/altscreen_chain_test.sh"
[ -f "$CONTROLLER" ] || { echo "FAIL: SD chain controller is missing: $CONTROLLER"; exit 127; }
MIRROR_SRC="$VOLUME/Toolbox/carplay_alt_screen/mirror_display/release"
PARENT="$DEVICE_ROOT/mnt/app/root"
RUNTIME_ROOT="$PARENT/carplay-altscreen"
RUNTIME_BIN="$RUNTIME_ROOT/bin"
RUNTIME_STATE="$RUNTIME_ROOT/state"
RUNTIME_TMP="$RUNTIME_ROOT/tmp"
RUNTIME_OWNER="$RUNTIME_ROOT/.mmi-cockpit-carplay-runtime-owner"
MIRROR_DST="$RUNTIME_BIN/mirror"
MIRROR_OWNER="$MIRROR_DST/.mmi-cockpit-carplay-mirror-owner"
MIRROR_PREV="$RUNTIME_TMP/mirror.previous"
PREV_OWNER="$MIRROR_PREV/.mmi-cockpit-carplay-mirror-owner"
LEGACY_MIRROR="$PARENT/carplay-alt111-mirror"
LEGACY_MIRROR_PREV="$PARENT/.carplay-alt111-mirror.previous"

# Old controller-only host fixtures intentionally do not carry the sidecar. A
# production package is fail-closed: integrated INSTALL requires every runtime
# member so the two-reboot flow can never arm a CarPlay-only half-install.
if [ ! -d "$MIRROR_SRC" ]; then
    if [ "$TESTING" = 1 ]; then
        echo "MIRROR_RUNTIME=TEST_FIXTURE_ABSENT integration_skipped=1"
        echo "source_volume=$VOLUME"
        echo "chain_controller=$CONTROLLER"
        exec /bin/sh "$CONTROLLER" install "${1:-}"
    fi
    echo "FAIL: integrated Mirror runtime missing: $MIRROR_SRC" >&2
    exit 1
fi
for f in carplay-alt111-mirror-display start_vehicle.sh stop_vehicle.sh BUILD_INFO.txt SHA256SUMS LICENSE.MMI-MIRROR; do
    [ -s "$MIRROR_SRC/$f" ] || { echo "FAIL: integrated Mirror runtime member missing/empty: $f" >&2; exit 1; }
done
if [ -e "$MIRROR_DST" ] && [ ! -f "$MIRROR_OWNER" ]; then
    echo "FAIL: refusing to replace unowned Mirror runtime directory: $MIRROR_DST" >&2
    exit 1
fi
if [ -e "$MIRROR_PREV" ] && [ ! -f "$PREV_OWNER" ]; then
    echo "FAIL: refusing to replace unowned previous Mirror runtime: $MIRROR_PREV" >&2
    exit 1
fi

echo "source_volume=$VOLUME"
echo "chain_controller=$CONTROLLER"
/bin/sh "$CONTROLLER" install "${1:-}"
CHAIN_RC=$?
[ "$CHAIN_RC" -eq 0 ] || exit "$CHAIN_RC"
[ -f "$RUNTIME_OWNER" ] && [ -d "$RUNTIME_BIN" ] && [ -d "$RUNTIME_STATE" ] && [ -d "$RUNTIME_TMP" ] || {
    echo "FAIL: unified runtime root was not published by the controller" >&2
    /bin/sh "$CONTROLLER" restore >/dev/null 2>&1 || true
    exit 1
}

mount_app_rw(){ [ "$TESTING" = 1 ] && return 0; mount -uw /mnt/app; }
mount_app_ro(){ [ "$TESTING" = 1 ] && return 0; mount -ur /mnt/app; }
rollback_chain(){
    echo "WARN: Mirror runtime deployment failed; restoring AltScreen installation"
    /bin/sh "$CONTROLLER" restore >/dev/null 2>&1 || echo "WARN: AltScreen rollback also failed; use RESTORE ORIGINAL before reboot"
}

STAGE="$RUNTIME_TMP/mirror.new.$$"
APP_RW=0
PUBLISHED=0
HAD_CURRENT=0
rollback_runtime(){
    # Keep /mnt/app writable long enough to restore the exact pre-INSTALL runtime.
    if [ "$APP_RW" != 1 ]; then
        if mount_app_rw >/dev/null 2>&1; then APP_RW=1; fi
    fi
    if [ "$APP_RW" = 1 ]; then
        [ "$PUBLISHED" != 1 ] || rm -rf "$MIRROR_DST" 2>/dev/null || true
        if [ "$HAD_CURRENT" = 1 ] && [ -d "$MIRROR_PREV" ]; then
            mv "$MIRROR_PREV" "$MIRROR_DST" 2>/dev/null || echo "WARN: could not restore previous Mirror runtime"
        fi
        rm -rf "$STAGE" 2>/dev/null || true
        sync >/dev/null 2>&1 || true
        mount_app_ro >/dev/null 2>&1 || true
        APP_RW=0
    fi
    rollback_chain
}
fail_runtime(){ msg=$1; rollback_runtime; echo "FAIL: $msg" >&2; exit 1; }

rm -rf "$STAGE" 2>/dev/null || true
if ! mount_app_rw; then rollback_chain; echo "FAIL: cannot mount /mnt/app writable for Mirror runtime" >&2; exit 1; fi
APP_RW=1

# Router rotation may already have copied the immediately previous Mirror into
# the unified tmp/ namespace. Keep it until START safely retires rollback state.
if [ -d "$MIRROR_PREV" ]; then
    [ -f "$PREV_OWNER" ] || fail_runtime "previous Mirror runtime lost its ownership marker"
    HAD_CURRENT=1
fi
# First migration from the pre-unification standalone Mirror: copy it into the
# unified rollback slot but leave the legacy tree in place until START. Thus a
# failure through the final remount still has an exact old runtime available.
if [ ! -d "$MIRROR_PREV" ] && [ -d "$LEGACY_MIRROR" ]; then
    [ -f "$LEGACY_MIRROR/.mmi-cockpit-carplay-mirror-owner" ] || fail_runtime "legacy Mirror runtime is unowned"
    cp -R "$LEGACY_MIRROR" "$MIRROR_PREV" || fail_runtime "cannot preserve legacy Mirror runtime"
    HAD_CURRENT=1
fi
mkdir -p "$STAGE" || fail_runtime "cannot create Mirror staging directory"
for f in carplay-alt111-mirror-display start_vehicle.sh stop_vehicle.sh BUILD_INFO.txt SHA256SUMS LICENSE.MMI-MIRROR; do
    cp "$MIRROR_SRC/$f" "$STAGE/$f" || fail_runtime "cannot copy Mirror runtime member: $f"
done
chmod 755 "$STAGE/carplay-alt111-mirror-display" "$STAGE/start_vehicle.sh" "$STAGE/stop_vehicle.sh" ||
    fail_runtime "cannot chmod Mirror runtime"
chmod 644 "$STAGE/BUILD_INFO.txt" "$STAGE/SHA256SUMS" "$STAGE/LICENSE.MMI-MIRROR" ||
    fail_runtime "cannot chmod Mirror metadata"
printf '%s\n' 'owner=MMI-Cockpit-Carplay' 'mode=CARPLAY111_MIRROR_SOURCE' > "$STAGE/.mmi-cockpit-carplay-mirror-owner" ||
    fail_runtime "cannot create Mirror ownership marker"

if [ -d "$MIRROR_DST" ]; then
    [ ! -d "$MIRROR_PREV" ] || rm -rf "$MIRROR_PREV" || fail_runtime "cannot refresh previous Mirror runtime"
    mv "$MIRROR_DST" "$MIRROR_PREV" || fail_runtime "cannot rotate previous Mirror runtime"
    HAD_CURRENT=1
fi
if ! mv "$STAGE" "$MIRROR_DST"; then fail_runtime "cannot publish Mirror runtime"; fi
PUBLISHED=1
sync || fail_runtime "sync failed after Mirror runtime install"
# Previous unified/legacy trees are intentionally retained through the first
# reboot. START is the next safe app-RW transaction and retires them only after
# the new runtime has survived INSTALL completely.
RUNTIME_PREV="$PARENT/.carplay-altscreen.previous"
if [ -d "$RUNTIME_PREV" ]; then
    [ -f "$RUNTIME_PREV/.mmi-cockpit-carplay-runtime-owner" ] || fail_runtime "previous unified runtime is unowned"
fi
if ! mount_app_ro; then fail_runtime "cannot remount /mnt/app read-only"; fi
APP_RW=0

# MIRROR_PREV intentionally remains only until START/RESTORE next obtains a safe
# writable /mnt/app. It is ignored at runtime and gives INSTALL exact rollback for
# every failure up through the final read-only remount.
echo "MIRROR_RUNTIME=INSTALLED path=/mnt/app/root/carplay-altscreen/bin/mirror autostart=armed_by_START unified_runtime=YES"
echo "INSTALL=PASS integrated=AltScreen+Mirror reboot_required=YES"
exit 0
