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
LOG_DIR="$SD_ROOT/logs/rescue"
LOG="$LOG_DIR/runtime-residue-rescue-$ACTION.log"
LOG_PREV="$LOG_DIR/runtime-residue-rescue-$ACTION.previous.log"
RESCUE_BACKUP_ROOT="$SD_ROOT/rescue-backup"
RESCUE_FINAL_BACKUP="$RESCUE_BACKUP_ROOT/runtime-residue-v1"
RESCUE_FINAL_STAGE="$RESCUE_BACKUP_ROOT/.runtime-residue-v1.new"
QUARANTINE_STAGE="$(p /mnt/app/root/.carplay-altscreen.rescue-v1.new)"
LOWER_ORIGINAL="$SD_ROOT/backup/original"
UPPER_ORIGINAL="$SD_ROOT/backup/ORIGINAL"
UNIVERSAL_BACKUP="$SD_ROOT/backup/universal-hook-original"
HMI_BACKUP="$SD_ROOT/backup/basevideo3-hmi-original"
FIREWALL_BACKUP="$SD_ROOT/backup/firewall-original"
STATE_DIR="$SD_ROOT/state"
SI="$(p /mnt/system/etc/eso/production/smartphone_integrator.json)"
PF="$(p /mnt/system/etc/pf.conf)"
JAR="$(p /mnt/app/eso/hmi/lsd/jars/carplay_hook.jar)"

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

same_bytes(){
    [ -f "$1" ] && [ -f "$2" ] || return 1
    cmp -s "$1" "$2" 2>/dev/null
}

find_original_backup(){
    [ -f "$LOWER_ORIGINAL/COMPLETE" ] || return 1
    printf '%s\n' "$LOWER_ORIGINAL"
    return 0
}

find_startup(){
    for rel in /mnt/system/etc/boot/startup.sh /etc/boot/startup.sh; do
        f="$(p "$rel")"
        [ -f "$f" ] && { printf '%s\n' "$f"; return 0; }
    done
    return 1
}

