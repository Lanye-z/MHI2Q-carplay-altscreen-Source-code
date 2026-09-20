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
STATE="/tmp/oem-plane-census"
PIDFILE="$STATE/pid"

[ -x "$BIN" ] && echo "OBSERVER_BINARY=INSTALLED" || echo "OBSERVER_BINARY=NOT_INSTALLED"
echo "OBSERVER_MODE=READ_ONLY"
echo "EVENT_SOURCE=WINDOW_MANAGER_CONTEXT"
echo "CARPLAY_START=NOT_USED"
echo "TARGETS=ID_STRING_33,58"

RUNNING=0
PID=""
if [ -f "$PIDFILE" ]; then
    PID="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then RUNNING=1; fi
fi
[ "$RUNNING" -eq 1 ] && echo "OBSERVER_PROCESS=RUNNING pid=$PID" || echo "OBSERVER_PROCESS=NOT_RUNNING"
[ -f "$STATE/READY" ] && echo "OBSERVER_READY=YES" || echo "OBSERVER_READY=NO"

for id in 33 58; do
    SRC="$STATE/window${id}.state"
    if [ -f "$SRC" ]; then
        echo "LATEST_TARGET_BEGIN id=$id"
        cat "$SRC"
        echo "LATEST_TARGET_END id=$id"
    else
        echo "LATEST_TARGET id=$id state=NOT_YET_OBSERVED"
    fi
done

if [ -f "$STATE/observer.log" ]; then
    echo "OBSERVER_LOG_TAIL_BEGIN"
    tail -n 80 "$STATE/observer.log" 2>/dev/null || true
    echo "OBSERVER_LOG_TAIL_END"
fi

if [ -n "$VOLUME" ]; then
    LOG="$VOLUME/MMI-Cockpit-Carplay/logs/oem-plane-census/plane33-58-census.log"
    echo "LOG=$LOG"
    if [ -f "$LOG" ]; then
        for label in Classic_Full Classic_Small Sport_Full Sport_Small; do
            N="$(grep -c "CENSUS_BEGIN schema=OEM_PLANE33_58_CENSUS_V1_1 label=$label " "$LOG" 2>/dev/null || true)"
            case "$N" in ''|*[!0-9]*) N=0 ;; esac
            echo "$label=$N"
        done
    else
        echo "CENSUS_LOG=NOT_YET_CREATED"
    fi
else
    echo "SD_CARD=NOT_FOUND"
fi
