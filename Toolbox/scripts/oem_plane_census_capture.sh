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

BIN="/mnt/app/root/oem-plane-census/bin/oem-plane-census"
[ -x "$BIN" ] || {
    echo "FAIL: observer binary not installed: $BIN"
    echo "ACTION=RUN_INSTALL_OBSERVER"
    exit 2
}

DEST="$VOLUME/MMI-Cockpit-Carplay/logs/oem-plane-census"
TMP="/tmp/oem-plane-census.$$"
mkdir -p "$DEST" || { echo "FAIL: cannot create $DEST"; exit 3; }

TS="$(date +%Y%m%d_%H%M%S 2>/dev/null || echo unknown)"
SNAP="$DEST/${TS}_${LABEL}.log"
MASTER="$DEST/plane33-58-census.log"

{
    echo "CAPTURE_REQUEST label=$LABEL timestamp=$TS"
    echo "EXPECTED_VEHICLE_STATE=$LABEL"
    echo "NOTE=switch_the_stock_VC_to_the_named_state_before_running_this_capture"
    "$BIN" --label "$LABEL"
    RC=$?
    echo "CAPTURE_BINARY_RC=$RC"
    exit "$RC"
} > "$TMP" 2>&1
RC=$?

cp "$TMP" "$SNAP" 2>/dev/null || true
cat "$TMP" >> "$MASTER" 2>/dev/null || true

# Correlate with the pre-existing HMI observer when present, but never depend on it.
if [ -f /tmp/carplay-oem-geometry.state ]; then
    cp /tmp/carplay-oem-geometry.state        "$DEST/${TS}_${LABEL}_hmi_geometry.state" 2>/dev/null || true
fi

rm -f "$TMP"
sync >/dev/null 2>&1 || true

echo "OEM_PLANE_CENSUS_CAPTURE label=$LABEL rc=$RC"
echo "snapshot=$SNAP"
echo "master=$MASTER"
exit "$RC"
