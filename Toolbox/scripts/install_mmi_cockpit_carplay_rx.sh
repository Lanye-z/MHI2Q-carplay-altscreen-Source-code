#!/bin/sh
# CarPlay private111 Direct Display V3 wheel-zoom INSTALL.
# The proven V2 display chain remains unchanged; V3 adds the true CarPlay
# changeMapZoomLevel control plane and refuses to install an unbuilt V2 HMI JAR.
# Installs the type111 control/data plane, H264/decoded SHM bridge,
# displayable3 GLES sidecar, and Java80 HMI control plane.
# Window58 readback and RGI98 native renderer are not used by the sidecar.
set -u

# QNX compatibility: treat already-existing directories as success instead of
# relying on target mkdir -p return semantics.
ensure_dirs() {
    for dir in "$@"; do
        [ -d "$dir" ] && continue
        mkdir -p "$dir" || return 1
    done
    return 0
}

# Persist the complete INSTALL transaction on the currently inserted SD card.
# This wrapper runs before any production mutation.  The child re-enters the
# same script with ALTS_OPLOG_CAPTURED=1 so every stdout/stderr line from this
# installer and its nested controllers is captured in one operation log.
if [ "${ALTS_OPLOG_CAPTURED:-0}" != 1 ]; then
    CAPTURE_ENTRY="$0"
    RESOLVED_CAPTURE=$(command -v -- "$CAPTURE_ENTRY" 2>/dev/null)
    [ -n "$RESOLVED_CAPTURE" ] && CAPTURE_ENTRY="$RESOLVED_CAPTURE"

    journal_volume=""
    if [ "${ALTSCREEN_CHAIN_TESTING:-0}" = 1 ]; then
        journal_volume=${ALTSCREEN_CHAIN_VOLUME:-}
        case "$journal_volume" in /tmp/*|/var/tmp/*) ;; *) echo "FAIL: invalid ALTSCREEN_CHAIN_VOLUME"; exit 2 ;; esac
    else
        for candidate in /net/mmx/fs/sda0 /net/mmx/fs/sda1 /net/mmx/fs/sdb0 /net/mmx/fs/sdb1 /fs/sda0 /fs/sda1 /fs/sdb0 /fs/sdb1; do
            if [ -d "$candidate/Toolbox" ]; then journal_volume=$candidate; break; fi
        done
    fi
    [ -n "$journal_volume" ] && [ -d "$journal_volume/Toolbox" ] || {
        echo "FAIL: no Toolbox SD card discovered; INSTALL not started and no production files changed"
        exit 1
    }

    journal_dir="$journal_volume/MMI-Cockpit-Carplay/logs/operations"
    ensure_dirs "$journal_dir" 2>/dev/null || {
        echo "FAIL: cannot create persistent INSTALL log directory on SD: $journal_dir"
        exit 1
    }
    journal_stamp=$(date +%Y%m%d_%H%M%S 2>/dev/null || echo unknown)
    journal_base="$journal_dir/install_${journal_stamp}"
    journal="$journal_base.log"
    journal_n=0
    while [ -e "$journal" ]; do
        journal_n=$((journal_n + 1))
        journal="${journal_base}_${journal_n}.log"
    done
    if ! (printf 'OP_BEGIN action=INSTALL script=%s storage=SD\n' "$CAPTURE_ENTRY" > "$journal") 2>/dev/null; then
        echo "FAIL: cannot create persistent INSTALL log on SD: $journal"
        exit 1
    fi
    printf 'DIAGNOSTICS_VOLUME=%s\n' "$journal_volume" >> "$journal"

    if [ "$#" -gt 0 ]; then
        ALTS_OPLOG_CAPTURED=1 /bin/sh "$CAPTURE_ENTRY" "$@" >> "$journal" 2>&1
    else
        ALTS_OPLOG_CAPTURED=1 /bin/sh "$CAPTURE_ENTRY" >> "$journal" 2>&1
    fi
    journal_rc=$?
    printf 'OP_END action=INSTALL rc=%s\n' "$journal_rc" >> "$journal"
    printf 'OPERATION_LOG=%s\n' "$journal" >> "$journal"
    sync >/dev/null 2>&1 || true
    cat "$journal"
    exit "$journal_rc"
fi

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

# All production mutations are owned by the persistent INSTALL transaction.
# The outer operation-log wrapper re-enters this script once; that child then
# hands control to the transaction wrapper.  The transaction calls back with
# ALTS_INSTALL_TXN_ACTIVE=1 for the actual APPLY step.
if [ "${ALTS_INSTALL_TXN_ACTIVE:-0}" != 1 ]; then
    INSTALL_TXN="$VOLUME/Toolbox/scripts/altscreen_install_transaction.sh"
    [ -f "$INSTALL_TXN" ] || {
        echo "FAIL: transactional INSTALL wrapper missing: $INSTALL_TXN"
        exit 127
    }
    if [ "$#" -gt 0 ]; then
        exec /bin/sh "$INSTALL_TXN" install "$@"
    else
        exec /bin/sh "$INSTALL_TXN" install
    fi
fi

CONTROLLER="$VOLUME/Toolbox/scripts/altscreen_chain_test.sh"
MIRROR_RELEASE="$VOLUME/Toolbox/carplay_alt_screen/mirror_display/release"
MIRROR_INFO="$MIRROR_RELEASE/BUILD_INFO.txt"
JAR_SOURCE="$VOLUME/Toolbox/carplay_alt_screen/hmi/carplay_hook-basevideo3.jar"
HMI_INFO="$VOLUME/Toolbox/carplay_alt_screen/hmi/BUILD_INFO.txt"
JAR_TARGET="$DEVICE_ROOT/mnt/app/eso/hmi/lsd/jars/carplay_hook.jar"
JAR_TARGET_DIR=$(dirname -- "$JAR_TARGET")
LIVE_JSON_SI="$DEVICE_ROOT/mnt/system/etc/eso/production/smartphone_integrator.json"
MANAGED_RUNTIME_OWNER="$DEVICE_ROOT/mnt/app/root/carplay-altscreen/.mmi-cockpit-carplay-runtime-owner"
BACKUP="$VOLUME/MMI-Cockpit-Carplay/backup/basevideo3-hmi-original"
BACKUP_TMP="$BACKUP.new.$$"
EXPECTED_SIZE=151037
EXPECTED_CKSUM=456399961

[ -f "$CONTROLLER" ] || { echo "FAIL: chain controller missing: $CONTROLLER"; exit 127; }
[ -s "$JAR_SOURCE" ] || { echo "FAIL: Java80 HMI JAR missing: $JAR_SOURCE"; exit 1; }
[ -s "$HMI_INFO" ] || { echo "FAIL: HMI BUILD_INFO missing: $HMI_INFO"; exit 1; }
grep -Fq 'oem_geometry_build_status=COMPILED_OBSERVER_READY' "$HMI_INFO" 2>/dev/null || {
    echo "FAIL: OEM observer source/JAR is not a compiled matched pair"
    grep -E '^(oem_geometry_build_status|jar_size|jar_cksum|jar_sha256)=' "$HMI_INFO" 2>/dev/null || true
    echo "ACTION=RUN_OEM_LAYOUT_OBSERVER_BUILD_BEFORE_INSTALL"
    exit 1
}
grep -Fq 'mode=PRIVATE111_DIRECT_DISPLAY_V3_WHEEL_ZOOM' "$HMI_INFO" 2>/dev/null &&
grep -Fq 'wheel_zoom_build_status=COMPILED_READY_FOR_VEHICLE_TEST' "$HMI_INFO" 2>/dev/null || {
    echo "FAIL: V3 wheel-zoom HMI artifact is not the compiled vehicle-test build"
    grep -E '^(mode|wheel_zoom_build_status|jar_size|jar_cksum|jar_sha256)=' "$HMI_INFO" 2>/dev/null || true
    echo "ACTION=RUN_WHEEL_ZOOM_V3_BUILD"
    exit 1
}
[ -s "$MIRROR_INFO" ] || { echo "FAIL: V2 Mirror BUILD_INFO missing: $MIRROR_INFO"; exit 1; }
grep -Fq 'release_binary_status=PRIVATE111_DIRECT_DISPLAY_V2' "$MIRROR_INFO" 2>/dev/null &&
grep -Fq 'vehicle_zip_status=READY_FOR_VEHICLE_TEST' "$MIRROR_INFO" 2>/dev/null || {
    echo "FAIL: this package is not an approved rebuilt V2 vehicle release"
    grep -E '^(release_binary_status|vehicle_zip_status)=' "$MIRROR_INFO" 2>/dev/null || true
    echo "ACTION=REBUILD_QNX_SIDECAR_AND_PROMOTE_BEFORE_INSTALL"
    exit 1
}

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
historical_managed_jar(){
    [ -f "$1" ] || return 1
    # V3 wheel-enabled JARs carry this project-only ZIP member name in the
    # archive directory, so previous CI rebuilds remain detectable even though
    # their whole-file cksum changes with JAR timestamps.
    grep -Fq 'com/luka/carplay/cluster/WheelZoomBridge.class' "$1" 2>/dev/null && return 0
    size=$(file_size "$1")
    sum=$(file_cksum "$1")
    [ "$sum" != unavailable ] || return 1
    # Older pre-WheelZoomBridge project JAR identities kept for compatibility.
    case "$size:$sum" in
      149510:180684234|149979:2362627699|150026:3028143795) return 0 ;;
      *) return 1 ;;
    esac
}
live_managed_install_detected(){
    managed=0
    owner_present=NO
    si_hook_present=NO
    current_package_jar=NO
    known_managed=NO
    known_managed_match=NONE
    target_jar_present=NO
    target_jar_size=ABSENT
    target_jar_cksum=ABSENT

    if [ -f "$MANAGED_RUNTIME_OWNER" ]; then
        owner_present=YES
        managed=1
    fi
    if grep -Fq 'libcarplay_altscreen.so' "$LIVE_JSON_SI" 2>/dev/null; then
        si_hook_present=YES
        managed=1
    fi
    if [ -f "$JAR_TARGET" ]; then
        target_jar_present=YES
        target_jar_size=$(file_size "$JAR_TARGET")
        target_jar_cksum=$(file_cksum "$JAR_TARGET")
        if same_bytes "$JAR_SOURCE" "$JAR_TARGET"; then
            current_package_jar=YES
            managed=1
        fi
        if [ "$current_package_jar" != YES ] && historical_managed_jar "$JAR_TARGET"; then
            known_managed=YES
            known_managed_match="$target_jar_size:$target_jar_cksum"
            managed=1
        fi
    fi

    echo "LIVE_MANAGED_CHECK_BEGIN"
    echo "RUNTIME_OWNER_PRESENT=$owner_present path=/mnt/app/root/carplay-altscreen/.mmi-cockpit-carplay-runtime-owner"
    echo "SMARTPHONE_INTEGRATOR_HOOK=$si_hook_present path=/mnt/system/etc/eso/production/smartphone_integrator.json token=libcarplay_altscreen.so"
    echo "JAR_TARGET_PRESENT=$target_jar_present path=/mnt/app/eso/hmi/lsd/jars/carplay_hook.jar size=$target_jar_size cksum=$target_jar_cksum"
    echo "CURRENT_PACKAGE_JAR_PRESENT=$current_package_jar expected_size=$EXPECTED_SIZE expected_cksum=$EXPECTED_CKSUM"
    echo "KNOWN_MANAGED_JAR_PRESENT=$known_managed matched_identity=$known_managed_match marker=WheelZoomBridge_or_legacy_identity"
    if [ "$managed" = 1 ]; then
        reasons=""
        [ "$owner_present" != YES ] || reasons="${reasons}RUNTIME_OWNER_PRESENT,"
        [ "$si_hook_present" != YES ] || reasons="${reasons}SMARTPHONE_INTEGRATOR_PRELOAD_PRESENT,"
        [ "$current_package_jar" != YES ] || reasons="${reasons}CURRENT_PACKAGE_JAR_PRESENT,"
        [ "$known_managed" != YES ] || reasons="${reasons}KNOWN_MANAGED_JAR_PRESENT,"
        reasons=${reasons%,}
        echo "LIVE_MANAGED_SUMMARY=MANAGED reasons=$reasons"
    else
        echo "LIVE_MANAGED_SUMMARY=CLEAN reasons=NONE"
    fi
    echo "LIVE_MANAGED_CHECK_END"
    [ "$managed" = 1 ]
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
    if live_managed_install_detected; then
        echo "FAIL: trusted original Java HMI backup is absent but the live system is already managed by this project; refusing to snapshot a V2/V3 JAR as OEM"
        echo "ACTION=REUSE_ORIGINAL_SD_BACKUP_OR_RESTORE_STOCK_FIRST"
        echo "ACTION_DETAIL=See LIVE_MANAGED_CHECK_* above to identify the exact residual condition before changing or deleting anything"
        return 1
    fi
    rm -rf "$BACKUP_TMP" 2>/dev/null || true
    ensure_dirs "$(dirname -- "$BACKUP")" "$BACKUP_TMP" || return 1
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
    ensure_dirs "$JAR_TARGET_DIR" || return 1
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

echo "PACKAGE_MODE=CARPLAY_PRIVATE111_DIRECT_DISPLAY_V2"
echo "NATIVE_SOURCE=private111_ScreenStreamProcessData h264_shm=/carplay111_h264"
echo "DECODER_BACKEND=stock_omx_screen_linearized_shm decoded_shm=/carplay111_decoded"
echo "PIXEL_BRIDGE=Screen_linearized_NV12_to_existing_MMI_GLES"
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
ensure_dirs "$JAR_TARGET_DIR" || fail "cannot create HMI JAR directory"
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
