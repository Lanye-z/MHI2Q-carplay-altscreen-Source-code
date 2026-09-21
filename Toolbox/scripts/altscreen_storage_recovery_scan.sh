#!/bin/sh
# MMI-Cockpit-Carplay historical storage recovery scanner.
# READ-ONLY with respect to vehicle persistent filesystems:
# - never remounts /mnt/system or /mnt/app writable
# - never deletes, moves, copies, or rewrites vehicle files
# - writes reports only to SD, or /tmp when SD is unavailable/unwritable
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
    if [ -n "$VOLUME" ]; then
        case "$VOLUME" in /tmp/*|/var/tmp/*) ;; *) echo "FAIL: invalid ALTSCREEN_RECOVERY_VOLUME" >&2; exit 2 ;; esac
    fi
else
    for candidate in /net/mmx/fs/sda0 /net/mmx/fs/sda1 /net/mmx/fs/sdb0 /net/mmx/fs/sdb1 /fs/sda0 /fs/sda1 /fs/sdb0 /fs/sdb1; do
        if [ -d "$candidate/Toolbox" ]; then
            VOLUME=$candidate
            break
        fi
    done
fi

p(){ printf '%s%s\n' "$ROOT" "$1"; }

STAMP=$(date +%Y%m%d_%H%M%S 2>/dev/null || echo unknown)
SCAN_NAME="storage_scan_${STAMP}_$$"
OUTPUT_STORAGE=TMP
REPORT_ROOT=""
SCAN_DIR=""

select_output() {
    if [ -n "$VOLUME" ] && [ -d "$VOLUME/Toolbox" ]; then
        candidate_root="$VOLUME/MMI-Cockpit-Carplay/logs/storage-recovery"
        candidate_scan="$candidate_root/$SCAN_NAME"
        if ensure_dirs "$candidate_scan" 2>/dev/null &&
           (printf '%s\n' "STORAGE_RECOVERY_SCAN" > "$candidate_scan/SUMMARY.txt") 2>/dev/null; then
            REPORT_ROOT=$candidate_root
            SCAN_DIR=$candidate_scan
            OUTPUT_STORAGE=SD
            return 0
        fi
    fi

    candidate_root="$(p /tmp/MMI-Cockpit-Carplay/logs/storage-recovery)"
    candidate_scan="$candidate_root/$SCAN_NAME"
    ensure_dirs "$candidate_scan" 2>/dev/null || return 1
    printf '%s\n' "STORAGE_RECOVERY_SCAN" > "$candidate_scan/SUMMARY.txt" 2>/dev/null || return 1
    REPORT_ROOT=$candidate_root
    SCAN_DIR=$candidate_scan
    OUTPUT_STORAGE=TMP
    return 0
}

select_output || {
    echo "FAIL: cannot create recovery report on SD or /tmp" >&2
    exit 1
}

SUMMARY="$SCAN_DIR/SUMMARY.txt"
DF_REPORT="$SCAN_DIR/DF.txt"
CANDIDATES="$SCAN_DIR/project_candidates.txt"
PROTECTED="$SCAN_DIR/protected_live_files.txt"
CHECKSUMS="$SCAN_DIR/checksums.txt"
REFS="$SCAN_DIR/live_references.txt"

TEMP_COUNT=0
TEMP_BYTES=0
ROLLBACK_COUNT=0
ROLLBACK_BYTES=0
LEGACY_COUNT=0
LEGACY_BYTES=0
SD_REVIEW_COUNT=0
SD_REVIEW_BYTES=0

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

size_hint_bytes() {
    path=$1
    if [ -f "$path" ]; then
        n=$(wc -c < "$path" 2>/dev/null || echo 0)
        set -- $n
        printf '%s\n' "${1:-0}"
        return
    fi
    if [ -d "$path" ]; then
        line=$(du -sk "$path" 2>/dev/null | head -n 1 || true)
        set -- $line
        kb=${1:-0}
        case "$kb" in ''|*[!0-9]*) kb=0 ;; esac
        printf '%s\n' "$((kb * 1024))"
        return
    fi
    printf '%s\n' 0
}

record_candidate() {
    kind=$1
    reason=$2
    path=$3
    [ -e "$path" ] || return 0
    shown=$(display_path "$path")
    bytes=$(size_hint_bytes "$path")
    case "$bytes" in ''|*[!0-9]*) bytes=0 ;; esac

    case "$kind" in
      TEMP_CANDIDATE)
        TEMP_COUNT=$((TEMP_COUNT + 1))
        TEMP_BYTES=$((TEMP_BYTES + bytes))
        ;;
      ROLLBACK_REVIEW)
        ROLLBACK_COUNT=$((ROLLBACK_COUNT + 1))
        ROLLBACK_BYTES=$((ROLLBACK_BYTES + bytes))
        ;;
      LEGACY_REVIEW)
        LEGACY_COUNT=$((LEGACY_COUNT + 1))
        LEGACY_BYTES=$((LEGACY_BYTES + bytes))
        ;;
      SD_REVIEW)
        SD_REVIEW_COUNT=$((SD_REVIEW_COUNT + 1))
        SD_REVIEW_BYTES=$((SD_REVIEW_BYTES + bytes))
        ;;
    esac

    {
        echo "[$kind]"
        echo "path=$shown"
        echo "bytes_hint=$bytes"
        echo "reason=$reason"
        ls -ld "$path" 2>&1 || true
        if [ -f "$path" ]; then
            printf 'cksum='
            cksum < "$path" 2>/dev/null || echo unavailable
        fi
        echo
    } >> "$CANDIDATES"
}

record_protected() {
    reason=$1
    path=$2
    shown=$(display_path "$path")
    {
        echo "[PROTECTED_OR_LIVE]"
        echo "path=$shown"
        echo "reason=$reason"
        if [ -e "$path" ]; then
            ls -ld "$path" 2>&1 || true
            if [ -f "$path" ]; then
                printf 'cksum='
                cksum < "$path" 2>/dev/null || echo unavailable
            fi
        else
            echo "status=ABSENT"
        fi
        echo
    } >> "$PROTECTED"
}

capture_dir() {
    outfile=$1
    logical=$2
    recursive=$3
    path=$(p "$logical")
    {
        echo "PATH=$logical"
        if [ ! -e "$path" ]; then
            echo "STATUS=ABSENT"
        else
            echo "STATUS=PRESENT"
            echo "--- ls -ld ---"
            ls -ld "$path" 2>&1 || true
            echo "--- du -sk ---"
            du -sk "$path" 2>&1 || true
            echo "--- listing ---"
            if [ "$recursive" = 1 ]; then
                ls -laR "$path" 2>&1 || true
            else
                ls -la "$path" 2>&1 || true
            fi
        fi
    } > "$SCAN_DIR/$outfile" 2>&1
}

capture_sd_dir() {
    outfile=$1
    path=$2
    {
        echo "PATH=$path"
        if [ -z "$path" ] || [ ! -e "$path" ]; then
            echo "STATUS=ABSENT"
        else
            echo "STATUS=PRESENT"
            du -sk "$path" 2>&1 || true
            ls -laR "$path" 2>&1 || true
        fi
    } > "$SCAN_DIR/$outfile" 2>&1
}

{
    echo "READ_ONLY_SCAN=YES"
    echo "DELETE_PERFORMED=NO"
    echo "OUTPUT_STORAGE=$OUTPUT_STORAGE"
    echo "REPORT_DIR=$SCAN_DIR"
    echo "SD_VOLUME=${VOLUME:-ABSENT}"
    echo "START_TIME=$STAMP"
} >> "$SUMMARY"

{
    echo "=== /mnt/system ==="
    df -k "$(p /mnt/system)" 2>/dev/null || df "$(p /mnt/system)" 2>/dev/null || true
    echo
    echo "=== /mnt/app ==="
    df -k "$(p /mnt/app)" 2>/dev/null || df "$(p /mnt/app)" 2>/dev/null || true
    echo
    echo "=== /tmp ==="
    df -k "$(p /tmp)" 2>/dev/null || df "$(p /tmp)" 2>/dev/null || true
    if [ -n "$VOLUME" ] && [ -d "$VOLUME" ]; then
        echo
        echo "=== SD ==="
        df -k "$VOLUME" 2>/dev/null || df "$VOLUME" 2>/dev/null || true
    fi
} > "$DF_REPORT" 2>&1

capture_dir system_boot.txt /mnt/system/etc/boot 0
capture_dir alternate_etc_boot.txt /etc/boot 0
capture_dir system_production.txt /mnt/system/etc/eso/production 0
capture_dir system_etc.txt /mnt/system/etc 0
capture_dir app_root.txt /mnt/app/root 0
capture_dir app_carplay_altscreen.txt /mnt/app/root/carplay-altscreen 1
capture_dir app_hooks.txt /mnt/app/root/hooks 0
capture_dir app_lib_target.txt /mnt/app/root/lib-target 0
capture_dir hmi_jars.txt /mnt/app/eso/hmi/lsd/jars 0
capture_dir tmp_runtime.txt /tmp/MMI-Cockpit-Carplay 1

if [ -n "$VOLUME" ]; then
    capture_sd_dir sd_state.txt "$VOLUME/MMI-Cockpit-Carplay/state"
    capture_sd_dir sd_backup.txt "$VOLUME/MMI-Cockpit-Carplay/backup"
    capture_sd_dir sd_staging.txt "$VOLUME/MMI-Cockpit-Carplay/staging"
else
    capture_sd_dir sd_state.txt ""
    capture_sd_dir sd_backup.txt ""
    capture_sd_dir sd_staging.txt ""
fi

: > "$CANDIDATES"
: > "$PROTECTED"
: > "$CHECKSUMS"
: > "$REFS"

BOOT=$(p /mnt/system/etc/boot)
ALT_BOOT=$(p /etc/boot)
PROD=$(p /mnt/system/etc/eso/production)
SYS_ETC=$(p /mnt/system/etc)
APP_ROOT=$(p /mnt/app/root)
RUNTIME=$(p /mnt/app/root/carplay-altscreen)
HOOKS=$(p /mnt/app/root/hooks)
LEGACY_LIBTARGET=$(p /mnt/app/root/lib-target)
HMI_JARS=$(p /mnt/app/eso/hmi/lsd/jars)

# Classify startup transaction residue only from the canonical persistent
# /mnt/system path. /etc/boot is still listed above for diagnostics, but on MHI2Q
# it may alias the same files and must not double-count candidates.
for path in \
    "$BOOT"/startup.sh.basevideo3.* \
    "$BOOT"/startup.sh.mirror.* \
    "$BOOT"/.startup.sh.new.* \
    "$BOOT"/.startup.sh.altscreen.new.*; do
    record_candidate TEMP_CANDIDATE historical_startup_transaction "$path"
done

for path in \
    "$PROD"/.smartphone_integrator.json.new.* \
    "$PROD"/.dio_manager.json.new.*; do
    record_candidate TEMP_CANDIDATE historical_atomic_publish "$path"
done

for path in \
    "$SYS_ETC"/.pf.conf.new.* \
    "$SYS_ETC"/.pf.conf.altscreen.new.*; do
    record_candidate TEMP_CANDIDATE historical_firewall_publish "$path"
done

for path in \
    "$APP_ROOT"/.carplay-altscreen.new \
    "$APP_ROOT"/.carplay-altscreen.new.* \
    "$APP_ROOT"/.altscreen-write-test \
    "$APP_ROOT"/.altscreen-write-test.*; do
    record_candidate TEMP_CANDIDATE historical_runtime_staging "$path"
done

for path in \
    "$RUNTIME"/lib/.*.new.* \
    "$HOOKS"/.*.new.* \
    "$LEGACY_LIBTARGET"/.*.new.*; do
    record_candidate TEMP_CANDIDATE historical_runtime_atomic_publish "$path"
done

for path in \
    "$HMI_JARS"/carplay_hook.jar.basevideo3.tmp \
    "$HMI_JARS"/carplay_hook.jar.basevideo3.restore.tmp; do
    record_candidate TEMP_CANDIDATE historical_hmi_jar_transaction "$path"
done

record_candidate ROLLBACK_REVIEW previous_runtime_rollback "$APP_ROOT/.carplay-altscreen.previous"
record_candidate ROLLBACK_REVIEW previous_mirror_rollback "$RUNTIME/tmp/mirror.previous"

record_candidate LEGACY_REVIEW legacy_fullchain_probe "$HOOKS/.mibcarplay_fullchain_probe"
record_candidate LEGACY_REVIEW legacy_altscreen_hook "$HOOKS/libcarplay_altscreen.so"
record_candidate LEGACY_REVIEW legacy_carplay_hook "$HOOKS/libcarplay_hook.so"
record_candidate LEGACY_REVIEW legacy_mirror_hook "$HOOKS/libcp_mirror.so"

if [ -n "$VOLUME" ]; then
    STATE="$VOLUME/MMI-Cockpit-Carplay/state"
    STAGING="$VOLUME/MMI-Cockpit-Carplay/staging"
    BACKUP="$VOLUME/MMI-Cockpit-Carplay/backup"
    for path in \
        "$STATE"/.child-install.* \
        "$STATE"/universal-config.* \
        "$STATE"/config.libpath \
        "$STATE"/config.stage1 \
        "$STATE"/config.stage2 \
        "$STATE"/pf.clean \
        "$STATE"/pf.clean.* \
        "$STATE"/boot.clean \
        "$STATE"/boot.block \
        "$STATE"/boot.new \
        "$STATE"/boot.restore \
        "$STATE"/diag.clean.* \
        "$STATE"/diag.block.* \
        "$STATE"/diag.new.* \
        "$STATE"/diag.restore.* \
        "$STAGING"/* \
        "$BACKUP"/*.new.* \
        "$BACKUP"/*/*.new.*; do
        record_candidate SD_REVIEW historical_sd_transaction "$path"
    done

    record_candidate SD_REVIEW operation_lock_review "$STATE/.chain_test.lock"

    {
        echo "PATH=$STATE/.chain_test.lock"
        if [ -d "$STATE/.chain_test.lock" ]; then
            echo "STATUS=PRESENT_REVIEW_REQUIRED"
            for field in owner pid boot action; do
                if [ -f "$STATE/.chain_test.lock/$field" ]; then
                    printf '%s=' "$field"
                    cat "$STATE/.chain_test.lock/$field" 2>/dev/null || true
                else
                    echo "$field=ABSENT"
                fi
            done
        else
            echo "STATUS=ABSENT"
        fi
    } > "$SCAN_DIR/operation_lock.txt" 2>&1
