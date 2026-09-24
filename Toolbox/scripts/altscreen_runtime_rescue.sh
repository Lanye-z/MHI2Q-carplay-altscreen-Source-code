#!/bin/sh
# Runtime residue rescue helper for MMI-Cockpit-Carplay.
# Purpose: safely move a recognized legacy/unowned runtime out of the V3.4
# install path without deleting it.  The move is reversible and uses one fixed
# quarantine slot on the same /mnt/app filesystem.
set -u

ACTION=${1:-check}
TESTING=${ALTSCREEN_RESCUE_TESTING:-0}
DEVICE_ROOT=""
VOLUME=""

ensure_dirs(){ for d in "$@"; do [ -d "$d" ] || mkdir -p "$d" || return 1; done; }

if [ "$TESTING" = 1 ]; then
    DEVICE_ROOT=${ALTSCREEN_RESCUE_ROOT:-}
    VOLUME=${ALTSCREEN_RESCUE_VOLUME:-}
    case "$DEVICE_ROOT" in /tmp/*|/var/tmp/*) ;; *) echo "RESCUE=REFUSED reason=INVALID_TEST_ROOT"; exit 2;; esac
    case "$VOLUME" in /tmp/*|/var/tmp/*) ;; *) echo "RESCUE=REFUSED reason=INVALID_TEST_VOLUME"; exit 2;; esac
else
    for d in /net/mmx/fs/sda0 /net/mmx/fs/sda1 /net/mmx/fs/sdb0 /net/mmx/fs/sdb1 /fs/sda0 /fs/sda1 /fs/sdb0 /fs/sdb1; do
        [ -d "$d/Toolbox" ] && { VOLUME=$d; break; }
    done
fi

[ -n "$VOLUME" ] && [ -d "$VOLUME/Toolbox" ] || {
    echo "RESCUE=REFUSED reason=SD_WITH_TOOLBOX_NOT_FOUND production_changed=NO"
    exit 1
}

p(){ printf '%s%s\n' "$DEVICE_ROOT" "$1"; }

ROOT="$(p /mnt/app/root/carplay-altscreen)"
QUARANTINE="$(p /mnt/app/root/.carplay-altscreen.rescue-v1)"
OWNER=".mmi-cockpit-carplay-runtime-owner"
SD_ROOT="$VOLUME/MMI-Cockpit-Carplay"
LOG_DIR="$SD_ROOT/logs"
LOG="$LOG_DIR/runtime-residue-rescue.log"
LOG_PREV="$LOG_DIR/runtime-residue-rescue.previous.log"
LOWER_ORIGINAL="$SD_ROOT/backup/original"
UPPER_ORIGINAL="$SD_ROOT/backup/ORIGINAL"
UNIVERSAL_BACKUP="$SD_ROOT/backup/universal-hook-original"

mount_app_rw(){ [ "$TESTING" = 1 ] || mount -uw /mnt/app; }
mount_app_ro(){ [ "$TESTING" = 1 ] || mount -ur /mnt/app; }

prepare_log(){
    if [ "$TESTING" != 1 ]; then
        helper="$VOLUME/Toolbox/scripts/altscreen_sd_writable.sh"
        [ -f "$helper" ] || {
            echo "RESCUE=REFUSED reason=SD_WRITABLE_HELPER_MISSING production_changed=NO"
            return 1
        }
        . "$helper"
        altscreen_sd_ensure_writable "$VOLUME" RUNTIME_RESCUE || {
            echo "RESCUE=REFUSED reason=SD_NOT_WRITABLE production_changed=NO"
            return 1
        }
    fi
    ensure_dirs "$LOG_DIR" || return 1
    rm -f "$LOG_PREV" 2>/dev/null || true
    [ ! -f "$LOG" ] || mv "$LOG" "$LOG_PREV" 2>/dev/null || return 1
    : > "$LOG" || return 1
}

prepare_log || exit 1
log(){ echo "$*"; echo "$*" >> "$LOG" 2>/dev/null || true; }

valid_owner(){
    dir=$1
    marker="$dir/$OWNER"
    [ -f "$marker" ] || return 1
    grep -Fxq 'owner=MMI-Cockpit-Carplay' "$marker" 2>/dev/null || return 1
    if grep -q '^runtime=' "$marker" 2>/dev/null; then
        grep -Fxq 'runtime=carplay-altscreen' "$marker" 2>/dev/null || return 1
    fi
    return 0
}

current_v34_runtime(){
    dir=$1
    valid_owner "$dir" || return 1
    marker="$dir/$OWNER"
    grep -Fxq 'runtime=carplay-altscreen' "$marker" 2>/dev/null || return 1
    [ -f "$dir/bin/mirror/BUILD_INFO.txt" ] || return 1
    grep -Fq 'release_binary_status=PRIVATE111_DIRECT_DISPLAY_V3_4' "$dir/bin/mirror/BUILD_INFO.txt" 2>/dev/null || return 1
    [ -f "$dir/state/diagnostics.enabled" ] || return 1
    return 0
}

trusted_backup(){
    original=""
    if [ -f "$LOWER_ORIGINAL/COMPLETE" ]; then
        original="$LOWER_ORIGINAL"
    elif [ -f "$UPPER_ORIGINAL/COMPLETE" ]; then
        original="$UPPER_ORIGINAL"
    else
        log "BACKUP_TRUST=FAIL reason=ORIGINAL_COMPLETE_MISSING"
        return 1
    fi
    [ -f "$UNIVERSAL_BACKUP/COMPLETE" ] || {
        log "BACKUP_TRUST=FAIL reason=UNIVERSAL_HOOK_COMPLETE_MISSING"
        return 1
    }
    log "BACKUP_TRUST=PASS original=$original universal_hook=$UNIVERSAL_BACKUP"
    return 0
}

top_level_safe(){
    dir=$1
    for item in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
        [ -e "$item" ] || continue
        name=${item##*/}
        case "$name" in
            bin|lib|state) ;;
            *)
                log "RUNTIME_STRUCTURE=UNKNOWN top_level=$name"
                return 1
                ;;
        esac
    done
    return 0
}

