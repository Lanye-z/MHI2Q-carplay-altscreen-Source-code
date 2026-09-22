#!/bin/sh
# MMI-Cockpit-Carplay GEM STORE LOGS + RESTORE action.
# Log collection is best effort; integrated restore (AltScreen + Mirror) always
# follows and its exit status is the visible GEM result.

ensure_dirs() {
    for dir in "$@"; do
        [ -d "$dir" ] && continue
        mkdir -p "$dir" || return 1
    done
    return 0
}

# Capture collection + restore as one persistent SD operation log.  The generic
# ALTS_OPLOG_CAPTURED marker is inherited by RESTORE ORIGINAL so the nested
# launcher does not create a second, partial log.
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
        journal_base="$journal_dir/store_restore_${journal_stamp}"
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
        journal="$journal_root/tmp/altscreen_store_restore_${journal_stamp}.log"
    fi

    if ! (printf 'OP_BEGIN action=STORE_LOGS_RESTORE script=%s storage=%s\n' "$CAPTURE_ENTRY" "$journal_storage" > "$journal") 2>/dev/null; then
        if [ "$journal_storage" = SD ]; then
            journal_storage=TMP
            journal_root=""
            if [ "${ALTSCREEN_CHAIN_TESTING:-0}" = 1 ]; then journal_root=${ALTSCREEN_CHAIN_ROOT:-}; fi
            journal="$journal_root/tmp/altscreen_store_restore_${journal_stamp}.log"
            (printf 'OP_BEGIN action=STORE_LOGS_RESTORE script=%s storage=%s\n' "$CAPTURE_ENTRY" "$journal_storage" > "$journal") 2>/dev/null || {
                echo "WARN: STORE LOGS + RESTORE journal unavailable on SD and /tmp; restore will continue unjournaled"
                ALTS_OPLOG_CAPTURED=1; export ALTS_OPLOG_CAPTURED
                if [ "$#" -gt 0 ]; then exec /bin/sh "$CAPTURE_ENTRY" "$@"; else exec /bin/sh "$CAPTURE_ENTRY"; fi
            }
            printf 'STORE_RESTORE_JOURNAL_FALLBACK=TMP reason=sd_write_failed\n' >> "$journal"
        else
            echo "WARN: STORE LOGS + RESTORE journal unavailable on /tmp; restore will continue unjournaled"
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
    printf 'OP_END action=STORE_LOGS_RESTORE rc=%s\n' "$journal_rc" >> "$journal"
    printf 'OPERATION_LOG=%s\n' "$journal" >> "$journal"

    if [ "$journal_storage" = TMP ]; then
        target_dir="$journal_volume/MMI-Cockpit-Carplay/logs/operations"
        if ensure_dirs "$target_dir" 2>/dev/null; then
            target="$target_dir/store_restore_${journal_stamp}_recovered.log"
            cp "$journal" "$target.new" 2>/dev/null &&
                mv "$target.new" "$target" 2>/dev/null &&
                printf 'STORE_RESTORE_JOURNAL_FLUSHED_TO_SD=%s\n' "$target" >> "$journal" ||
                rm -f "$target.new" 2>/dev/null || true
        fi
    fi
    sync >/dev/null 2>&1 || true
    # STORE LOGS + RESTORE may contain large collected streams. Keep the full
    # record on SD while replaying only the tail to the GEM console.
    echo "OPERATION_LOG=$journal"
    tail -c 262144 "$journal" 2>/dev/null || cat "$journal"
    exit "$journal_rc"
fi

BASE="$0"
RESOLVED=$(command -v -- "$BASE" 2>/dev/null)
[ -n "$RESOLVED" ] || RESOLVED="$BASE"
SCRIPTDIR=$(cd -P -- "$(dirname -- "$RESOLVED")" 2>/dev/null && pwd -P)
[ -n "$SCRIPTDIR" ] || { echo "FAIL: cannot resolve installed launcher directory"; exit 126; }

TESTING=${ALTSCREEN_CHAIN_TESTING:-0}
DEVICE_ROOT=""
if [ "$TESTING" = 1 ]; then
    DEVICE_ROOT=${ALTSCREEN_CHAIN_ROOT:-}
    case "$DEVICE_ROOT" in /tmp/*|/var/tmp/*) ;; *) echo "FAIL: invalid ALTSCREEN_CHAIN_ROOT"; exit 2 ;; esac
fi
APP_BIN="$DEVICE_ROOT/mnt/app/root/carplay-altscreen/bin"
APP_SELF="$APP_BIN/finish_mmi_cockpit_carplay_test.sh"
# ALTSCREEN_FAKE_RECORD belongs only to the host dispatcher contract test.
# Production always forwards from a legacy /eso GEM bootstrap to the owned
# /mnt/app runtime when that runtime exists.
if { [ "$TESTING" != 1 ] || [ -z "${ALTSCREEN_FAKE_RECORD:-}" ]; } &&
   [ "$SCRIPTDIR" != "$APP_BIN" ] && [ -f "$APP_SELF" ] &&
   [ -f "$APP_BIN/altscreen_chain_test.sh" ]; then
    echo "APP_RUNTIME_FORWARD action=STORE_RESTORE from=$SCRIPTDIR to=/mnt/app/root/carplay-altscreen/bin"
    if [ "$#" -gt 0 ]; then
        exec /bin/sh "$APP_SELF" "$@"
    else
        exec /bin/sh "$APP_SELF"
    fi
fi

CONTROLLER="$SCRIPTDIR/altscreen_chain_test.sh"
RESTORE="$SCRIPTDIR/stop_mmi_cockpit_carplay_test.sh"
[ -f "$CONTROLLER" ] || { echo "FAIL: installed chain controller is missing: $CONTROLLER"; exit 127; }
[ -f "$RESTORE" ] || { echo "FAIL: integrated restore launcher is missing: $RESTORE"; exit 127; }

/bin/sh "$CONTROLLER" collect
COLLECT_RC=$?
if [ "$COLLECT_RC" -eq 0 ]; then
    echo "log collection complete"
else
    echo "WARN: log collection incomplete (status $COLLECT_RC); restoring originals anyway"
fi

exec /bin/sh "$RESTORE"