fi

record_protected live_boot_script "$(p /mnt/system/etc/boot/startup.sh)"
record_protected live_carplay_environment "$(p /mnt/system/etc/eso/production/smartphone_integrator.json)"
record_protected live_dio_environment "$(p /mnt/system/etc/eso/production/dio_manager.json)"
record_protected live_firewall_config "$(p /mnt/system/etc/pf.conf)"
record_protected live_hmi_jar "$(p /mnt/app/eso/hmi/lsd/jars/carplay_hook.jar)"
record_protected alternate_live_boot_script "$(p /etc/boot/startup.sh)"
record_protected current_runtime "$(p /mnt/app/root/carplay-altscreen)"
record_protected persistent_boot_demand "$(p /mnt/app/root/carplay-altscreen/state/basevideo3.enabled)"
record_protected persistent_diagnostics_demand "$(p /mnt/app/root/carplay-altscreen/state/diagnostics.enabled)"
record_protected current_fullchain_probe "$(p /mnt/app/root/carplay-altscreen/state/fullchain_probe)"
record_protected legacy_overlay_directory "$(p /mnt/app/root/lib-target)"
record_protected legacy_hooks_directory "$(p /mnt/app/root/hooks)"

for logical in \
    /mnt/system/etc/boot/startup.sh \
    /mnt/system/etc/eso/production/smartphone_integrator.json \
    /mnt/system/etc/eso/production/dio_manager.json \
    /mnt/system/etc/pf.conf \
    /mnt/app/eso/hmi/lsd/jars/carplay_hook.jar \
    /mnt/app/root/carplay-altscreen/lib/libcarplay_altscreen.so; do
    path=$(p "$logical")
    if [ -f "$path" ]; then
        printf '%s ' "$logical" >> "$CHECKSUMS"
        cksum < "$path" >> "$CHECKSUMS" 2>/dev/null || echo unavailable >> "$CHECKSUMS"
    else
        echo "$logical ABSENT" >> "$CHECKSUMS"
    fi
