#!/bin/sh
set -u

DST_DIR="/mnt/app/root/oem-plane-census"
STATE="/tmp/oem-plane-census"
PIDFILE="$STATE/pid"

echo "OBSERVER_ONLY_UNINSTALL=YES"
echo "CARPLAY_FILES_TOUCHED=NO"

if [ -f "$PIDFILE" ]; then
    PID="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
        kill -TERM "$PID" 2>/dev/null || true
        i=0
        while [ "$i" -lt 5 ] && kill -0 "$PID" 2>/dev/null; do
            sleep 1
            i=$((i + 1))
        done
        kill -0 "$PID" 2>/dev/null && kill -KILL "$PID" 2>/dev/null || true
    fi
fi
rm -f "$PIDFILE" "$STATE/READY"

mount -uw /mnt/app || { echo "FAIL: cannot mount /mnt/app rw"; exit 1; }
rm -rf "$DST_DIR"
sync
mount -ur /mnt/app || true

echo "OEM_PLANE_CENSUS_UNINSTALL=PASS"
echo "runtime_state_retained=$STATE"
