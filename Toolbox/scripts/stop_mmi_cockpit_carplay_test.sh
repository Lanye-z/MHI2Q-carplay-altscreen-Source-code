#!/bin/sh
# V3 RESTORE ORIGINAL entry point.
# All persistent mutations are delegated to the SD-resident transactional
# orchestrator so recovery still works when /mnt/app runtime is partial/missing.
set -u

ensure_dirs() {
    for dir in "$@"; do
        [ -d "$dir" ] && continue
        mkdir -p "$dir" || return 1
    done
    return 0
}

# Persist the complete RESTORE ORIGINAL transaction on the active SD card before
# any restore mutation starts.  STORE LOGS + RESTORE sets ALTS_OPLOG_CAPTURED
# itself, so direct RESTORE gets one log while the combined action gets one
# outer log rather than nested duplicates.
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
        echo "RESTORE=REFUSED reason=SD_WITH_TOOLBOX_NOT_FOUND production_changed=NO"
        exit 1
    }

    journal_stamp=$(date +%Y%m%d_%H%M%S 2>/dev/null || echo unknown)
    journal_dir="$journal_volume/MMI-Cockpit-Carplay/logs/operations"
    journal_storage=SD
    if ensure_dirs "$journal_dir" 2>/dev/null; then
        journal_base="$journal_dir/restore_${journal_stamp}"
        journal="$journal_base.log"
        journal_n=0
        while [ -e "$journal" ]; do
            journal_n=$((journal_n + 1))
            journal="${journal_base}_${journal_n}.log"
        done
    else
        journal_storage=TMP
        journal_root=""
        if [ "${ALTSCREEN_CHAIN_TESTING:-0}" = 1 ]; then journal_root=${ALTSCREEN_CHAIN_ROOT:-}; fi
        journal="$journal_root/tmp/altscreen_restore_${journal_stamp}.log"
    fi

    if ! (printf 'OP_BEGIN action=RESTORE_ORIGINAL script=%s storage=%s\n' "$CAPTURE_ENTRY" "$journal_storage" > "$journal") 2>/dev/null; then
        if [ "$journal_storage" = SD ]; then
            journal_storage=TMP
            journal_root=""
            if [ "${ALTSCREEN_CHAIN_TESTING:-0}" = 1 ]; then journal_root=${ALTSCREEN_CHAIN_ROOT:-}; fi
            journal="$journal_root/tmp/altscreen_restore_${journal_stamp}.log"
            (printf 'OP_BEGIN action=RESTORE_ORIGINAL script=%s storage=%s\n' "$CAPTURE_ENTRY" "$journal_storage" > "$journal") 2>/dev/null || {
                echo "WARN: RESTORE operation journal unavailable on SD and /tmp; recovery will continue unjournaled"
                ALTS_OPLOG_CAPTURED=1; export ALTS_OPLOG_CAPTURED
                if [ "$#" -gt 0 ]; then exec /bin/sh "$CAPTURE_ENTRY" "$@"; else exec /bin/sh "$CAPTURE_ENTRY"; fi
            }
            printf 'RESTORE_JOURNAL_FALLBACK=TMP reason=sd_write_failed\n' >> "$journal"
        else
            echo "WARN: RESTORE operation journal unavailable on /tmp; recovery will continue unjournaled"
            ALTS_OPLOG_CAPTURED=1; export ALTS_OPLOG_CAPTURED
            if [ "$#" -gt 0 ]; then exec /bin/sh "$CAPTURE_ENTRY" "$@"; else exec /bin/sh "$CAPTURE_ENTRY"; fi
        fi
    fi
    printf 'DIAGNOSTICS_VOLUME=%s\n' "$journal_volume" >> "$journal"

    if [ "$#" -gt 0 ]; then
        ALTS_OPLOG_CAPTURED=1 /bin/sh "$CAPTURE_ENTRY" "$@" >> "$journal" 2>&1
    else
        ALTS_OPLOG_CAPTURED=1 /bin/sh "$CAPTURE_ENTRY" >> "$journal" 2>&1
    fi
    journal_rc=$?
    printf 'OP_END action=RESTORE_ORIGINAL rc=%s\n' "$journal_rc" >> "$journal"
    printf 'OPERATION_LOG=%s\n' "$journal" >> "$journal"

    if [ "$journal_storage" = TMP ]; then
        target_dir="$journal_volume/MMI-Cockpit-Carplay/logs/operations"
        if ensure_dirs "$target_dir" 2>/dev/null; then
            target="$target_dir/restore_${journal_stamp}_recovered.log"
            cp "$journal" "$target.new" 2>/dev/null &&
                mv "$target.new" "$target" 2>/dev/null &&
                printf 'RESTORE_JOURNAL_FLUSHED_TO_SD=%s\n' "$target" >> "$journal" ||
                rm -f "$target.new" 2>/dev/null || true
        fi
    fi
    sync >/dev/null 2>&1 || true
    cat "$journal"
    exit "$journal_rc"
fi

TESTING=${ALTSCREEN_CHAIN_TESTING:-0}
VOLUME=""
if [ "$TESTING" = 1 ]; then
    VOLUME=${ALTSCREEN_CHAIN_VOLUME:-}
    case "$VOLUME" in /tmp/*|/var/tmp/*) ;; *) echo "FAIL: invalid ALTSCREEN_CHAIN_VOLUME" >&2; exit 2 ;; esac
else
    for candidate in /net/mmx/fs/sda0 /net/mmx/fs/sda1 /net/mmx/fs/sdb0 /net/mmx/fs/sdb1 /fs/sda0 /fs/sda1 /fs/sdb0 /fs/sdb1; do
        if [ -d "$candidate/Toolbox" ]; then
            VOLUME=$candidate
            break
        fi
    done
fi

[ -n "$VOLUME" ] || {
    echo "RESTORE=REFUSED reason=SD_WITH_TOOLBOX_NOT_FOUND production_changed=NO"
    exit 1
}

TXN="$VOLUME/Toolbox/scripts/altscreen_restore_transaction.sh"
[ -f "$TXN" ] || {
    echo "RESTORE=REFUSED reason=TRANSACTIONAL_RESTORE_SCRIPT_MISSING production_changed=NO"
    exit 127
}

echo "RESTORE_ENTRY=TRANSACTIONAL_V3 source=$TXN"
if [ "$#" -gt 0 ]; then
    exec /bin/sh "$TXN" "$@"
else
    exec /bin/sh "$TXN"
fi
