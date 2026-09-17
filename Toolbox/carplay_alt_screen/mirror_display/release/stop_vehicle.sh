#!/bin/sh
set -eu
TMP_ROOT="${ALT111_MIRROR_TMP_ROOT:-/tmp}"
NS="$TMP_ROOT/MMI-Cockpit-Carplay/mirror"
FLAT="$TMP_ROOT/MMI-Cockpit-Carplay.mirror"
PIDFILE=""
for candidate in "$NS/pid" "$FLAT.pid"; do [ -f "$candidate" ] && { PIDFILE=$candidate; break; }; done
if [ -n "$PIDFILE" ]; then
  PID="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    kill -TERM "$PID" 2>/dev/null || true
    N=0
    while kill -0 "$PID" 2>/dev/null && [ "$N" -lt 30 ]; do sleep 1; N=$((N + 1)); done
    if kill -0 "$PID" 2>/dev/null; then kill -KILL "$PID" 2>/dev/null || true; fi
  fi
fi
rm -f "$NS/pid" "$NS/ready" "$NS/basevideo.ready" "$FLAT.pid" "$FLAT.ready" "$FLAT.basevideo.ready"
/eso/bin/apps/dmdt dc 76 3 >/dev/null 2>&1 || true
/eso/bin/apps/dmdt sc 1 72 >/dev/null 2>&1 || true
sleep 1
/eso/bin/apps/dmdt sc 1 74 >/dev/null 2>&1 || true
echo "MIRROR_DISPLAY=STOPPED context=74"