done

for logical in \
    /mnt/system/etc/boot/startup.sh \
    /mnt/system/etc/eso/production/smartphone_integrator.json \
    /mnt/system/etc/eso/production/dio_manager.json \
    /mnt/system/etc/pf.conf; do
    path=$(p "$logical")
    [ -f "$path" ] || continue
    echo "=== $logical ===" >> "$REFS"
    grep -n 'carplay-altscreen' "$path" >> "$REFS" 2>/dev/null || true
    grep -n 'libcarplay_altscreen' "$path" >> "$REFS" 2>/dev/null || true
    grep -n 'libcarplay_hook' "$path" >> "$REFS" 2>/dev/null || true
    grep -n 'libcp_mirror' "$path" >> "$REFS" 2>/dev/null || true
    grep -n 'ALTSCREEN' "$path" >> "$REFS" 2>/dev/null || true
    grep -n 'BASEVIDEO3' "$path" >> "$REFS" 2>/dev/null || true
    grep -n 'MMI-Cockpit-Carplay' "$path" >> "$REFS" 2>/dev/null || true
    echo >> "$REFS"
done

{
    echo "TEMP_CANDIDATE_COUNT=$TEMP_COUNT"
    echo "TEMP_CANDIDATE_BYTES_HINT=$TEMP_BYTES"
    echo "ROLLBACK_REVIEW_COUNT=$ROLLBACK_COUNT"
    echo "ROLLBACK_REVIEW_BYTES_HINT=$ROLLBACK_BYTES"
    echo "LEGACY_REVIEW_COUNT=$LEGACY_COUNT"
    echo "LEGACY_REVIEW_BYTES_HINT=$LEGACY_BYTES"
    echo "SD_REVIEW_COUNT=$SD_REVIEW_COUNT"
    echo "SD_REVIEW_BYTES_HINT=$SD_REVIEW_BYTES"
    echo "CLASSIFICATION=SCAN_ONLY_NOT_DELETE_AUTHORITY"
    echo "SCAN_COMPLETE=YES"
} >> "$SUMMARY"

printf '%s\n' "$SCAN_DIR" > "$REPORT_ROOT/LAST_SCAN.txt" 2>/dev/null || true
printf '%s\n' "SCAN_COMPLETE=YES" > "$SCAN_DIR/SCAN_COMPLETE"

echo "STORAGE_RECOVERY_SCAN=PASS"
echo "READ_ONLY_SCAN=YES"
echo "DELETE_PERFORMED=NO"
echo "OUTPUT_STORAGE=$OUTPUT_STORAGE"
echo "REPORT_DIR=$SCAN_DIR"
echo "TEMP_CANDIDATE_COUNT=$TEMP_COUNT"
echo "ROLLBACK_REVIEW_COUNT=$ROLLBACK_COUNT"
echo "LEGACY_REVIEW_COUNT=$LEGACY_COUNT"
echo "SD_REVIEW_COUNT=$SD_REVIEW_COUNT"
echo "NEXT_STEP=review_report_before_any_cleanup"
