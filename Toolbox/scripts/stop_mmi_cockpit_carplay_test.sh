#!/bin/sh
# private111 direct-display V1 RESTORE ORIGINAL.
# Releases Java80 demand, restores the exact pre-install carplay_hook.jar, then
# restores the native AltScreen/preload transaction. No MMI Mirror is involved.
set -u

ensure_dirs() {
    for dir in "$@"; do
        [ -d "$dir" ] && continue
        mkdir -p "$dir" || return 1
    done
    return 0
}

BASE="$0"
RESOLVED=$(command -v -- "$BASE" 2>/dev/null)
[ -n "$RESOLVED" ] || RESOLVED="$BASE"
SCRIPTDIR=$(cd -P -- "$(dirname -- "$RESOLVED")" 2>/dev/null && pwd -P)
[ -n "$SCRIPTDIR" ] || { echo "FAIL: cannot resolve RESTORE directory"; exit 126; }

TESTING=${ALTSCREEN_CHAIN_TESTING:-0}
DEVICE_ROOT=""
VOLUME=""
if [ "$TESTING" = 1 ]; then
    DEVICE_ROOT=${ALTSCREEN_CHAIN_ROOT:-}
    VOLUME=${ALTSCREEN_CHAIN_VOLUME:-}
else
    for candidate in /net/mmx/fs/sda0 /net/mmx/fs/sda1 /net/mmx/fs/sdb0 /net/mmx/fs/sdb1 /fs/sda0 /fs/sda1 /fs/sdb0 /fs/sdb1; do
        if [ -d "$candidate/Toolbox" ]; then VOLUME=$candidate; break; fi
    done
fi

APP_BIN="$DEVICE_ROOT/mnt/app/root/carplay-altscreen/bin"
APP_SELF="$APP_BIN/stop_mmi_cockpit_carplay_test.sh"
if [ "$SCRIPTDIR" != "$APP_BIN" ] && [ -f "$APP_SELF" ] && [ -f "$APP_BIN/altscreen_chain_test.sh" ]; then
    echo "APP_RUNTIME_FORWARD action=RESTORE from=$SCRIPTDIR to=/mnt/app/root/carplay-altscreen/bin"
    if [ "$#" -gt 0 ]; then
        exec /bin/sh "$APP_SELF" "$@"
    else
        exec /bin/sh "$APP_SELF"
    fi
fi

CONTROLLER="$SCRIPTDIR/altscreen_chain_test.sh"
[ -f "$CONTROLLER" ] || { echo "FAIL: installed chain controller missing"; exit 127; }
[ -n "$VOLUME" ] || { echo "FAIL: SD card required to restore original Java HMI JAR"; exit 1; }

RUNTIME="$DEVICE_ROOT/mnt/app/root/carplay-altscreen"
TXN_DIR="$DEVICE_ROOT/tmp/MMI-Cockpit-Carplay/txn/restore.$$"
ENABLED="$RUNTIME/state/basevideo3.enabled"
JAR="$DEVICE_ROOT/mnt/app/eso/hmi/lsd/jars/carplay_hook.jar"
JAR_DIR=$(dirname -- "$JAR")
BACKUP="$VOLUME/MMI-Cockpit-Carplay/backup/basevideo3-hmi-original"
ACTIVE="$DEVICE_ROOT/tmp/mmi-mirror-active"
READY="$DEVICE_ROOT/tmp/mmi-mirror-basevideo.ready"
STARTED="$DEVICE_ROOT/tmp/mmi-mirror-controller.started"
MIRROR_STOP="$RUNTIME/bin/mirror/stop_vehicle.sh"

