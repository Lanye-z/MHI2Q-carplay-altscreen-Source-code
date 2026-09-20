#!/bin/sh
set -u

VOLUME=""
for candidate in /net/mmx/fs/sda0 /net/mmx/fs/sda1 /net/mmx/fs/sdb0 /net/mmx/fs/sdb1 /fs/sda0 /fs/sda1 /fs/sdb0 /fs/sdb1; do
    if [ -d "$candidate/Toolbox" ]; then
        VOLUME=$candidate
        break
    fi
done

BIN="/mnt/app/root/oem-plane-census/bin/oem-plane-census"
[ -x "$BIN" ] && echo "OBSERVER_BINARY=INSTALLED" || echo "OBSERVER_BINARY=NOT_INSTALLED"
echo "OBSERVER_MODE=READ_ONLY"
echo "CARPLAY_START=NOT_USED"
echo "TARGETS=ID_STRING_33,58"

if [ -n "$VOLUME" ]; then
    LOG="$VOLUME/MMI-Cockpit-Carplay/logs/oem-plane-census/plane33-58-census.log"
    echo "LOG=$LOG"
    if [ -f "$LOG" ]; then
        for label in Classic_Full Classic_Small Sport_Full Sport_Small; do
            N="$(grep -c "CENSUS_BEGIN schema=OEM_PLANE33_58_CENSUS_V1_1 label=$label " "$LOG" 2>/dev/null || true)"
            case "$N" in ''|*[!0-9]*) N=0 ;; esac
            echo "$label=$N"
        done
        echo "LAST_CENSUS_BEGIN"
        tail -n 160 "$LOG" 2>/dev/null || true
        echo "LAST_CENSUS_END"
    else
        echo "CENSUS_LOG=NOT_YET_CREATED"
    fi
else
    echo "SD_CARD=NOT_FOUND"
fi