oem_restore_verified(){
    [ ! -e "$ROOT" ] || {
        log "OEM_VERIFY=FAIL reason=MANAGED_RUNTIME_PRESENT"
        return 1
    }
    [ -f "$STATE_DIR/RESTORE_PENDING_REBOOT" ] || {
        log "OEM_VERIFY=FAIL reason=RESTORE_PENDING_REBOOT_MARKER_MISSING"
        return 1
    }
    [ ! -f "$STATE_DIR/INSTALLED" ] || {
        log "OEM_VERIFY=FAIL reason=INSTALLED_MARKER_STILL_PRESENT"
        return 1
    }

    native=$(find_original_backup) || {
        log "OEM_VERIFY=FAIL reason=ORIGINAL_BACKUP_MISSING"
        return 1
    }
    [ -f "$native/manifest.txt" ] || {
        log "OEM_VERIFY=FAIL reason=ORIGINAL_MANIFEST_MISSING"
        return 1
    }

    count=0
    while IFS= read -r rel; do
        [ -n "$rel" ] || continue
        case "$rel" in
          /eso/bin/apps/dio_manager|/mnt/app/eso/bin/apps/dio_manager|/eso/lib/libairplay.so|/armle/usr/lib/libNmeBaseClasses.so|/mnt/app/armle/usr/lib/libNmeBaseClasses.so|/eso/lib/libNmeBaseClasses.so|/mnt/system/etc/eso/production/smartphone_integrator.json|/mnt/system/etc/eso/production/dio_manager.json) ;;
          *) log "OEM_VERIFY=FAIL reason=UNEXPECTED_MANIFEST_PATH path=$rel"; return 1 ;;
        esac
        src="$native/files/$(echo "$rel" | tr '/' '_')"
        dst="$(p "$rel")"
        same_bytes "$src" "$dst" || {
            log "OEM_VERIFY=FAIL reason=NATIVE_FILE_MISMATCH path=$rel"
            return 1
        }
        count=$((count + 1))
    done < "$native/manifest.txt"
    [ "$count" = 5 ] || {
        log "OEM_VERIFY=FAIL reason=NATIVE_MANIFEST_COUNT count=$count expected=5"
        return 1
    }

    ! grep -Fq 'libcarplay_altscreen.so' "$SI" 2>/dev/null || {
        log "OEM_VERIFY=FAIL reason=ALTSCREEN_PRELOAD_STILL_ARMED"
        return 1
    }

    [ -f "$FIREWALL_BACKUP/COMPLETE" ] &&
    [ -f "$FIREWALL_BACKUP/pf.conf" ] &&
    same_bytes "$FIREWALL_BACKUP/pf.conf" "$PF" || {
        log "OEM_VERIFY=FAIL reason=FIREWALL_NOT_RESTORED"
        return 1
    }

    [ -f "$UNIVERSAL_BACKUP/COMPLETE" ] || {
        log "OEM_VERIFY=FAIL reason=UNIVERSAL_BACKUP_MISSING"
        return 1
    }
    hook_present=$(cat "$UNIVERSAL_BACKUP/present" 2>/dev/null || echo invalid)
    hook_rel=$(cat "$UNIVERSAL_BACKUP/path" 2>/dev/null || echo /mnt/app/root/hooks/libcarplay_altscreen.so)
    case "$hook_rel" in
      /mnt/app/root/carplay-altscreen/lib/libcarplay_altscreen.so|/mnt/app/root/hooks/libcarplay_altscreen.so) ;;
      *) log "OEM_VERIFY=FAIL reason=UNIVERSAL_BACKUP_PATH_INVALID path=$hook_rel"; return 1 ;;
    esac
    hook_dst="$(p "$hook_rel")"
    case "$hook_present" in
      0) [ ! -e "$hook_dst" ] || {
           log "OEM_VERIFY=FAIL reason=UNIVERSAL_HOOK_SHOULD_BE_ABSENT"
           return 1
         } ;;
      1) same_bytes "$UNIVERSAL_BACKUP/libcarplay_altscreen.so" "$hook_dst" || {
           log "OEM_VERIFY=FAIL reason=ORIGINAL_UNIVERSAL_HOOK_MISMATCH"
           return 1
         } ;;
      *) log "OEM_VERIFY=FAIL reason=UNIVERSAL_BACKUP_STATE_INVALID"; return 1 ;;
    esac

    [ -f "$HMI_BACKUP/COMPLETE" ] && [ -f "$HMI_BACKUP/target" ] || {
        log "OEM_VERIFY=FAIL reason=HMI_BACKUP_MISSING"
        return 1
    }
    if [ -f "$HMI_BACKUP/present" ] && [ ! -f "$HMI_BACKUP/absent" ]; then
        same_bytes "$HMI_BACKUP/carplay_hook.jar" "$JAR" || {
            log "OEM_VERIFY=FAIL reason=HMI_JAR_MISMATCH"
            return 1
        }
    elif [ -f "$HMI_BACKUP/absent" ] && [ ! -f "$HMI_BACKUP/present" ]; then
        [ ! -e "$JAR" ] || {
            log "OEM_VERIFY=FAIL reason=HMI_JAR_SHOULD_BE_ABSENT"
            return 1
        }
    else
        log "OEM_VERIFY=FAIL reason=HMI_BACKUP_STATE_INVALID"
        return 1
    fi

    startup=$(find_startup) || {
        log "OEM_VERIFY=FAIL reason=STARTUP_NOT_FOUND"
        return 1
    }
    ! grep -E 'BEGIN ALT111 (MIRROR|BASEVIDEO3) AUTOSTART|BEGIN ALTSCREEN DIAGNOSTICS' "$startup" >/dev/null 2>&1 || {
        log "OEM_VERIFY=FAIL reason=ALTSCREEN_STARTUP_BLOCK_REMAINS"
        return 1
    }

    log "OEM_VERIFY=PASS restored_originals=5 preload=ABSENT firewall=OEM hmi=OEM runtime=ABSENT"
    return 0
}

hmi_backup_project_managed(){
    jar=$1
    [ -f "$jar" ] || return 1
    grep -Fq 'com/luka/carplay/cluster/ClusterStateController.class' "$jar" 2>/dev/null && return 0
    grep -Fq 'com/luka/carplay/cluster/WheelZoomBridge.class' "$jar" 2>/dev/null && return 0
    grep -Fq 'com/luka/carplay/cluster/ClusterLayerController.class' "$jar" 2>/dev/null && return 0
    set -- $(cksum < "$jar" 2>/dev/null || echo "0 0")
    sum=${1:-0}
    size=$(wc -c < "$jar" 2>/dev/null || echo 0)
    set -- $size
    size=${1:-0}
    case "$size:$sum" in
      143072:1515795662|149510:180684234|149979:2362627699|150026:3028143795) return 0 ;;
      *) return 1 ;;
    esac
}