mount_app_rw(){ [ "$TESTING" = 1 ] || mount -uw /mnt/app; }
mount_app_ro(){ [ "$TESTING" = 1 ] || mount -ur /mnt/app; }
mount_system_rw(){ [ "$TESTING" = 1 ] || mount -uw /mnt/system; }
mount_system_ro(){ [ "$TESTING" = 1 ] || mount -ur /mnt/system; }
system_space_snapshot(){
    label=$1; target="$DEVICE_ROOT/mnt/system"
    echo "SYSTEM_SPACE_BEGIN label=$label path=$target"
    df -k "$target" 2>/dev/null || df "$target" 2>/dev/null || true
    echo "SYSTEM_SPACE_END label=$label"
}
publish_system_file(){
    src=$1; dst=$2; mode=$3; dir=${dst%/*}; base=${dst##*/}; tmp="$dir/.$base.altscreen.new.$$"
    if cmp -s "$src" "$dst" 2>/dev/null; then chmod "$mode" "$dst" 2>/dev/null || return 1; echo "SYSTEM_PUBLISH=SKIP_IDENTICAL target=$dst"; return 0; fi
    rm -f "$tmp" 2>/dev/null || true
    if ! cp "$src" "$tmp"; then rc=$?; rm -f "$tmp" 2>/dev/null || true; echo "SYSTEM_WRITE_FAILED stage=copy target=$dst"; system_space_snapshot restore_publish_failed; return "$rc"; fi
    chmod "$mode" "$tmp" || { rc=$?; rm -f "$tmp" 2>/dev/null || true; return "$rc"; }
    cmp -s "$src" "$tmp" || { rm -f "$tmp" 2>/dev/null || true; return 1; }
    mv "$tmp" "$dst" || { rc=$?; rm -f "$tmp" 2>/dev/null || true; return "$rc"; }
}
cleanup_txn(){ [ ! -e "$TXN_DIR" ] || rm -rf "$TXN_DIR" 2>/dev/null || true; }
trap cleanup_txn 0 1 2 15

verify_backup(){
    [ -f "$BACKUP/COMPLETE" ] || return 1
    if [ -f "$BACKUP/present" ]; then
        [ -s "$BACKUP/carplay_hook.jar" ] || return 1
        if [ -f "$BACKUP/cksum" ] && command -v cksum >/dev/null 2>&1; then
            [ "$(cksum < "$BACKUP/carplay_hook.jar")" = "$(cat "$BACKUP/cksum")" ] || return 1
        fi
    elif [ -f "$BACKUP/absent" ]; then
        :
    else
        return 1
    fi
}

strip_blocks(){
    awk '
      {
        key=$0
        sub(/\r$/, "", key)
        trimmed=key
        gsub(/^[ \t]+/, "", trimmed)
        gsub(/[ \t]+$/, "", trimmed)

        if (trimmed == "# BEGIN ALT111 MIRROR AUTOSTART") {
            if (block != "") bad=8
            block="old"
            next
        }
        if (trimmed == "# END ALT111 MIRROR AUTOSTART") {
            if (block != "old") bad=8
            block=""
            next
        }
        if (trimmed == "# BEGIN ALT111 BASEVIDEO3 AUTOSTART") {
            if (block != "") bad=8
            block="new"
            next
        }
        if (trimmed == "# END ALT111 BASEVIDEO3 AUTOSTART") {
            if (block != "new") bad=8
            block=""
            next
        }
        if (block == "") print
      }
      END {
        if (bad) exit bad
        if (block != "") exit 9
      }
    ' "$1"
}

# Stop the pixel sidecar first. It has no context writer in this branch.
[ ! -x "$MIRROR_STOP" ] || /bin/sh "$MIRROR_STOP" >/dev/null 2>&1 || true
# Release demand while the current Java controller is still resident. It will
# observe active/ready withdrawal and return terminal1 to its stock context.
rm -f "$ACTIVE" "$READY" 2>/dev/null || true
sleep 1

if [ -f "$ENABLED" ]; then
    mount_app_rw || { echo "FAIL: cannot mount /mnt/app to disable BaseVideo3"; exit 1; }
    rm -f "$ENABLED" || { mount_app_ro >/dev/null 2>&1 || true; echo "FAIL: cannot remove BaseVideo3 enable marker"; exit 1; }
    sync >/dev/null 2>&1 || true
    mount_app_ro || { echo "FAIL: cannot remount /mnt/app read-only"; exit 1; }
fi

