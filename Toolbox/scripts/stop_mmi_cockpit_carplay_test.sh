#!/bin/sh
# V3 RESTORE ORIGINAL entry point.
# All persistent mutations are delegated to the SD-resident transactional
# orchestrator so recovery still works when /mnt/app runtime is partial/missing.
set -u

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