verify_native_backup_media(){
    [ -f "$LOWER_ORIGINAL/COMPLETE" ] &&
    [ -f "$LOWER_ORIGINAL/manifest.txt" ] &&
    [ -f "$LOWER_ORIGINAL/overlay_present.txt" ] &&
    [ -f "$LOWER_ORIGINAL/overlay_dir.txt" ] || {
        if [ -f "$UPPER_ORIGINAL/COMPLETE" ]; then
            log "BACKUP_TRUST=FAIL reason=CANONICAL_ORIGINAL_MISSING found_legacy_uppercase=YES action=RENAME_ORIGINAL_TO_original_ON_PC"
        else
            log "BACKUP_TRUST=FAIL reason=ORIGINAL_BACKUP_INCOMPLETE canonical=$LOWER_ORIGINAL"
        fi
        return 1
    }

    count=0
    while IFS= read -r rel; do
        case "$rel" in
          /eso/bin/apps/dio_manager|/mnt/app/eso/bin/apps/dio_manager|/eso/lib/libairplay.so|/armle/usr/lib/libNmeBaseClasses.so|/mnt/app/armle/usr/lib/libNmeBaseClasses.so|/eso/lib/libNmeBaseClasses.so|/mnt/system/etc/eso/production/smartphone_integrator.json|/mnt/system/etc/eso/production/dio_manager.json) ;;
          *) log "BACKUP_TRUST=FAIL reason=UNEXPECTED_NATIVE_MANIFEST_PATH path=$rel"; return 1 ;;
        esac
        member="$LOWER_ORIGINAL/files/$(echo "$rel" | tr '/' '_')"
        [ -s "$member" ] && [ -f "$member.cksum" ] &&
        [ "$(cksum < "$member")" = "$(cat "$member.cksum")" ] || {
            log "BACKUP_TRUST=FAIL reason=NATIVE_MEMBER_CKSUM path=$rel"
            return 1
        }
        count=$((count + 1))
    done < "$LOWER_ORIGINAL/manifest.txt"
    [ "$count" = 5 ] || {
        log "BACKUP_TRUST=FAIL reason=NATIVE_MANIFEST_COUNT count=$count expected=5"
        return 1
    }

    overlay_dir=$(cat "$LOWER_ORIGINAL/overlay_dir.txt" 2>/dev/null || true)
    case "$overlay_dir" in
      /mnt/app/root/carplay-altscreen/lib|/mnt/app/root/lib-target) ;;
      *) log "BACKUP_TRUST=FAIL reason=OVERLAY_DIR_INVALID path=$overlay_dir"; return 1 ;;
    esac
    while IFS= read -r name; do
        case "$name" in
          libairplay.so|libairplax.so|libNmeBaseClasses.so) ;;
          *) log "BACKUP_TRUST=FAIL reason=OVERLAY_MEMBER_INVALID name=$name"; return 1 ;;
        esac
        member="$LOWER_ORIGINAL/files/overlay_$name"
        [ -f "$member" ] && [ -f "$member.cksum" ] &&
        [ "$(cksum < "$member")" = "$(cat "$member.cksum")" ] || {
            log "BACKUP_TRUST=FAIL reason=OVERLAY_MEMBER_CKSUM name=$name"
            return 1
        }
    done < "$LOWER_ORIGINAL/overlay_present.txt"
    return 0
}

verify_firewall_backup_media(){
    [ -f "$FIREWALL_BACKUP/COMPLETE" ] &&
    [ -s "$FIREWALL_BACKUP/pf.conf" ] &&
    [ -f "$FIREWALL_BACKUP/pf.conf.cksum" ] &&
    [ "$(cksum < "$FIREWALL_BACKUP/pf.conf")" = "$(cat "$FIREWALL_BACKUP/pf.conf.cksum")" ] || {
        log "BACKUP_TRUST=FAIL reason=FIREWALL_BACKUP_INVALID"
        return 1
    }
    return 0
}

verify_universal_backup_media(){
    [ -f "$UNIVERSAL_BACKUP/COMPLETE" ] &&
    [ -f "$UNIVERSAL_BACKUP/present" ] || {
        log "BACKUP_TRUST=FAIL reason=UNIVERSAL_HOOK_BACKUP_INCOMPLETE"
        return 1
    }
    hook_path=$(cat "$UNIVERSAL_BACKUP/path" 2>/dev/null || echo /mnt/app/root/hooks/libcarplay_altscreen.so)
    case "$hook_path" in
      /mnt/app/root/carplay-altscreen/lib/libcarplay_altscreen.so|/mnt/app/root/hooks/libcarplay_altscreen.so) ;;
      *) log "BACKUP_TRUST=FAIL reason=UNIVERSAL_HOOK_PATH_INVALID path=$hook_path"; return 1 ;;
    esac
    present=$(cat "$UNIVERSAL_BACKUP/present" 2>/dev/null || echo invalid)
    case "$present" in
      0)
        [ ! -e "$UNIVERSAL_BACKUP/libcarplay_altscreen.so" ] || {
            log "BACKUP_TRUST=FAIL reason=UNIVERSAL_ABSENT_WITH_STALE_BINARY"
            return 1
        }
        ;;
      1)
        [ -s "$UNIVERSAL_BACKUP/libcarplay_altscreen.so" ] &&
        [ -f "$UNIVERSAL_BACKUP/libcarplay_altscreen.so.cksum" ] &&
        [ "$(cksum < "$UNIVERSAL_BACKUP/libcarplay_altscreen.so")" = "$(cat "$UNIVERSAL_BACKUP/libcarplay_altscreen.so.cksum")" ] || {
            log "BACKUP_TRUST=FAIL reason=UNIVERSAL_HOOK_CKSUM"
            return 1
        }
        ;;
      *)
        log "BACKUP_TRUST=FAIL reason=UNIVERSAL_HOOK_STATE_INVALID"
        return 1
        ;;
    esac
    return 0
}

