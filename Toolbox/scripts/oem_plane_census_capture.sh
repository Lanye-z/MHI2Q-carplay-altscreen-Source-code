#!/bin/sh
set -u

LABEL="${1:-}"
case "$LABEL" in
    Classic_Full|Classic_Small|Sport_Full|Sport_Small) ;;
    *) echo "FAIL: invalid label '$LABEL'"; exit 64 ;;
esac

VOLUME=""
for candidate in /net/mmx/fs/sda0 /net/mmx/fs/sda1 /net/mmx/fs/sdb0 /net/mmx/fs/sdb1 /fs/sda0 /fs/sda1 /fs/sdb0 /fs/sdb1; do
    if [ -d "$candidate/Toolbox" ]; then
        VOLUME=$candidate
        break
    fi
done
[ -n "$VOLUME" ] || { echo "FAIL: Toolbox SD card not found"; exit 1; }

STATE="/tmp/oem-plane-census"
PIDFILE="$STATE/pid"
[ -f "$PIDFILE" ] || {
    echo "FAIL: observer is not started"
    echo "ACTION=RUN_START_OBSERVER"
    exit 2
}
PID="$(cat "$PIDFILE" 2>/dev/null || true)"
[ -n "$PID" ] && kill -0 "$PID" 2>/dev/null || {
    echo "FAIL: observer pid is stale"
    echo "ACTION=RUN_START_OBSERVER"
    exit 3
}
[ -f "$STATE/READY" ] || { echo "FAIL: observer not READY"; exit 4; }

# Let the active OEM plane publish at least a few frames after the user settles
# the requested stock layout. No property is written by this delay/capture.
sleep 1

DEST="$VOLUME/MMI-Cockpit-Carplay/logs/oem-plane-census"
TMP="/tmp/oem-plane-census-capture.$$"
mkdir -p "$DEST" || { echo "FAIL: cannot create $DEST"; exit 5; }

TS="$(date +%Y%m%d_%H%M%S 2>/dev/null || echo unknown)"
SNAP="$DEST/${TS}_${LABEL}.log"
MASTER="$DEST/plane33-58-census.log"

MISSING=0
{
    echo "CENSUS_BEGIN schema=OEM_PLANE33_58_CENSUS_V1_1 label=$LABEL timestamp=$TS mode=READ_ONLY"
    echo "EXPECTED_VEHICLE_STATE=$LABEL"
    echo "observer_pid=$PID"
    echo "source=WINDOW_MANAGER_EVENT_QUEUE_latest_native_snapshot"

    for id in 33 58; do
        SRC="$STATE/window${id}.state"
        echo "TARGET_SNAPSHOT_BEGIN id=$id"
        if [ -f "$SRC" ]; then
            cat "$SRC"
        else
            echo "snapshot=NOT_YET_OBSERVED"
            echo "hint=switch_stock_VC_view_after_START_OBSERVER_to_generate_PROPERTY_or_POST_events"
            MISSING=1
        fi
        echo "TARGET_SNAPSHOT_END id=$id"
    done

    if [ -f /tmp/carplay-oem-geometry.state ]; then
        echo "HMI_GEOMETRY_CORRELATION_BEGIN"
        cat /tmp/carplay-oem-geometry.state
        echo "HMI_GEOMETRY_CORRELATION_END"
    else
        echo "HMI_GEOMETRY_CORRELATION=UNAVAILABLE"
    fi

    echo "CENSUS_END label=$LABEL missing_target_snapshot=$MISSING"
} > "$TMP" 2>&1

cp "$TMP" "$SNAP" 2>/dev/null || true
cat "$TMP" >> "$MASTER" 2>/dev/null || true
if [ -f /tmp/carplay-oem-geometry.state ]; then
    cp /tmp/carplay-oem-geometry.state        "$DEST/${TS}_${LABEL}_hmi_geometry.state" 2>/dev/null || true
fi
rm -f "$TMP"
sync >/dev/null 2>&1 || true

echo "OEM_PLANE_CENSUS_CAPTURE label=$LABEL missing=$MISSING"
echo "snapshot=$SNAP"
echo "master=$MASTER"
if [ "$MISSING" -ne 0 ]; then
    echo "WARN: one or more target windows have not emitted an observable event yet; log was retained"
fi
exit 0
