#!/bin/sh
set -u

STATE="/tmp/oem-plane-census"
PIDFILE="$STATE/pid"

if [ ! -f "$PIDFILE" ]; then
    echo "OEM_PLANE_CENSUS_STOP=NOT_RUNNING"
    exit 0
fi

PID="$(cat "$PIDFILE" 2>/dev/null || true)"
if [ -z "$PID" ]; then
    rm -f "$PIDFILE" "$STATE/READY"
    echo "OEM_PLANE_CENSUS_STOP=STALE_PIDFILE"
    exit 0
fi

if kill -0 "$PID" 2>/dev/null; then
    kill -TERM "$PID" 2>/dev/null || true
    i=0
    while [ "$i" -lt 5 ] && kill -0 "$PID" 2>/dev/null; do
        sleep 1
        i=$((i + 1))
    done
    if kill -0 "$PID" 2>/dev/null; then
        echo "WARN: observer did not stop after TERM; sending KILL"
        kill -KILL "$PID" 2>/dev/null || true
    fi
fi

rm -f "$PIDFILE" "$STATE/READY"
echo "OEM_PLANE_CENSUS_STOP=PASS pid=$PID"