verify_hmi_backup_media(){
    [ -f "$HMI_BACKUP/COMPLETE" ] &&
    [ -f "$HMI_BACKUP/target" ] &&
    [ "$(cat "$HMI_BACKUP/target" 2>/dev/null || true)" = "/mnt/app/eso/hmi/lsd/jars/carplay_hook.jar" ] || {
        log "BACKUP_TRUST=FAIL reason=HMI_BACKUP_METADATA"
        return 1
    }

    hp=0; ha=0
    [ ! -f "$HMI_BACKUP/present" ] || hp=1
    [ ! -f "$HMI_BACKUP/absent" ] || ha=1
    [ $((hp + ha)) -eq 1 ] || {
        log "BACKUP_TRUST=FAIL reason=HMI_BACKUP_PRESENCE_AMBIGUOUS"
        return 1
    }

    if [ "$hp" = 1 ]; then
        [ -s "$HMI_BACKUP/carplay_hook.jar" ] &&
        [ -f "$HMI_BACKUP/cksum" ] &&
        [ "$(cksum < "$HMI_BACKUP/carplay_hook.jar")" = "$(cat "$HMI_BACKUP/cksum")" ] || {
            log "BACKUP_TRUST=FAIL reason=HMI_BACKUP_CKSUM"
            return 1
        }
        hmi_backup_project_managed "$HMI_BACKUP/carplay_hook.jar" && {
            log "BACKUP_TRUST=FAIL reason=HMI_BACKUP_PROJECT_MANAGED"
            return 1
        }
    else
        [ ! -e "$HMI_BACKUP/carplay_hook.jar" ] && [ ! -e "$HMI_BACKUP/cksum" ] || {
            log "BACKUP_TRUST=FAIL reason=HMI_ABSENT_WITH_STALE_PAYLOAD"
            return 1
        }
    fi
    return 0
}

trusted_backup(){
    verify_native_backup_media || return 1
    verify_firewall_backup_media || return 1
    verify_universal_backup_media || return 1
    verify_hmi_backup_media || return 1
    [ -f "$SD_ROOT/backup/boot-diagnostics/COMPLETE" ] || {
        log "BACKUP_TRUST=FAIL reason=BOOT_DIAGNOSTICS_BACKUP_INCOMPLETE"
        return 1
    }
    log "BACKUP_TRUST=PASS original=$LOWER_ORIGINAL firewall=$FIREWALL_BACKUP universal_hook=$UNIVERSAL_BACKUP hmi=$HMI_BACKUP"
    return 0
}

strip_startup_blocks_preflight(){
    awk '
      {
        key=$0
        sub(/\r$/, "", key)
        trimmed=key
        gsub(/^[ \t]+/, "", trimmed)
        gsub(/[ \t]+$/, "", trimmed)
        if (trimmed == "# BEGIN ALT111 MIRROR AUTOSTART") {
          if (block != "") bad=8
          block="old"; next
        }
        if (trimmed == "# END ALT111 MIRROR AUTOSTART") {
          if (block != "old") bad=8
          block=""; next
        }
        if (trimmed == "# BEGIN ALT111 BASEVIDEO3 AUTOSTART") {
          if (block != "") bad=8
          block="new"; next
        }
        if (trimmed == "# END ALT111 BASEVIDEO3 AUTOSTART") {
          if (block != "new") bad=8
          block=""; next
        }
        if (block == "") print
      }
      END {
        if (bad) exit bad
        if (block != "") exit 9
      }
    ' "$1"
}

restore_hmi_live_preflight(){
    hp=0
    [ ! -f "$HMI_BACKUP/present" ] || hp=1
    if [ "$hp" = 1 ]; then
        if [ -f "$JAR" ] && ! hmi_backup_project_managed "$JAR" && ! same_bytes "$HMI_BACKUP/carplay_hook.jar" "$JAR"; then
            log "RESTORE_READINESS=FAIL reason=LIVE_HMI_CONFLICT_WITH_TRUSTED_BACKUP"
            return 1
        fi
    else
        if [ -f "$JAR" ] && ! hmi_backup_project_managed "$JAR"; then
            log "RESTORE_READINESS=FAIL reason=ABSENT_BACKUP_LIVE_JAR_NOT_PROJECT_MANAGED"
            return 1
        fi
    fi
    return 0
}

restore_startup_preflight(){
    startup=$(find_startup) || {
        log "RESTORE_READINESS=FAIL reason=STARTUP_NOT_FOUND"
        return 1
    }
    stage="$SD_ROOT/staging"
    ensure_dirs "$stage" || return 1
    tmp="$stage/rescue-startup-preflight.tmp"
    rm -f "$tmp" 2>/dev/null || true
    strip_startup_blocks_preflight "$startup" > "$tmp" || {
        rm -f "$tmp" 2>/dev/null || true
        log "RESTORE_READINESS=FAIL reason=AUTOSTART_BLOCK_INVALID"
        return 1
    }
    /bin/sh -n "$tmp" >/dev/null 2>&1 || {
        rm -f "$tmp" 2>/dev/null || true
        log "RESTORE_READINESS=FAIL reason=CLEANED_STARTUP_SYNTAX_INVALID"
        return 1
    }
    rm -f "$tmp" 2>/dev/null || true
    return 0
}

