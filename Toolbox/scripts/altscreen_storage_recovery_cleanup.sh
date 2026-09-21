#!/bin/sh
# MMI-Cockpit-Carplay confirmed historical storage cleanup.
#
# SAFETY CONTRACT:
# - cleanup is restricted to exact, reviewed project-owned paths/patterns;
# - every target is backed up to SD and verified before any deletion;
# - no cleanup is allowed without a writable SD card;
# - live startup/config files are checksummed and never rewritten;
# - current MMI Mirror runtime or live libcp_mirror.so references block Mirror cleanup;
# - a post-clean read-only scan is run automatically.
set -u

ensure_dirs() {
    for dir in "$@"; do
        [ -d "$dir" ] && continue
        mkdir -p "$dir" || return 1
    done
    return 0
}

TESTING=${ALTSCREEN_RECOVERY_TESTING:-0}
ROOT=""
VOLUME=""

if [ "$TESTING" = 1 ]; then
    ROOT=${ALTSCREEN_RECOVERY_ROOT:-}
    VOLUME=${ALTSCREEN_RECOVERY_VOLUME:-}
    case "$ROOT" in /tmp/*|/var/tmp/*) ;; *) echo "FAIL: invalid ALTSCREEN_RECOVERY_ROOT" >&2; exit 2 ;; esac
    case "$VOLUME" in /tmp/*|/var/tmp/*) ;; *) echo "FAIL: invalid ALTSCREEN_RECOVERY_VOLUME" >&2; exit 2 ;; esac
else
    for candidate in /net/mmx/fs/sda0 /net/mmx/fs/sda1 /net/mmx/fs/sdb0 /net/mmx/fs/sdb1 /fs/sda0 /fs/sda1 /fs/sdb0 /fs/sdb1; do
        if [ -d "$candidate/Toolbox" ]; then
            VOLUME=$candidate
            break
        fi
    done
fi

p(){ printf '%s%s\n' "$ROOT" "$1"; }

[ -n "$VOLUME" ] && [ -d "$VOLUME/Toolbox" ] || {
    echo "CLEANUP=REFUSED reason=SD_WITH_TOOLBOX_NOT_FOUND"
    exit 1
}

STAMP=$(date +%Y%m%d_%H%M%S 2>/dev/null || echo unknown)
RUN_NAME="cleanup_${STAMP}_$$"
LOG_ROOT="$VOLUME/MMI-Cockpit-Carplay/logs/storage-recovery"
BACKUP_ROOT="$VOLUME/MMI-Cockpit-Carplay/cleanup-backup"
RUN_DIR="$LOG_ROOT/$RUN_NAME"
BACKUP_DIR="$BACKUP_ROOT/$RUN_NAME"
FILES_DIR="$BACKUP_DIR/files"
TXN_DIR="$(p /tmp/MMI-Cockpit-Carplay/txn/storage-cleanup.$$)"

if ! ensure_dirs "$RUN_DIR" "$FILES_DIR" "$TXN_DIR"; then
    echo "CLEANUP=REFUSED reason=SD_OR_TMP_NOT_WRITABLE"
    exit 1
fi
if ! printf '%s\n' "MMI-Cockpit-Carplay Storage Recovery cleanup" > "$RUN_DIR/CLEANUP_REPORT.txt" 2>/dev/null; then
    echo "CLEANUP=REFUSED reason=SD_LOG_NOT_WRITABLE"
    exit 1
fi
if ! printf '%s\n' "backup_probe" > "$BACKUP_DIR/.write-test" 2>/dev/null; then
    echo "CLEANUP=REFUSED reason=SD_BACKUP_NOT_WRITABLE"
    exit 1
fi
rm -f "$BACKUP_DIR/.write-test" 2>/dev/null || {
    echo "CLEANUP=REFUSED reason=SD_BACKUP_PROBE_CLEANUP_FAILED"
    exit 1
}

REPORT="$RUN_DIR/CLEANUP_REPORT.txt"
MANIFEST="$RUN_DIR/delete_manifest.txt"
RESULTS="$RUN_DIR/delete_results.txt"
SKIPPED="$RUN_DIR/skipped_files.txt"
DF_BEFORE="$RUN_DIR/DF.before.txt"
DF_AFTER="$RUN_DIR/DF.after.txt"
CHECK_BEFORE="$RUN_DIR/checksums.before.txt"
CHECK_AFTER="$RUN_DIR/checksums.after.txt"
SYSTEM_LIST="$TXN_DIR/system_candidates.list"
APP_LIST="$TXN_DIR/app_candidates.list"
: > "$MANIFEST"
: > "$RESULTS"
: > "$SKIPPED"
: > "$SYSTEM_LIST"
: > "$APP_LIST"

display_path() {
    path=$1
    if [ -n "$ROOT" ]; then
        case "$path" in
          "$ROOT"/*) printf '%s\n' "${path#"$ROOT"}" ;;
          *) printf '%s\n' "$path" ;;
        esac
    else
        printf '%s\n' "$path"
    fi
}

file_bytes() {
    f=$1
    n=$(wc -c < "$f" 2>/dev/null || echo 0)
    set -- $n
    case "${1:-0}" in ''|*[!0-9]*) echo 0 ;; *) echo "$1" ;; esac
}

path_bytes_hint() {
    path=$1
    if [ -f "$path" ]; then
        file_bytes "$path"
        return
    fi
    if [ -d "$path" ]; then
        line=$(du -sk "$path" 2>/dev/null | head -n 1 || true)
        set -- $line
        kb=${1:-0}
        case "$kb" in ''|*[!0-9]*) kb=0 ;; esac
        echo "$((kb * 1024))"
        return
    fi
    echo 0
}

file_cksum() {
    cksum < "$1" 2>/dev/null
}

same_file() {
    [ -f "$1" ] && [ -f "$2" ] || return 1
    [ "$(file_bytes "$1")" = "$(file_bytes "$2")" ] || return 1
    [ "$(file_cksum "$1")" = "$(file_cksum "$2")" ]
}

dir_file_count() {
    find "$1" -type f -print 2>/dev/null | wc -l | awk '{print $1}'
}

dir_file_bytes() {
    total=0
    find "$1" -type f -print 2>/dev/null | while IFS= read -r f; do
        n=$(wc -c < "$f" 2>/dev/null || echo 0)
        set -- $n
        case "${1:-0}" in ''|*[!0-9]*) n=0 ;; *) n=$1 ;; esac
        total=$((total + n))
        echo "$total"
    done | tail -n 1
}

same_dir_hint() {
    [ -d "$1" ] && [ -d "$2" ] || return 1
    a_count=$(dir_file_count "$1")
    b_count=$(dir_file_count "$2")
    [ "$a_count" = "$b_count" ] || return 1
    a_bytes=$(dir_file_bytes "$1")
    b_bytes=$(dir_file_bytes "$2")
    [ "${a_bytes:-0}" = "${b_bytes:-0}" ]
}

capture_df() {
    out=$1
    {
        echo "=== /mnt/system ==="
        df -k "$(p /mnt/system)" 2>/dev/null || df "$(p /mnt/system)" 2>/dev/null || true
        echo
        echo "=== /mnt/app ==="
        df -k "$(p /mnt/app)" 2>/dev/null || df "$(p /mnt/app)" 2>/dev/null || true
        echo
        echo "=== SD ==="
        df -k "$VOLUME" 2>/dev/null || df "$VOLUME" 2>/dev/null || true
    } > "$out" 2>&1
}

record_live_checksums() {
    out=$1
    : > "$out"
    for logical in \
        /mnt/system/etc/boot/startup.sh \
        /mnt/system/etc/eso/production/smartphone_integrator.json \
        /mnt/system/etc/eso/production/dio_manager.json \
        /mnt/system/etc/pf.conf; do
        f=$(p "$logical")
        if [ -f "$f" ]; then
            printf '%s ' "$logical" >> "$out"
            file_cksum "$f" >> "$out" 2>/dev/null || echo unavailable >> "$out"
        else
            echo "$logical ABSENT" >> "$out"
        fi
    done
}

valid_startup_temp_name() {
    name=$1
    case "$name" in
      startup.sh.basevideo3.block.*|startup.sh.basevideo3.clean.*|startup.sh.basevideo3.new.*|startup.sh.basevideo3.original.*|\
      startup.sh.mirror.block.*|startup.sh.mirror.clean.*|startup.sh.mirror.new.*|startup.sh.mirror.original.*)
        pid=${name##*.}
        case "$pid" in ''|*[!0-9]*) return 1 ;; esac
        return 0
        ;;
      *) return 1 ;;
    esac
}

add_system_candidate() {
    path=$1
    [ -f "$path" ] || return 0
    name=$(basename -- "$path")
    valid_startup_temp_name "$name" || {
        echo "SKIP path=$(display_path "$path") reason=NAME_NOT_WHITELISTED" >> "$SKIPPED"
        return 0
    }
    printf '%s\n' "$path" >> "$SYSTEM_LIST"
    bytes=$(path_bytes_hint "$path")
    {
        echo "[SYSTEM_STARTUP_TEMP]"
        echo "path=$(display_path "$path")"
        echo "bytes=$bytes"
        printf 'cksum='
        file_cksum "$path" 2>/dev/null || echo unavailable
        echo
    } >> "$MANIFEST"
}

live_refers_to_mirror_hook() {
    needle="/mnt/app/root/hooks/libcp_mirror.so"
    for logical in \
        /mnt/system/etc/boot/startup.sh \
        /mnt/system/etc/eso/production/smartphone_integrator.json \
        /mnt/system/etc/eso/production/dio_manager.json \
        /mnt/system/etc/pf.conf; do
        f=$(p "$logical")
        [ -f "$f" ] || continue
        grep -F "$needle" "$f" >/dev/null 2>&1 && return 0
    done
    return 1
}

add_app_candidate() {
    kind=$1
    path=$2
    [ -e "$path" ] || return 0
    printf '%s|%s\n' "$kind" "$path" >> "$APP_LIST"
    bytes=$(path_bytes_hint "$path")
    {
        echo "[$kind]"
        echo "path=$(display_path "$path")"
        echo "bytes=$bytes"
        if [ -f "$path" ]; then
            printf 'cksum='
            file_cksum "$path" 2>/dev/null || echo unavailable
        else
            echo "type=directory"
            du -sk "$path" 2>/dev/null || true
        fi
        echo
    } >> "$MANIFEST"
}

backup_file() {
    src=$1
    dst=$2
    ensure_dirs "$(dirname -- "$dst")" || return 1
    cp "$src" "$dst" || return 1
    same_file "$src" "$dst"
}

backup_dir() {
    src=$1
    dst=$2
    ensure_dirs "$(dirname -- "$dst")" || return 1
    [ ! -e "$dst" ] || return 1
    cp -R "$src" "$dst" || return 1
    same_dir_hint "$src" "$dst"
}

mount_system_rw(){ [ "$TESTING" = 1 ] || mount -uw /mnt/system; }
mount_system_ro(){ [ "$TESTING" = 1 ] || mount -ur /mnt/system; }
mount_app_rw(){ [ "$TESTING" = 1 ] || mount -uw /mnt/app; }
mount_app_ro(){ [ "$TESTING" = 1 ] || mount -ur /mnt/app; }

SYSTEM_RW=0
APP_RW=0
cleanup_mounts() {
    if [ "$APP_RW" = 1 ]; then mount_app_ro >/dev/null 2>&1 || true; APP_RW=0; fi
    if [ "$SYSTEM_RW" = 1 ]; then mount_system_ro >/dev/null 2>&1 || true; SYSTEM_RW=0; fi
}
trap 'cleanup_mounts; echo "CLEANUP=INTERRUPTED" >> "$REPORT"; exit 130' 1 2 15

CHAIN_LOCK="$VOLUME/MMI-Cockpit-Carplay/state/.chain_test.lock"
if [ -e "$CHAIN_LOCK" ]; then
    {
        echo "CLEANUP=REFUSED"
        echo "reason=CHAIN_TEST_OPERATION_LOCK_PRESENT"
        echo "path=$CHAIN_LOCK"
    } >> "$REPORT"
    echo "CLEANUP=REFUSED reason=CHAIN_TEST_OPERATION_LOCK_PRESENT"
    exit 1
fi

command -v cksum >/dev/null 2>&1 || {
    echo "CLEANUP=REFUSED reason=CKSUM_UNAVAILABLE" >> "$REPORT"
    echo "CLEANUP=REFUSED reason=CKSUM_UNAVAILABLE"
    exit 1
}

STARTUP="$(p /mnt/system/etc/boot/startup.sh)"
[ -f "$STARTUP" ] || {
    echo "CLEANUP=REFUSED reason=LIVE_STARTUP_MISSING" >> "$REPORT"
    echo "CLEANUP=REFUSED reason=LIVE_STARTUP_MISSING"
    exit 1
}

MMI_RUNTIME="$(p /mnt/app/root/mmi-mirror)"
if [ -e "$MMI_RUNTIME" ]; then
    echo "MMI_MIRROR_RUNTIME=PRESENT app_mirror_cleanup=REFUSED" >> "$SKIPPED"
    APP_MIRROR_ALLOWED=0
else
    APP_MIRROR_ALLOWED=1
fi

capture_df "$DF_BEFORE"
record_live_checksums "$CHECK_BEFORE"
STARTUP_CKSUM_BEFORE=$(file_cksum "$STARTUP") || {
    echo "CLEANUP=REFUSED reason=STARTUP_CHECKSUM_FAILED" >> "$REPORT"
    echo "CLEANUP=REFUSED reason=STARTUP_CHECKSUM_FAILED"
    exit 1
}

BOOT="$(p /mnt/system/etc/boot)"
for path in \
    "$BOOT"/startup.sh.basevideo3.block.* \
    "$BOOT"/startup.sh.basevideo3.clean.* \
    "$BOOT"/startup.sh.basevideo3.new.* \
    "$BOOT"/startup.sh.basevideo3.original.* \
    "$BOOT"/startup.sh.mirror.block.* \
    "$BOOT"/startup.sh.mirror.clean.* \
    "$BOOT"/startup.sh.mirror.new.* \
    "$BOOT"/startup.sh.mirror.original.*; do
    add_system_candidate "$path"
done

MIRROR_HOOK="$(p /mnt/app/root/hooks/libcp_mirror.so)"
MIRROR_PREVIOUS="$(p /mnt/app/root/carplay-altscreen/tmp/mirror.previous)"

if [ "$APP_MIRROR_ALLOWED" = 1 ] && [ -f "$MIRROR_HOOK" ]; then
    if live_refers_to_mirror_hook; then
        echo "SKIP path=/mnt/app/root/hooks/libcp_mirror.so reason=LIVE_CONFIG_REFERENCE" >> "$SKIPPED"
    else
        add_app_candidate LEGACY_MMI_MIRROR_HOOK "$MIRROR_HOOK"
    fi
fi

if [ "$APP_MIRROR_ALLOWED" = 1 ] && [ -e "$MIRROR_PREVIOUS" ]; then
    add_app_candidate LEGACY_ALTSCREEN_MIRROR_PREVIOUS "$MIRROR_PREVIOUS"
fi

SYSTEM_COUNT=$(wc -l < "$SYSTEM_LIST" 2>/dev/null || echo 0)
set -- $SYSTEM_COUNT; SYSTEM_COUNT=${1:-0}
APP_COUNT=$(wc -l < "$APP_LIST" 2>/dev/null || echo 0)
set -- $APP_COUNT; APP_COUNT=${1:-0}

SYSTEM_BYTES=0
while IFS= read -r path; do
    [ -n "$path" ] || continue
    SYSTEM_BYTES=$((SYSTEM_BYTES + $(path_bytes_hint "$path")))
done < "$SYSTEM_LIST"

APP_BYTES=0
while IFS='|' read -r kind path; do
    [ -n "$path" ] || continue
    APP_BYTES=$((APP_BYTES + $(path_bytes_hint "$path")))
done < "$APP_LIST"

{
    echo "CLEANUP_MODE=CONFIRMED_LEGACY_WHITELIST"
    echo "DELETE_LOGGING=ENABLED"
    echo "SD_BACKUP_REQUIRED=YES"
    echo "RUN_DIR=$RUN_DIR"
    echo "BACKUP_DIR=$BACKUP_DIR"
    echo "SYSTEM_CANDIDATE_COUNT=$SYSTEM_COUNT"
    echo "SYSTEM_CANDIDATE_BYTES=$SYSTEM_BYTES"
    echo "APP_CANDIDATE_COUNT=$APP_COUNT"
    echo "APP_CANDIDATE_BYTES=$APP_BYTES"
    echo "MMI_MIRROR_RUNTIME_PRESENT=$([ -e "$MMI_RUNTIME" ] && echo YES || echo NO)"
} >> "$REPORT"

# Back up every candidate to SD before any persistent vehicle deletion.
while IFS= read -r path; do
    [ -n "$path" ] || continue
    name=$(basename -- "$path")
    dst="$FILES_DIR/system_boot/$name"
    if ! backup_file "$path" "$dst"; then
        echo "BACKUP=FAIL path=$(display_path "$path")" >> "$REPORT"
        echo "CLEANUP=REFUSED reason=BACKUP_FAILED path=$(display_path "$path")"
        exit 1
    fi
    echo "BACKUP=PASS path=$(display_path "$path") dst=$dst" >> "$RESULTS"
done < "$SYSTEM_LIST"

while IFS='|' read -r kind path; do
    [ -n "$path" ] || continue
    case "$kind" in
      LEGACY_MMI_MIRROR_HOOK)
        dst="$FILES_DIR/app_hooks/libcp_mirror.so"
        backup_file "$path" "$dst" || {
            echo "BACKUP=FAIL path=$(display_path "$path")" >> "$REPORT"
            echo "CLEANUP=REFUSED reason=BACKUP_FAILED path=$(display_path "$path")"
            exit 1
        }
        ;;
      LEGACY_ALTSCREEN_MIRROR_PREVIOUS)
        dst="$FILES_DIR/runtime_tmp/mirror.previous"
        if [ -d "$path" ]; then
            backup_dir "$path" "$dst" || {
                echo "BACKUP=FAIL path=$(display_path "$path")" >> "$REPORT"
                echo "CLEANUP=REFUSED reason=BACKUP_FAILED path=$(display_path "$path")"
                exit 1
            }
        else
            backup_file "$path" "$dst" || {
                echo "BACKUP=FAIL path=$(display_path "$path")" >> "$REPORT"
                echo "CLEANUP=REFUSED reason=BACKUP_FAILED path=$(display_path "$path")"
                exit 1
            }
        fi
        ;;
      *)
        echo "CLEANUP=REFUSED reason=UNKNOWN_APP_CANDIDATE kind=$kind" >> "$REPORT"
        exit 1
        ;;
    esac
    echo "BACKUP=PASS path=$(display_path "$path") dst=$dst" >> "$RESULTS"
done < "$APP_LIST"

cp "$MANIFEST" "$BACKUP_DIR/delete_manifest.txt" || {
    echo "CLEANUP=REFUSED reason=MANIFEST_BACKUP_FAILED" >> "$REPORT"
    exit 1
}
cp "$CHECK_BEFORE" "$BACKUP_DIR/checksums.before.txt" || {
    echo "CLEANUP=REFUSED reason=CHECKSUM_BACKUP_FAILED" >> "$REPORT"
    exit 1
}
printf '%s\n' "BACKUP_COMPLETE=YES" > "$BACKUP_DIR/BACKUP_COMPLETE" || {
    echo "CLEANUP=REFUSED reason=BACKUP_COMPLETE_MARKER_FAILED" >> "$REPORT"
    exit 1
}
sync >/dev/null 2>&1 || true

# Delete only the canonical /mnt/system/etc/boot whitelist.
if [ "$SYSTEM_COUNT" -gt 0 ]; then
    mount_system_rw || {
        echo "CLEANUP=FAIL reason=SYSTEM_MOUNT_RW_FAILED" >> "$REPORT"
        exit 1
    }
    SYSTEM_RW=1

    while IFS= read -r path; do
        [ -n "$path" ] || continue
        [ "$(dirname -- "$path")" = "$BOOT" ] || {
            echo "DELETE=REFUSED path=$(display_path "$path") reason=OUTSIDE_CANONICAL_BOOT_DIR" >> "$RESULTS"
            cleanup_mounts
            exit 1
        }
        name=$(basename -- "$path")
        valid_startup_temp_name "$name" || {
            echo "DELETE=REFUSED path=$(display_path "$path") reason=NAME_REVALIDATION_FAILED" >> "$RESULTS"
            cleanup_mounts
            exit 1
        }
        if [ -f "$path" ]; then
            if rm -f "$path"; then
                echo "DELETE=PASS path=$(display_path "$path")" >> "$RESULTS"
            else
                echo "DELETE=FAIL path=$(display_path "$path")" >> "$RESULTS"
                cleanup_mounts
                exit 1
            fi
        else
            echo "DELETE=SKIP_ALREADY_ABSENT path=$(display_path "$path")" >> "$RESULTS"
        fi
    done < "$SYSTEM_LIST"

    sync >/dev/null 2>&1 || true
    if ! mount_system_ro; then
        echo "CLEANUP=FAIL reason=SYSTEM_REMOUNT_RO_FAILED" >> "$REPORT"
        cleanup_mounts
        exit 1
    fi
    SYSTEM_RW=0
fi

# Delete the two reviewed MMI/Mirror leftovers only after live-reference checks.
if [ "$APP_COUNT" -gt 0 ]; then
    mount_app_rw || {
        echo "CLEANUP=FAIL reason=APP_MOUNT_RW_FAILED" >> "$REPORT"
        exit 1
    }
    APP_RW=1

    while IFS='|' read -r kind path; do
        [ -n "$path" ] || continue
        case "$kind" in
          LEGACY_MMI_MIRROR_HOOK)
            [ "$path" = "$MIRROR_HOOK" ] || {
                echo "DELETE=REFUSED path=$(display_path "$path") reason=HOOK_PATH_MISMATCH" >> "$RESULTS"
                cleanup_mounts
                exit 1
            }
            if live_refers_to_mirror_hook; then
                echo "DELETE=SKIP path=/mnt/app/root/hooks/libcp_mirror.so reason=LIVE_CONFIG_REFERENCE_RECHECK" >> "$RESULTS"
                continue
            fi
            if [ -f "$path" ]; then
                rm -f "$path" || {
                    echo "DELETE=FAIL path=/mnt/app/root/hooks/libcp_mirror.so" >> "$RESULTS"
                    cleanup_mounts
                    exit 1
                }
                echo "DELETE=PASS path=/mnt/app/root/hooks/libcp_mirror.so" >> "$RESULTS"
            fi
            ;;
          LEGACY_ALTSCREEN_MIRROR_PREVIOUS)
            [ "$path" = "$MIRROR_PREVIOUS" ] || {
                echo "DELETE=REFUSED path=$(display_path "$path") reason=MIRROR_PREVIOUS_PATH_MISMATCH" >> "$RESULTS"
                cleanup_mounts
                exit 1
            }
            [ ! -e "$MMI_RUNTIME" ] || {
                echo "DELETE=SKIP path=/mnt/app/root/carplay-altscreen/tmp/mirror.previous reason=MMI_MIRROR_RUNTIME_REAPPEARED" >> "$RESULTS"
                continue
            }
            if [ -e "$path" ]; then
                rm -rf "$path" || {
                    echo "DELETE=FAIL path=/mnt/app/root/carplay-altscreen/tmp/mirror.previous" >> "$RESULTS"
                    cleanup_mounts
                    exit 1
                }
                echo "DELETE=PASS path=/mnt/app/root/carplay-altscreen/tmp/mirror.previous" >> "$RESULTS"
            fi
            ;;
        esac
    done < "$APP_LIST"

    sync >/dev/null 2>&1 || true
    if ! mount_app_ro; then
        echo "CLEANUP=FAIL reason=APP_REMOUNT_RO_FAILED" >> "$REPORT"
        cleanup_mounts
        exit 1
    fi
    APP_RW=0
fi

STARTUP_CKSUM_AFTER=$(file_cksum "$STARTUP") || {
    echo "CLEANUP=FAIL reason=STARTUP_POST_CHECKSUM_FAILED" >> "$REPORT"
    exit 1
}
record_live_checksums "$CHECK_AFTER"
capture_df "$DF_AFTER"

if [ "$STARTUP_CKSUM_BEFORE" != "$STARTUP_CKSUM_AFTER" ]; then
    {
        echo "STARTUP_UNCHANGED=NO"
        echo "CLEANUP=FAIL"
        echo "reason=LIVE_STARTUP_CHANGED"
    } >> "$REPORT"
    echo "CLEANUP=FAIL reason=LIVE_STARTUP_CHANGED"
    exit 1
fi

REMAINING_SYSTEM=0
while IFS= read -r path; do
    [ -n "$path" ] || continue
    [ ! -e "$path" ] || REMAINING_SYSTEM=$((REMAINING_SYSTEM + 1))
done < "$SYSTEM_LIST"

POST_SCAN_STATUS=NOT_RUN
SCANNER="$(dirname -- "$0")/altscreen_storage_recovery_scan.sh"
if [ -f "$SCANNER" ]; then
    if ALTSCREEN_RECOVERY_TESTING="$TESTING" ALTSCREEN_RECOVERY_ROOT="$ROOT" ALTSCREEN_RECOVERY_VOLUME="$VOLUME" \
       /bin/sh "$SCANNER" > "$RUN_DIR/POST_SCAN.txt" 2>&1; then
        POST_SCAN_STATUS=PASS
        if [ -s "$LOG_ROOT/LAST_SCAN.txt" ]; then
            POST_SCAN_DIR=$(cat "$LOG_ROOT/LAST_SCAN.txt" 2>/dev/null || true)
            echo "POST_SCAN_DIR=$POST_SCAN_DIR" >> "$REPORT"
        fi
    else
        POST_SCAN_STATUS=FAIL
    fi
fi

{
    echo "STARTUP_UNCHANGED=YES"
    echo "SYSTEM_TARGETS_REMAINING=$REMAINING_SYSTEM"
    echo "POST_SCAN=$POST_SCAN_STATUS"
    echo "CLEANUP=PASS"
} >> "$REPORT"
printf '%s\n' "$RUN_DIR" > "$LOG_ROOT/LAST_CLEANUP.txt" 2>/dev/null || true
printf '%s\n' "CLEANUP_COMPLETE=YES" > "$RUN_DIR/CLEANUP_COMPLETE"
rm -rf "$TXN_DIR" 2>/dev/null || true
trap - 1 2 15

echo "CLEANUP=PASS"
echo "DELETE_LOGGING=ENABLED"
echo "BACKUP_DIR=$BACKUP_DIR"
echo "REPORT_DIR=$RUN_DIR"
echo "SYSTEM_FILES_TARGETED=$SYSTEM_COUNT"
echo "SYSTEM_BYTES_HINT=$SYSTEM_BYTES"
echo "APP_ITEMS_TARGETED=$APP_COUNT"
echo "APP_BYTES_HINT=$APP_BYTES"
echo "STARTUP_UNCHANGED=YES"
echo "SYSTEM_TARGETS_REMAINING=$REMAINING_SYSTEM"
echo "POST_SCAN=$POST_SCAN_STATUS"
echo "NEXT_STEP=review_DF.after_and_POST_SCAN"
exit 0