STARTUP=""
for candidate in "$DEVICE_ROOT/mnt/system/etc/boot/startup.sh" "$DEVICE_ROOT/etc/boot/startup.sh"; do
    if [ -f "$candidate" ]; then STARTUP=$candidate; break; fi
done
if [ -n "$STARTUP" ]; then
    ensure_dirs "$TXN_DIR" || { echo "FAIL: cannot create volatile RESTORE transaction directory"; exit 1; }
    CLEAN="$TXN_DIR/startup.clean"
    system_space_snapshot restore_begin
    strip_blocks "$STARTUP" > "$CLEAN" || { echo "FAIL: invalid BaseVideo3/Mirror autostart block"; exit 1; }
    sh -n "$CLEAN" || { echo "FAIL: startup.sh invalid after BaseVideo3 block removal"; exit 1; }
    if ! cmp -s "$CLEAN" "$STARTUP" 2>/dev/null; then
        mount_system_rw || { echo "FAIL: cannot mount /mnt/system writable"; exit 1; }
        rm -f "$STARTUP.basevideo3.clean."* "$STARTUP.basevideo3.block."* "$STARTUP.basevideo3.new."*               "$STARTUP.basevideo3.original."* "$STARTUP.basevideo3.restore."*               "${STARTUP%/*}/.${STARTUP##*/}.altscreen.new."* 2>/dev/null || true
        publish_system_file "$CLEAN" "$STARTUP" 755 || { mount_system_ro >/dev/null 2>&1 || true; echo "FAIL: SYSTEM_WRITE_FAILED publishing cleaned startup.sh"; exit 1; }
        sync >/dev/null 2>&1 || true
        mount_system_ro || { echo "FAIL: cannot remount /mnt/system read-only"; exit 1; }
    else
        echo "RESTORE_AUTOSTART=ALREADY_CLEAN"
    fi
    system_space_snapshot restore_after_publish
fi

verify_backup || { echo "FAIL: original Java HMI backup unavailable or damaged: $BACKUP"; exit 1; }
mount_app_rw || { echo "FAIL: cannot mount /mnt/app to restore Java HMI"; exit 1; }
ensure_dirs "$JAR_DIR" || { mount_app_ro >/dev/null 2>&1 || true; echo "FAIL: cannot create JAR directory"; exit 1; }
TMP="$JAR.basevideo3.restore.tmp"
rm -f "$TMP" 2>/dev/null || true
if [ -f "$BACKUP/present" ]; then
    cp "$BACKUP/carplay_hook.jar" "$TMP" && chmod 644 "$TMP" && mv "$TMP" "$JAR" || {
        mount_app_ro >/dev/null 2>&1 || true
        echo "FAIL: cannot restore original carplay_hook.jar"; exit 1; }
    if command -v cksum >/dev/null 2>&1 && [ -f "$BACKUP/cksum" ]; then
        [ "$(cksum < "$JAR")" = "$(cat "$BACKUP/cksum")" ] || {
            mount_app_ro >/dev/null 2>&1 || true
            echo "FAIL: restored carplay_hook.jar checksum mismatch"; exit 1; }
    fi
    echo "HMI_CONTROL_PLANE=RESTORED original=present"
else
    rm -f "$JAR" "$TMP" || {
        mount_app_ro >/dev/null 2>&1 || true
        echo "FAIL: cannot remove standalone carplay_hook.jar"; exit 1; }
    echo "HMI_CONTROL_PLANE=RESTORED original=absent"
fi
sync >/dev/null 2>&1 || true
mount_app_ro || { echo "FAIL: cannot remount /mnt/app read-only"; exit 1; }

rm -f "$STARTED" 2>/dev/null || true
/bin/sh "$CONTROLLER" restore
RC=$?
[ "$RC" -eq 0 ] || exit "$RC"

echo "BASEVIDEO3_BOOT_DEMAND=DISABLED"
echo "DIRECT_DISPLAY_SIDECAR=STOPPED native_dmdt=DISABLED"
echo "RESTORE=PASS integrated=AltScreen+H264Tap+DecoderTap+Displayable3+Java80 reboot_required=YES"
exit 0