run_v34_restore_precheck(){
    controller="$VOLUME/Toolbox/scripts/altscreen_chain_test.sh"
    [ -f "$controller" ] || {
        log "RESTORE_READINESS=FAIL reason=V3_4_CONTROLLER_MISSING"
        return 1
    }
    trusted_backup || return 1
    restore_hmi_live_preflight || return 1
    restore_startup_preflight || return 1

    precheck_log="$LOG_DIR/.restore-precheck.$"
    rm -f "$precheck_log" 2>/dev/null || true
    if [ "$TESTING" = 1 ]; then
        ALTSCREEN_CHAIN_TESTING=1 ALTSCREEN_CHAIN_ROOT="$DEVICE_ROOT" ALTSCREEN_CHAIN_VOLUME="$VOLUME"           /bin/sh "$controller" restore-precheck > "$precheck_log" 2>&1
    else
        /bin/sh "$controller" restore-precheck > "$precheck_log" 2>&1
    fi
    rc=$?
    if [ -f "$precheck_log" ]; then
        while IFS= read -r line; do log "V34_PRECHECK $line"; done < "$precheck_log"
        rm -f "$precheck_log" 2>/dev/null || true
    fi
    [ "$rc" = 0 ] || {
        log "RESTORE_READINESS=FAIL reason=V3_4_RESTORE_PRECHECK rc=$rc"
        return 1
    }
    log "RESTORE_READINESS=PASS controller=V3_4 hmi=SAFE startup=SAFE runtime_cleanup=SAFE recovery_media=TRUSTED"
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

dir_file_manifest(){
    src=$1
    out=$2
    [ -d "$src" ] || return 1
    (
        cd "$src" || exit 1
        find . -type f -print 2>/dev/null | sort | while IFS= read -r rel; do
            [ -f "$rel" ] || continue
            c=$(cksum < "$rel" 2>/dev/null) || exit 1
            set -- $c
            [ "$#" -ge 2 ] || exit 1
            printf '%s|%s|%s\n' "$rel" "${1:-0}" "${2:-0}"
        done
    ) > "$out"
}

dir_tree_manifest(){
    src=$1
    out=$2
    [ -d "$src" ] || return 1
    (
        cd "$src" || exit 1
        find . -type d -print 2>/dev/null | sort
    ) > "$out"
}

verify_rescue_backup_internal(){
    base=$RESCUE_FINAL_BACKUP
    [ -f "$base/COMPLETE" ] &&
    [ -d "$base/payload" ] &&
    [ -f "$base/meta/files.manifest" ] &&
    [ -f "$base/meta/dirs.manifest" ] &&
    [ -f "$base/meta/source_path" ] || {
        log "RESCUE_BACKUP_VERIFY=FAIL reason=STRUCTURE_INCOMPLETE path=$base"
        return 1
    }

    [ "$(cat "$base/meta/source_path" 2>/dev/null || true)" = "/mnt/app/root/.carplay-altscreen.rescue-v1" ] || {
        log "RESCUE_BACKUP_VERIFY=FAIL reason=SOURCE_PATH_MISMATCH"
        return 1
    }

    no_symlinks "$base/payload" || {
        log "RESCUE_BACKUP_VERIFY=FAIL reason=PAYLOAD_SYMLINK"
        return 1
    }

    tmp_files="$base/meta/.verify.files"
    tmp_dirs="$base/meta/.verify.dirs"
    rm -f "$tmp_files" "$tmp_dirs" 2>/dev/null || true

    dir_file_manifest "$base/payload" "$tmp_files" &&
    dir_tree_manifest "$base/payload" "$tmp_dirs" &&
    cmp -s "$base/meta/files.manifest" "$tmp_files" &&
    cmp -s "$base/meta/dirs.manifest" "$tmp_dirs"
    rc=$?
    rm -f "$tmp_files" "$tmp_dirs" 2>/dev/null || true

    [ "$rc" = 0 ] || {
        log "RESCUE_BACKUP_VERIFY=FAIL reason=MANIFEST_MISMATCH"
        return 1
    }

    file_count=$(wc -l < "$base/meta/files.manifest" 2>/dev/null || echo 0)
    dir_count=$(wc -l < "$base/meta/dirs.manifest" 2>/dev/null || echo 0)
    set -- $file_count; file_count=${1:-0}
    set -- $dir_count; dir_count=${1:-0}
    log "RESCUE_BACKUP_VERIFY=PASS path=$base files=$file_count dirs=$dir_count"
    return 0
}

backup_matches_quarantine(){
    verify_rescue_backup_internal || return 1
    [ -d "$QUARANTINE" ] || return 1

    tmp_files="$RESCUE_FINAL_BACKUP/meta/.source.files"
    tmp_dirs="$RESCUE_FINAL_BACKUP/meta/.source.dirs"
    rm -f "$tmp_files" "$tmp_dirs" 2>/dev/null || true

    dir_file_manifest "$QUARANTINE" "$tmp_files" &&
    dir_tree_manifest "$QUARANTINE" "$tmp_dirs" &&
    cmp -s "$RESCUE_FINAL_BACKUP/meta/files.manifest" "$tmp_files" &&
    cmp -s "$RESCUE_FINAL_BACKUP/meta/dirs.manifest" "$tmp_dirs"
    rc=$?
    rm -f "$tmp_files" "$tmp_dirs" 2>/dev/null || true

    [ "$rc" = 0 ] || {
        log "RESCUE_BACKUP_MATCH=FAIL reason=QUARANTINE_DIFFERS_FROM_SD_BACKUP"
        return 1
    }
    log "RESCUE_BACKUP_MATCH=PASS quarantine=/mnt/app/root/.carplay-altscreen.rescue-v1"
    return 0
}

backup_quarantine_to_sd(){
    recognized_unowned "$QUARANTINE" || {
        log "RESCUE_BACKUP=REFUSED reason=QUARANTINE_NOT_RECOGNIZED"
        return 1
    }

    ensure_dirs "$RESCUE_BACKUP_ROOT" || {
        log "RESCUE_BACKUP=FAIL reason=BACKUP_ROOT_CREATE_FAILED"
        return 1
    }

    if [ -e "$RESCUE_FINAL_BACKUP" ]; then
        if backup_matches_quarantine; then
            log "RESCUE_BACKUP=REUSED path=$RESCUE_FINAL_BACKUP overwrite=NO"
            return 0
        fi
        log "RESCUE_BACKUP=REFUSED reason=EXISTING_BACKUP_DIFFERS overwrite=NO path=$RESCUE_FINAL_BACKUP"
        return 1
    fi

    rm -rf "$RESCUE_FINAL_STAGE" 2>/dev/null || {
        log "RESCUE_BACKUP=FAIL reason=STALE_STAGE_REMOVE_FAILED"
        return 1
    }

    ensure_dirs "$RESCUE_FINAL_STAGE/payload" "$RESCUE_FINAL_STAGE/meta" || {
        rm -rf "$RESCUE_FINAL_STAGE" 2>/dev/null || true
        log "RESCUE_BACKUP=FAIL reason=STAGE_CREATE_FAILED"
        return 1
    }

    log "RESCUE_BACKUP=START source=/mnt/app/root/.carplay-altscreen.rescue-v1 destination=$RESCUE_FINAL_BACKUP"
    cp -R "$QUARANTINE/." "$RESCUE_FINAL_STAGE/payload/" || {
        rm -rf "$RESCUE_FINAL_STAGE" 2>/dev/null || true
        log "RESCUE_BACKUP=FAIL reason=COPY_FAILED"
        return 1
    }

    dir_file_manifest "$QUARANTINE" "$RESCUE_FINAL_STAGE/meta/files.manifest" &&
    dir_tree_manifest "$QUARANTINE" "$RESCUE_FINAL_STAGE/meta/dirs.manifest" || {
        rm -rf "$RESCUE_FINAL_STAGE" 2>/dev/null || true
        log "RESCUE_BACKUP=FAIL reason=SOURCE_MANIFEST_FAILED"
        return 1
    }

    dir_file_manifest "$RESCUE_FINAL_STAGE/payload" "$RESCUE_FINAL_STAGE/meta/copied.files" &&
    dir_tree_manifest "$RESCUE_FINAL_STAGE/payload" "$RESCUE_FINAL_STAGE/meta/copied.dirs" &&
    cmp -s "$RESCUE_FINAL_STAGE/meta/files.manifest" "$RESCUE_FINAL_STAGE/meta/copied.files" &&
    cmp -s "$RESCUE_FINAL_STAGE/meta/dirs.manifest" "$RESCUE_FINAL_STAGE/meta/copied.dirs" || {
        rm -rf "$RESCUE_FINAL_STAGE" 2>/dev/null || true
        log "RESCUE_BACKUP=FAIL reason=COPY_VERIFY_FAILED"
        return 1
    }

    rm -f "$RESCUE_FINAL_STAGE/meta/copied.files" "$RESCUE_FINAL_STAGE/meta/copied.dirs" 2>/dev/null || true
    if ! printf '%s\n' "/mnt/app/root/.carplay-altscreen.rescue-v1" > "$RESCUE_FINAL_STAGE/meta/source_path" ||
       ! printf '%s\n' "${delete_mode:-UNKNOWN}" > "$RESCUE_FINAL_STAGE/meta/target_state" ||
       ! printf '%s\n' "MMI-Cockpit-Carplay runtime residue rescue v1" > "$RESCUE_FINAL_STAGE/meta/purpose" ||
       ! touch "$RESCUE_FINAL_STAGE/COMPLETE"; then
        rm -rf "$RESCUE_FINAL_STAGE" 2>/dev/null || true
        log "RESCUE_BACKUP=FAIL reason=METADATA_WRITE_FAILED"
        return 1
    fi
    sync >/dev/null 2>&1 || {
        log "RESCUE_BACKUP=FAIL reason=SYNC_FAILED"
        return 1
    }

    mv "$RESCUE_FINAL_STAGE" "$RESCUE_FINAL_BACKUP" || {
        log "RESCUE_BACKUP=FAIL reason=PUBLISH_FAILED"
        return 1
    }
    sync >/dev/null 2>&1 || {
        log "RESCUE_BACKUP=FAIL reason=PUBLISH_SYNC_FAILED"
        return 1
    }

    backup_matches_quarantine || {
        log "RESCUE_BACKUP=FAIL reason=POST_PUBLISH_VERIFY_FAILED"
        return 1
    }
    log "RESCUE_BACKUP=PASS path=$RESCUE_FINAL_BACKUP deletion_gate=OPEN"
    return 0
}

restore_sd_backup_to_quarantine(){
    [ ! -e "$QUARANTINE" ] || {
        log "RESTORE_SD_BACKUP=REFUSED reason=QUARANTINE_ALREADY_EXISTS production_changed=NO"
        return 1
    }
    verify_rescue_backup_internal || {
        log "RESTORE_SD_BACKUP=REFUSED reason=SD_BACKUP_INVALID production_changed=NO"
        return 1
    }

    mount_app_rw || {
        log "RESTORE_SD_BACKUP=REFUSED reason=MOUNT_APP_RW_FAILED production_changed=NO"
        return 1
    }

    rm -rf "$QUARANTINE_STAGE" 2>/dev/null || {
        mount_app_ro >/dev/null 2>&1 || true
        log "RESTORE_SD_BACKUP=FAIL reason=STAGE_REMOVE_FAILED"
        return 1
    }
    ensure_dirs "$QUARANTINE_STAGE" || {
        mount_app_ro >/dev/null 2>&1 || true
        log "RESTORE_SD_BACKUP=FAIL reason=STAGE_CREATE_FAILED"
        return 1
    }

    cp -R "$RESCUE_FINAL_BACKUP/payload/." "$QUARANTINE_STAGE/" || {
        rm -rf "$QUARANTINE_STAGE" 2>/dev/null || true
        mount_app_ro >/dev/null 2>&1 || true
        log "RESTORE_SD_BACKUP=FAIL reason=COPY_FAILED"
        return 1
    }

    tmp_files="$RESCUE_FINAL_BACKUP/meta/.rehydrate.files"
    tmp_dirs="$RESCUE_FINAL_BACKUP/meta/.rehydrate.dirs"
    dir_file_manifest "$QUARANTINE_STAGE" "$tmp_files" &&
    dir_tree_manifest "$QUARANTINE_STAGE" "$tmp_dirs" &&
    cmp -s "$RESCUE_FINAL_BACKUP/meta/files.manifest" "$tmp_files" &&
    cmp -s "$RESCUE_FINAL_BACKUP/meta/dirs.manifest" "$tmp_dirs"
    rc=$?
    rm -f "$tmp_files" "$tmp_dirs" 2>/dev/null || true
    if [ "$rc" != 0 ]; then
        rm -rf "$QUARANTINE_STAGE" 2>/dev/null || true
        mount_app_ro >/dev/null 2>&1 || true
        log "RESTORE_SD_BACKUP=FAIL reason=REHYDRATE_VERIFY_FAILED"
        return 1
    fi

    mv "$QUARANTINE_STAGE" "$QUARANTINE" || {
        rm -rf "$QUARANTINE_STAGE" 2>/dev/null || true
        mount_app_ro >/dev/null 2>&1 || true
        log "RESTORE_SD_BACKUP=FAIL reason=PUBLISH_FAILED"
        return 1
    }
    sync >/dev/null 2>&1 || true
    mount_app_ro || {
        log "RESTORE_SD_BACKUP=FAIL reason=REMOUNT_APP_RO_FAILED production_changed=YES"
        return 1
    }

    backup_matches_quarantine || {
        log "RESTORE_SD_BACKUP=FAIL reason=POST_RESTORE_VERIFY_FAILED production_changed=YES"
        return 1
    }
    log "RESTORE_SD_BACKUP=PASS destination=/mnt/app/root/.carplay-altscreen.rescue-v1 active_runtime_unchanged=YES"
    return 0
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
        if oem_restore_verified && recognized_unowned "$QUARANTINE"; then
            log "RESCUE_STATE=OEM_RESTORED_WITH_QUARANTINE current_runtime=ABSENT safe_to_delete=YES"
            return 0
        fi
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

    if ! run_v34_restore_precheck; then
        log "QUARANTINE_POSTCHECK=FAIL action=ROLLBACK_TO_ORIGINAL_PATH"
        mount_app_rw || {
            log "QUARANTINE_ROLLBACK=FAIL reason=MOUNT_APP_RW_FAILED recovery_required=YES"
            return 1
        }
        if [ ! -e "$ROOT" ] && mv "$QUARANTINE" "$ROOT"; then
            sync >/dev/null 2>&1 || true
            if mount_app_ro; then
                log "QUARANTINE_ROLLBACK=PASS restored=/mnt/app/root/carplay-altscreen production_state=PRE_QUARANTINE"
            else
                log "QUARANTINE_ROLLBACK=FAIL reason=REMOUNT_APP_RO_FAILED runtime_restored=YES recovery_required=YES"
            fi
        else
            mount_app_ro >/dev/null 2>&1 || true
            log "QUARANTINE_ROLLBACK=FAIL reason=MOVE_BACK_FAILED recovery_required=YES"
        fi
        return 1
    fi

    log "QUARANTINE=PASS from=/mnt/app/root/carplay-altscreen to=/mnt/app/root/.carplay-altscreen.rescue-v1 deletion=NONE reversible=YES restore_preflight=PASS"
    log "NEXT_ACTION=RUN_V3_4_RESTORE_ORIGINAL recommended=YES alternative=V3_4_INSTALL"
    return 0
}

do_delete(){
    [ -d "$QUARANTINE" ] && [ ! -L "$QUARANTINE" ] || {
        log "DELETE_QUARANTINE=REFUSED reason=QUARANTINE_ABSENT_OR_UNSAFE production_changed=NO"
        return 1
    }

    delete_mode=""
    if current_v34_runtime "$ROOT"; then
        delete_mode=V3_4
        log "DELETE_TARGET_STATE=V3_4_RUNTIME_VERIFIED"
    elif oem_restore_verified; then
        delete_mode=OEM_RESTORED
        log "DELETE_TARGET_STATE=OEM_RESTORE_VERIFIED"
    else
        log "DELETE_QUARANTINE=REFUSED reason=NEITHER_V3_4_NOR_OEM_RESTORE_VERIFIED production_changed=NO"
        log "ACTION=REBOOT_AND_VERIFY_TARGET_STATE_FIRST"
        return 1
    fi

    recognized_unowned "$QUARANTINE" || {
        log "DELETE_QUARANTINE=REFUSED reason=QUARANTINE_NOT_RECOGNIZED production_changed=NO"
        return 1
    }

    log "DELETE_PREFLIGHT=PASS target_state=$delete_mode quarantine=LEGACY_UNOWNED_RECOGNIZED backup=TRUSTED"
    log "DELETE_SCOPE=/mnt/app/root/.carplay-altscreen.rescue-v1 only"
    log "DELETE_CURRENT_RUNTIME=NO"

    backup_quarantine_to_sd || {
        log "DELETE_QUARANTINE=REFUSED reason=FINAL_SD_BACKUP_FAILED production_changed=NO"
        return 1
    }
    log "DELETE_BACKUP_GATE=PASS backup=$RESCUE_FINAL_BACKUP"

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

    if [ "$delete_mode" = V3_4 ]; then
        current_v34_runtime "$ROOT" || {
            log "DELETE_QUARANTINE=FAIL reason=CURRENT_V3_4_RUNTIME_CHANGED_AFTER_DELETE production_changed=YES"
            return 1
        }
        log "CURRENT_V3_4_RUNTIME=PRESERVED"
    else
        oem_restore_verified || {
            log "DELETE_QUARANTINE=FAIL reason=OEM_RESTORE_STATE_CHANGED_AFTER_DELETE production_changed=YES"
            return 1
        }
        log "OEM_RUNTIME_STATE=PRESERVED"
    fi

    verify_rescue_backup_internal || {
        log "DELETE_QUARANTINE=FAIL reason=FINAL_SD_BACKUP_INVALID_AFTER_DELETE production_changed=YES"
        return 1
    }

    log "DELETE_QUARANTINE=PASS path=/mnt/app/root/.carplay-altscreen.rescue-v1 irreversible_on_unit=YES target_state=$delete_mode"
    log "RESCUE_SD_BACKUP=PRESERVED path=$RESCUE_FINAL_BACKUP recoverable=YES"
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
log "RESCUE_LOG=$LOG"
log "RESCUE_VOLUME=$VOLUME"
log "RUNTIME_PATH=/mnt/app/root/carplay-altscreen"
log "QUARANTINE_PATH=/mnt/app/root/.carplay-altscreen.rescue-v1"
case "$ACTION" in
    check) check_state ;;
    quarantine) do_quarantine ;;
    restore) do_restore ;;
    delete) do_delete ;;
    restore-backup) restore_sd_backup_to_quarantine ;;
    *) log "usage: $0 {check|quarantine|restore|delete|restore-backup}"; exit 2 ;;
esac
rc=$?
log "RESCUE_RESULT action=$ACTION rc=$rc"
exit "$rc"