no_symlinks(){
    dir=$1
    hit=$(find "$dir" -type l -print 2>/dev/null | sed -n '1p')
    [ -z "$hit" ] || {
        log "RUNTIME_STRUCTURE=UNSAFE reason=SYMLINK path=$hit"
        return 1
    }
    return 0
}

fingerprint_score(){
    dir=$1
    score=0
    for rel in \
        bin/altscreen_chain_test.sh \
        bin/altscreen_chain_test_universal.sh \
        bin/install_mmi_cockpit_carplay_rx.sh \
        bin/stop_mmi_cockpit_carplay_test.sh \
        bin/mirror/start_vehicle.sh \
        bin/mirror/stop_vehicle.sh \
        bin/mirror/carplay-alt111-mirror-display \
        lib/libcarplay_altscreen.so \
        state/basevideo3.enabled \
        state/diagnostics.enabled
    do
        [ -e "$dir/$rel" ] && score=$((score + 1))
    done
    printf '%s\n' "$score"
}

recognized_unowned(){
    dir=$1
    [ -d "$dir" ] && [ ! -L "$dir" ] || {
        log "RUNTIME_RECOGNITION=FAIL reason=NOT_SAFE_DIRECTORY path=$dir"
        return 1
    }
    valid_owner "$dir" && {
        log "RUNTIME_RECOGNITION=FAIL reason=VALID_OWNER_PRESENT path=$dir"
        return 1
    }
    no_symlinks "$dir" || return 1
    top_level_safe "$dir" || return 1
    score=$(fingerprint_score "$dir")
    log "RUNTIME_FINGERPRINT_SCORE=$score required=2"
    [ "$score" -ge 2 ] || {
        log "RUNTIME_RECOGNITION=FAIL reason=INSUFFICIENT_PROJECT_FINGERPRINT"
        return 1
    }
    trusted_backup || return 1
    log "RUNTIME_RECOGNITION=PASS kind=LEGACY_UNOWNED_PROJECT_RUNTIME"
    return 0
}

