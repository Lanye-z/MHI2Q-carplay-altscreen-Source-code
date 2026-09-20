#!/bin/sh
# Minimal, payload-free Universal resolver recorder.
# Runs from the boot diagnostics block and writes filtered compatibility verdicts
# straight to the test SD card. It does not depend on STORE, local /tmp
# subdirectories, or the optional full-stream log encryptor.
set -u

# QNX compatibility: some vehicle mkdir implementations return EEXIST for
# `mkdir -p` when the final directory already exists. Idempotent directory
# creation must therefore test first; lock acquisition still uses bare mkdir.
ensure_dirs() {
    for dir in "$@"; do
        [ -d "$dir" ] && continue
        mkdir -p "$dir" || return 1
    done
    return 0
}
PATH=${PATH:-/bin:/usr/bin}:/proc/boot:/armle/bin:/armle/scripts:/bin:/usr/bin:/usr/sbin:/sbin:/mnt/app/armle/bin:/eso/bin:/eso/bin/apps
export PATH

ROOT=""
INTERVAL=1
if [ "${ALTSCREEN_CHAIN_TESTING:-0}" = 1 ]; then
    ROOT=${ALTSCREEN_CHAIN_ROOT:-}
    case "$ROOT" in /tmp/*|/var/tmp/*) ;; *) exit 2 ;; esac
    INTERVAL=${ALTS_DIAG_INTERVAL:-0.05}
fi
ENABLED="$ROOT/mnt/app/root/carplay-altscreen/state/diagnostics.enabled"
SOURCE=""
OFFSET=0
INODE=""
DEST=""
VOLUME=""
TMP_DEST="$ROOT/tmp/MMI-Cockpit-Carplay/adaptive.log"
[ -d "$ROOT/tmp/MMI-Cockpit-Carplay" ] || TMP_DEST="$ROOT/tmp/MMI-Cockpit-Carplay.adaptive.log"
SD_DEST=""
SD_DEST_VOLUME=""

select_hook_source() {
    latest=$(ls -t \
        "$VOLUME/MMI-Cockpit-Carplay/logs/altscreen_hook.log" \
        "$ROOT/tmp/MMI-Cockpit-Carplay/altscreen_hook.log" \
        "$ROOT/tmp/MMI-Cockpit-Carplay.altscreen_hook.log" \
        "$ROOT/tmp/altscreen_hook.log" 2>/dev/null | head -n 1)
    printf '%s\n' "${latest:-$ROOT/tmp/MMI-Cockpit-Carplay/altscreen_hook.log}"
}

find_volume() {
    VOLUME=""
    if [ "${ALTSCREEN_CHAIN_TESTING:-0}" = 1 ]; then
        candidate=${ALTSCREEN_CHAIN_VOLUME:-}
        [ -n "$candidate" ] && [ -d "$candidate/Toolbox" ] && [ -d "$candidate/MMI-Cockpit-Carplay/state" ] && VOLUME=$candidate
    else
        for candidate in /net/mmx/fs/sda0 /net/mmx/fs/sda1 /net/mmx/fs/sdb0 /net/mmx/fs/sdb1 /fs/sda0 /fs/sda1 /fs/sdb0 /fs/sdb1; do
            if [ -d "$candidate/Toolbox" ] && [ -d "$candidate/MMI-Cockpit-Carplay/state" ]; then
                VOLUME=$candidate
                break
            fi
        done
    fi
    [ -n "$VOLUME" ]
}

init_dest() {
    find_volume || VOLUME=""
    DEST="$TMP_DEST"
    if [ -n "$VOLUME" ]; then
        if [ "$SD_DEST_VOLUME" != "$VOLUME" ]; then SD_DEST=""; SD_DEST_VOLUME=$VOLUME; fi
        [ "${ALTSCREEN_CHAIN_TESTING:-0}" = 1 ] || mount -uw "$VOLUME" >/dev/null 2>&1 || true
        dir="$VOLUME/MMI-Cockpit-Carplay/logs/adaptive"
        if ensure_dirs "$dir" 2>/dev/null; then
            [ -n "$SD_DEST" ] || SD_DEST="$dir/adaptive_$(date +%Y%m%d_%H%M%S)_$$.log"
            if ( : >> "$SD_DEST" ) 2>/dev/null; then DEST=$SD_DEST; fi
        fi
    fi
    [ -s "$DEST" ] && return 0
    profile=$(cat "$VOLUME/MMI-Cockpit-Carplay/state/firmware_profile.txt" 2>/dev/null || echo UNKNOWN)
    train=""
    for rel in /net/rcc/dev/shmem/version.txt /dev/shmem/version.txt /net/mmx/dev/shmem/version.txt; do
        path="$ROOT$rel"
        [ -r "$path" ] || continue
        train=$(sed -n '/Current train/p' "$path" | head -n 1)
        [ -n "$train" ] && break
    done
    printf '%s ADAPTIVE_FAILSAFE_BEGIN profile=%s train=%s source=altscreen_hook.log payload_filter=STATUS_ONLY store_required=NO\n' \
        "$(date +%Y%m%d_%H%M%S)" "$profile" "${train:-UNKNOWN}" > "$DEST" 2>/dev/null || { DEST=""; return 1; }
    for rel in /eso/lib/libairplay.so /eso/bin/apps/dio_manager /mnt/app/eso/bin/apps/dio_manager /armle/usr/lib/libNmeBaseClasses.so /mnt/app/armle/usr/lib/libNmeBaseClasses.so; do
        path="$ROOT$rel"
        [ -f "$path" ] || continue
        facts=$(cksum < "$path" 2>/dev/null || true)
        [ -n "$facts" ] && printf '%s ADAPTIVE_BINARY path=%s cksum=%s\n' "$(date +%Y%m%d_%H%M%S)" "$rel" "$facts" >> "$DEST"
    done
    return 0
}

copy_delta() {
    init_dest || return 0
    SOURCE=$(select_hook_source)
    [ -f "$SOURCE" ] || return 0
    if [ -f "$DEST" ] && [ "$(wc -c < "$DEST")" -ge 4194304 ]; then
        : > "$DEST" 2>/dev/null || DEST="$TMP_DEST"
    fi
    size=$(wc -c < "$SOURCE" 2>/dev/null || echo 0)
    inode=$(ls -i "$SOURCE" 2>/dev/null | awk '{print $1}')
    case "$size" in ''|*[!0-9]*) return 0 ;; esac
    if [ "$OFFSET" -gt "$size" ] || { [ -n "$INODE" ] && [ -n "$inode" ] && [ "$INODE" != "$inode" ]; }; then
        printf '%s ADAPTIVE_SOURCE_RESET previous_offset=%s size=%s previous_inode=%s inode=%s\n' \
            "$(date +%Y%m%d_%H%M%S)" "$OFFSET" "$size" "$INODE" "$inode" >> "$DEST" 2>/dev/null || true
        OFFSET=0
    fi
    if [ "$size" -gt "$OFFSET" ]; then
        # No temporary file is required: tail/awk stream directly into the SD
        # status log. Only our own phase/gate records are eligible.
        tail -c "+$((OFFSET + 1))" "$SOURCE" 2>/dev/null | awk '
          /PHASE=AUG22_DYNAMIC_RESOLVER/ ||
          /PHASE=STOCK_INTERNAL_REDIRECT/ ||
          /PHASE=RUNTIME_PROCESS_IDENTITY/ ||
          /PHASE=RUNTIME_SYMBOL_RESOLUTION/ ||
          /PHASE=RUNTIME_PREREQUISITES/ ||
          /PHASE=RUNTIME_ABI_IDENTITY/ ||
          /PHASE=RUNTIME_FORWARDING_GATE/ ||
          /PHASE=PRIVATE111_BACKEND_INSTALL_RESULT/ ||
          /PHASE=RUNTIME_GEOMETRY_GATE/ ||
          /RUNTIME ready / { print }
        ' >> "$DEST" 2>/dev/null || {
            DEST=$TMP_DEST
            tail -c "+$((OFFSET + 1))" "$SOURCE" 2>/dev/null | awk '
              /PHASE=AUG22_DYNAMIC_RESOLVER/ || /PHASE=STOCK_INTERNAL_REDIRECT/ ||
              /PHASE=RUNTIME_PROCESS_IDENTITY/ || /PHASE=RUNTIME_SYMBOL_RESOLUTION/ ||
              /PHASE=RUNTIME_PREREQUISITES/ || /PHASE=RUNTIME_ABI_IDENTITY/ ||
              /PHASE=RUNTIME_FORWARDING_GATE/ || /PHASE=PRIVATE111_BACKEND_INSTALL_RESULT/ ||
              /PHASE=RUNTIME_GEOMETRY_GATE/ || /RUNTIME ready / { print }
            ' >> "$DEST" 2>/dev/null || return 0
        }
        OFFSET=$size
    fi
    INODE=$inode
    [ -z "$VOLUME" ] || /bin/sh "${0%/*}/altscreen_log_ring.sh" prune 2>/dev/null || true
}

[ -f "$ENABLED" ] || exit 0
while [ -f "$ENABLED" ]; do
    copy_delta
    sleep "$INTERVAL" || exit 0
done
copy_delta
exit 0
