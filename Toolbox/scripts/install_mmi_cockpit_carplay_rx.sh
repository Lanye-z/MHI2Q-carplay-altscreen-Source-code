#!/bin/sh
# CarPlay private111 Direct Display V1 INSTALL.
# Installs the type111 control/data plane, H264/decoded SHM bridge,
# displayable3 GLES sidecar, and Java80 HMI control plane.
# Window58 readback and RGI98 native renderer are not used by the sidecar.
set -u

BASE="$0"
RESOLVED=$(command -v -- "$BASE" 2>/dev/null)
[ -n "$RESOLVED" ] || RESOLVED="$BASE"
SCRIPTDIR=$(cd -P -- "$(dirname -- "$RESOLVED")" 2>/dev/null && pwd -P)
[ -n "$SCRIPTDIR" ] || { echo "FAIL: cannot resolve installer directory"; exit 126; }

TESTING=${ALTSCREEN_CHAIN_TESTING:-0}
DEVICE_ROOT=""
VOLUME=""
if [ "$TESTING" = 1 ]; then
    VOLUME=${ALTSCREEN_CHAIN_VOLUME:-}
    DEVICE_ROOT=${ALTSCREEN_CHAIN_ROOT:-}
    [ -n "$VOLUME" ] || { echo "FAIL: testing volume missing"; exit 1; }
    case "$DEVICE_ROOT" in /tmp/*|/var/tmp/*) ;; *) echo "FAIL: invalid ALTSCREEN_CHAIN_ROOT"; exit 2 ;; esac
else
    for candidate in /net/mmx/fs/sda0 /net/mmx/fs/sda1 /net/mmx/fs/sdb0 /net/mmx/fs/sdb1 /fs/sda0 /fs/sda1 /fs/sdb0 /fs/sdb1; do
        if [ -d "$candidate/Toolbox" ]; then VOLUME=$candidate; break; fi
    done
fi

[ -n "$VOLUME" ] || { echo "FAIL: no Toolbox SD card discovered"; exit 1; }
CONTROLLER="$VOLUME/Toolbox/scripts/altscreen_chain_test.sh"
JAR_SOURCE="$VOLUME/Toolbox/carplay_alt_screen/hmi/carplay_hook-basevideo3.jar"
JAR_TARGET="$DEVICE_ROOT/mnt/app/eso/hmi/lsd/jars/carplay_hook.jar"
JAR_TARGET_DIR=$(dirname -- "$JAR_TARGET")
BACKUP="$VOLUME/MMI-Cockpit-Carplay/backup/basevideo3-hmi-original"
BACKUP_TMP="$BACKUP.new.$$"
EXPECTED_SIZE=143072
EXPECTED_CKSUM=1515795662

[ -f "$CONTROLLER" ] || { echo "FAIL: chain controller missing: $CONTROLLER"; exit 127; }
[ -s "$JAR_SOURCE" ] || { echo "FAIL: Java80 HMI JAR missing: $JAR_SOURCE"; exit 1; }

file_size(){
    n=$(wc -c < "$1" 2>/dev/null) || { echo 0; return; }
    set -- $n
    echo "${1:-0}"
}
file_cksum(){
    if command -v cksum >/dev/null 2>&1; then
        cksum < "$1" 2>/dev/null | awk '{print $1}'
    else
        echo unavailable
    fi
}
jar_valid(){
    f=$1
    [ -s "$f" ] || return 1
    [ "$(file_size "$f")" = "$EXPECTED_SIZE" ] || return 1
    sum=$(file_cksum "$f")
    [ "$sum" = unavailable ] || [ "$sum" = "$EXPECTED_CKSUM" ] || return 1
}
same_bytes(){
    [ -f "$1" ] && [ -f "$2" ] || return 1
    [ "$(file_size "$1")" = "$(file_size "$2")" ] || return 1
    a=$(file_cksum "$1"); b=$(file_cksum "$2")
    if [ "$a" != unavailable ] && [ "$b" != unavailable ]; then
        [ "$a" = "$b" ]
    else
        cmp "$1" "$2" >/dev/null 2>&1
    fi
}
mount_app_rw(){ [ "$TESTING" = 1 ] || mount -uw /mnt/app; }
mount_app_ro(){ [ "$TESTING" = 1 ] || mount -ur /mnt/app; }

verify_backup(){
    [ -f "$BACKUP/COMPLETE" ] || return 1
    [ -f "$BACKUP/target" ] || return 1
    [ "$(cat "$BACKUP/target" 2>/dev/null)" = "/mnt/app/eso/hmi/lsd/jars/carplay_hook.jar" ] || return 1
    if [ -f "$BACKUP/present" ]; then
        [ -s "$BACKUP/carplay_hook.jar" ] || return 1
        if [ -f "$BACKUP/cksum" ] && command -v cksum >/dev/null 2>&1; then
            [ "$(cksum < "$BACKUP/carplay_hook.jar")" = "$(cat "$BACKUP/cksum")" ] || return 1
        fi
    elif [ -f "$BACKUP/absent" ]; then
        [ ! -e "$BACKUP/carplay_hook.jar" ] || return 1
    else
        return 1
    fi
}

backup_original_jar(){
    if [ -e "$BACKUP" ]; then
        verify_backup || { echo "FAIL: existing Java HMI backup is damaged"; return 1; }
        echo "HMI_BACKUP=PRESERVED path=$BACKUP"
        return 0
    fi
    rm -rf "$BACKUP_TMP" 2>/dev/null || true
    mkdir -p "$(dirname -- "$BACKUP")" "$BACKUP_TMP" || return 1
    echo "/mnt/app/eso/hmi/lsd/jars/carplay_hook.jar" > "$BACKUP_TMP/target" || return 1
    if [ -f "$JAR_TARGET" ]; then
        cp "$JAR_TARGET" "$BACKUP_TMP/carplay_hook.jar" || return 1
        touch "$BACKUP_TMP/present" || return 1
        if command -v cksum >/dev/null 2>&1; then cksum < "$BACKUP_TMP/carplay_hook.jar" > "$BACKUP_TMP/cksum" || return 1; fi
        echo "HMI_BACKUP=SNAPSHOT original=present"
    else
        touch "$BACKUP_TMP/absent" || return 1
        echo "HMI_BACKUP=SNAPSHOT original=absent"
    fi
    touch "$BACKUP_TMP/COMPLETE" || return 1
    mv "$BACKUP_TMP" "$BACKUP" || return 1
    verify_backup
}

restore_original_jar(){
    verify_backup || return 1
    mkdir -p "$JAR_TARGET_DIR" || return 1
    rm -f "$JAR_TARGET.basevideo3.tmp" 2>/dev/null || true
    if [ -f "$BACKUP/present" ]; then
        cp "$BACKUP/carplay_hook.jar" "$JAR_TARGET.basevideo3.tmp" || return 1
        chmod 644 "$JAR_TARGET.basevideo3.tmp" || return 1
        mv "$JAR_TARGET.basevideo3.tmp" "$JAR_TARGET" || return 1
        same_bytes "$BACKUP/carplay_hook.jar" "$JAR_TARGET" || return 1
    else
        rm -f "$JAR_TARGET" "$JAR_TARGET.basevideo3.tmp" || return 1
    fi
}

jar_valid "$JAR_SOURCE" || {
    echo "FAIL: Java80 HMI JAR identity mismatch"
    echo "expected_size=$EXPECTED_SIZE expected_cksum=$EXPECTED_CKSUM"
    echo "actual_size=$(file_size "$JAR_SOURCE") actual_cksum=$(file_cksum "$JAR_SOURCE")"
    exit 1
}

echo "PACKAGE_MODE=CARPLAY_PRIVATE111_DIRECT_DISPLAY_V1"
echo "NATIVE_SOURCE=private111_ScreenStreamProcessData h264_shm=/carplay111_h264"
echo "DECODER_BACKEND=stock_omx_buffer_tap_v1 decoded_shm=/carplay111_decoded"
echo "PIXEL_BRIDGE=NV12_to_existing_MMI_GLES"
echo "PIXEL_TARGET=displayable3"
echo "HMI_CONTEXT=ctx80"
echo "WINDOW58_READBACK=DISABLED"
echo "DIRECT_DISPLAY_SIDECAR=INCLUDED"
echo "RGI98_NATIVE_RENDERER=NOT_INCLUDED"

backup_original_jar || exit 1
/bin/sh "$CONTROLLER" install "${1:-}"
CHAIN_RC=$?
[ "$CHAIN_RC" -eq 0 ] || exit "$CHAIN_RC"
MIRROR_RUNTIME="$DEVICE_ROOT/mnt/app/root/carplay-altscreen/bin/mirror"
[ -x "$MIRROR_RUNTIME/carplay-alt111-mirror-display" ] || { echo "FAIL: integrated direct-display binary was not staged"; exit 1; }
[ -x "$MIRROR_RUNTIME/start_vehicle.sh" ] || { echo "FAIL: integrated direct-display launcher was not staged"; exit 1; }

APP_RW=0
rollback(){
    echo "WARN: Java80 deployment failed; restoring pre-install state"
    if [ "$APP_RW" != 1 ]; then
        if mount_app_rw >/dev/null 2>&1; then APP_RW=1; fi
    fi
    if [ "$APP_RW" = 1 ]; then
        restore_original_jar >/dev/null 2>&1 || echo "WARN: Java HMI rollback failed"
        sync >/dev/null 2>&1 || true
        mount_app_ro >/dev/null 2>&1 || true
        APP_RW=0
    fi
    /bin/sh "$CONTROLLER" restore >/dev/null 2>&1 || echo "WARN: native rollback failed"
}
fail(){ msg=$1; rollback; echo "FAIL: $msg" >&2; exit 1; }

mount_app_rw || fail "cannot mount /mnt/app writable"
APP_RW=1
mkdir -p "$JAR_TARGET_DIR" || fail "cannot create HMI JAR directory"
TMP="$JAR_TARGET.basevideo3.tmp"
rm -f "$TMP" 2>/dev/null || true
cp "$JAR_SOURCE" "$TMP" || fail "cannot stage Java80 HMI JAR"
chmod 644 "$TMP" || fail "cannot chmod Java80 HMI JAR"
jar_valid "$TMP" || fail "staged Java80 HMI JAR identity check failed"
mv "$TMP" "$JAR_TARGET" || fail "cannot publish Java80 HMI JAR"
jar_valid "$JAR_TARGET" || fail "installed Java80 HMI JAR identity check failed"
sync || fail "sync failed after Java80 HMI install"
mount_app_ro || fail "cannot remount /mnt/app read-only"
APP_RW=0

echo "HMI_CONTROL_PLANE=INSTALLED target=/mnt/app/eso/hmi/lsd/jars/carplay_hook.jar size=$EXPECTED_SIZE cksum=$EXPECTED_CKSUM"
echo "HMI_CONTRACT=JAVA80 ctx80=98,101,102,3 basevideo=3"
echo "INSTALL=PASS integrated=AltScreen+H264Tap+DecoderTap+Displayable3+Java80 reboot_required=YES"
exit 0