check_state(){
    if [ ! -e "$ROOT" ] && [ ! -e "$QUARANTINE" ]; then
        log "RESCUE_STATE=ABSENT action=NONE safe_to_install=YES"
        return 0
    fi
    if [ ! -e "$ROOT" ] && [ -e "$QUARANTINE" ]; then
        if recognized_unowned "$QUARANTINE"; then
            log "RESCUE_STATE=QUARANTINED path=/mnt/app/root/.carplay-altscreen.rescue-v1 safe_to_install=YES"
            return 0
        fi
        log "RESCUE_STATE=QUARANTINE_UNKNOWN action=STOP"
        return 1
    fi
    if [ -e "$ROOT" ] && [ -e "$QUARANTINE" ]; then
        if current_v34_runtime "$ROOT" && recognized_unowned "$QUARANTINE"; then
            log "RESCUE_STATE=V3_4_WITH_QUARANTINE current_runtime=VERIFIED safe_to_delete=YES"
            return 0
        fi
        log "RESCUE_STATE=CONFLICT reason=ROOT_AND_QUARANTINE_BOTH_EXIST_BUT_NOT_VERIFIED action=STOP"
        return 1
    fi
    if valid_owner "$ROOT"; then
        log "RESCUE_STATE=OWNED_CURRENT action=DO_NOT_QUARANTINE"
        return 0
    fi
    if recognized_unowned "$ROOT"; then
        log "RESCUE_STATE=LEGACY_UNOWNED_RECOGNIZED safe_to_quarantine=YES"
        return 0
    fi
    log "RESCUE_STATE=UNKNOWN_UNOWNED safe_to_quarantine=NO action=STOP"
    return 1
}

do_quarantine(){
    [ ! -e "$QUARANTINE" ] || {
        log "QUARANTINE=REFUSED reason=FIXED_QUARANTINE_SLOT_EXISTS production_changed=NO"
        return 1
    }
    if [ ! -e "$ROOT" ]; then
        log "QUARANTINE=NOT_NEEDED reason=RUNTIME_ABSENT production_changed=NO safe_to_install=YES"
        return 0
    fi
    valid_owner "$ROOT" && {
        log "QUARANTINE=REFUSED reason=RUNTIME_HAS_VALID_OWNER production_changed=NO"
        return 1
    }
    recognized_unowned "$ROOT" || {
        log "QUARANTINE=REFUSED reason=RUNTIME_NOT_POSITIVELY_RECOGNIZED production_changed=NO"
        return 1
    }

    mount_app_rw || {
        log "QUARANTINE=REFUSED reason=MOUNT_APP_RW_FAILED production_changed=NO"
        return 1
    }

    if mv "$ROOT" "$QUARANTINE"; then
        sync >/dev/null 2>&1 || true
    else
        mount_app_ro >/dev/null 2>&1 || true
        log "QUARANTINE=FAIL reason=ATOMIC_MOVE_FAILED production_changed=NO_OR_UNKNOWN"
        return 1
    fi

    if ! mount_app_ro; then
        log "QUARANTINE=FAIL reason=REMOUNT_APP_RO_FAILED production_changed=YES runtime_quarantined=YES"
        return 1
    fi

    [ ! -e "$ROOT" ] && [ -d "$QUARANTINE" ] || {
        log "QUARANTINE=FAIL reason=POST_MOVE_VERIFY_FAILED production_changed=YES"
        return 1
    }

    log "QUARANTINE=PASS from=/mnt/app/root/carplay-altscreen to=/mnt/app/root/.carplay-altscreen.rescue-v1 deletion=NONE reversible=YES"
    log "NEXT_ACTION=RUN_V3_4_INSTALL"
    return 0
}

