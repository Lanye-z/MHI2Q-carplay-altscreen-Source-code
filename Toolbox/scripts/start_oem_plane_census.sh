#!/bin/sh
set -u

BIN="/mnt/app/root/oem-plane-census/bin/oem-plane-census"
STATE="/tmp/oem-plane-census"
PIDFILE="$STATE/pid"
LOG="$STATE/observer.log"

[ -x "$BIN" ] || {
    echo "FAIL: observer binary not installed: $BIN"
    echo "ACTION=RUN_INSTALL_OBSERVER"
    exit 2
}

mkdir -p "$STATE" || { echo "FAIL: cannot create $STATE"; exit 3; }

if [ -f "$PIDFILE" ]; then
    OLD="$(cat "$PIDFILE" 2>/dev/null || true)"
    if [ -n "$OLD" ] && kill -0 "$OLD" 2>/dev/null; then
        echo "OEM_PLANE_CENSUS_START=ALREADY_RUNNING pid=$OLD"
        [ -f "$STATE/READY" ] && echo "READY=YES" || echo "READY=NO"
        exit 0
    fi
fi

rm -f "$PIDFILE" "$STATE/READY"
: > "$LOG"

if command -v nohup >/dev/null 2>&1; then
    nohup "$BIN" --watch --state-dir "$STATE" </dev/null >>"$LOG" 2>&1 &
else
    "$BIN" --watch --state-dir "$STATE" </dev/null >>"$LOG" 2>&1 &
fi
PID=$!
echo "$PID" > "$PIDFILE"

i=0
while [ "$i" -lt 5 ]; do
    if ! kill -0 "$PID" 2>/dev/null; then
        echo "FAIL: observer exited during startup pid=$PID"
        tail -n 80 "$LOG" 2>/dev/null || true
        rm -f "$PIDFILE"
        exit 4
    fi
    if [ -f "$STATE/READY" ]; then
        echo "OEM_PLANE_CENSUS_START=PASS pid=$PID"
        echo "mode=READ_ONLY event_source=WINDOW_MANAGER_CONTEXT"
        echo "warmup=SWITCH_STOCK_VC_VIEW_AFTER_START_TO_REFRESH_33_58"
        exit 0
    fi
    sleep 1
    i=$((i + 1))
done

echo "FAIL: observer did not publish READY"
tail -n 80 "$LOG" 2>/dev/null || true
kill -TERM "$PID" 2>/dev/null || true
rm -f "$PIDFILE"
exit 5