do_delete(){
    [ -d "$QUARANTINE" ] && [ ! -L "$QUARANTINE" ] || {
        log "DELETE_QUARANTINE=REFUSED reason=QUARANTINE_ABSENT_OR_UNSAFE production_changed=NO"
        return 1
    }

    current_v34_runtime "$ROOT" || {
        log "DELETE_QUARANTINE=REFUSED reason=CURRENT_V3_4_RUNTIME_NOT_VERIFIED production_changed=NO"
        log "ACTION=REBOOT_AND_VERIFY_V3_4_FIRST"
        return 1
    }

    recognized_unowned "$QUARANTINE" || {
        log "DELETE_QUARANTINE=REFUSED reason=QUARANTINE_NOT_RECOGNIZED production_changed=NO"
        return 1
    }

    log "DELETE_PREFLIGHT=PASS current_runtime=V3_4_OWNED quarantine=LEGACY_UNOWNED_RECOGNIZED backup=TRUSTED"
    log "DELETE_SCOPE=/mnt/app/root/.carplay-altscreen.rescue-v1 only"
    log "DELETE_BACKUPS=NO"
    log "DELETE_CURRENT_RUNTIME=NO"

    mount_app_rw || {
        log "DELETE_QUARANTINE=REFUSED reason=MOUNT_APP_RW_FAILED production_changed=NO"
        return 1
    }

    if rm -rf "$QUARANTINE"; then
        sync >/dev/null 2>&1 || true
    else
        mount_app_ro >/dev/null 2>&1 || true
        log "DELETE_QUARANTINE=FAIL reason=REMOVE_FAILED production_changed=UNKNOWN"
        return 1
    fi

    if ! mount_app_ro; then
        log "DELETE_QUARANTINE=FAIL reason=REMOUNT_APP_RO_FAILED production_changed=YES quarantine_removed=$([ ! -e "$QUARANTINE" ] && echo YES || echo NO)"
        return 1
    fi

    [ ! -e "$QUARANTINE" ] || {
        log "DELETE_QUARANTINE=FAIL reason=POST_DELETE_VERIFY_FAILED production_changed=YES"
        return 1
    }

    current_v34_runtime "$ROOT" || {
        log "DELETE_QUARANTINE=FAIL reason=CURRENT_V3_4_RUNTIME_CHANGED_AFTER_DELETE production_changed=YES"
        return 1
    }

    log "DELETE_QUARANTINE=PASS path=/mnt/app/root/.carplay-altscreen.rescue-v1 irreversible=YES"
    log "CURRENT_V3_4_RUNTIME=PRESERVED"
    log "OEM_BACKUPS=PRESERVED"
    return 0
}

do_restore(){
    [ -d "$QUARANTINE" ] && [ ! -L "$QUARANTINE" ] || {
        log "RESTORE_QUARANTINE=REFUSED reason=QUARANTINE_ABSENT_OR_UNSAFE production_changed=NO"
        return 1
    }
    [ ! -e "$ROOT" ] || {
        log "RESTORE_QUARANTINE=REFUSED reason=RUNTIME_PATH_ALREADY_EXISTS production_changed=NO action=DO_NOT_OVERWRITE"
        return 1
    }
    recognized_unowned "$QUARANTINE" || {
        log "RESTORE_QUARANTINE=REFUSED reason=QUARANTINE_NOT_RECOGNIZED production_changed=NO"
        return 1
    }

    mount_app_rw || {
        log "RESTORE_QUARANTINE=REFUSED reason=MOUNT_APP_RW_FAILED production_changed=NO"
        return 1
    }
    if mv "$QUARANTINE" "$ROOT"; then
        sync >/dev/null 2>&1 || true
    else
        mount_app_ro >/dev/null 2>&1 || true
        log "RESTORE_QUARANTINE=FAIL reason=ATOMIC_MOVE_FAILED"
        return 1
    fi
    if ! mount_app_ro; then
        log "RESTORE_QUARANTINE=FAIL reason=REMOUNT_APP_RO_FAILED production_changed=YES runtime_restored=YES"
        return 1
    fi
    [ -d "$ROOT" ] && [ ! -e "$QUARANTINE" ] || {
        log "RESTORE_QUARANTINE=FAIL reason=POST_MOVE_VERIFY_FAILED production_changed=YES"
        return 1
    }
    log "RESTORE_QUARANTINE=PASS path=/mnt/app/root/carplay-altscreen deletion=NONE"
    return 0
}

log "===== runtime residue rescue v1 action=$ACTION ====="
case "$ACTION" in
    check) check_state ;;
    quarantine) do_quarantine ;;
    restore) do_restore ;;
    delete) do_delete ;;
    *) log "usage: $0 {check|quarantine|restore|delete}"; exit 2 ;;
esac
rc=$?
log "RESCUE_RESULT action=$ACTION rc=$rc"
exit "$rc"
