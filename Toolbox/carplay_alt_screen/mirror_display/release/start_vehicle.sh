#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
if [ -n "${ALT111_MIRROR_BIN:-}" ]; then
  BIN="$ALT111_MIRROR_BIN"
elif [ -x "$ROOT/carplay-alt111-mirror-display" ]; then
  BIN="$ROOT/carplay-alt111-mirror-display"
else
  BIN="$ROOT/release/carplay-alt111-mirror-display"
fi
TMP_ROOT="${ALT111_MIRROR_TMP_ROOT:-/tmp}"
PROJECT_TMP="$TMP_ROOT/MMI-Cockpit-Carplay"
VOLATILE="$PROJECT_TMP/mirror"
if [ ! -d "$PROJECT_TMP" ]; then mkdir "$PROJECT_TMP" 2>/dev/null || true; fi
if [ -d "$PROJECT_TMP" ] && [ ! -d "$VOLATILE" ]; then mkdir "$VOLATILE" 2>/dev/null || true; fi
if [ -d "$VOLATILE" ]; then
  PIDFILE="$VOLATILE/pid"
  LOGFILE="$VOLATILE/mirror.log"
  READY="$VOLATILE/ready"
  BASE_READY="$VOLATILE/basevideo.ready"
  VOLATILE_MODE=NAMESPACE
else
  PIDFILE="$TMP_ROOT/MMI-Cockpit-Carplay.mirror.pid"
  LOGFILE="$TMP_ROOT/MMI-Cockpit-Carplay.mirror.log"
  READY="$TMP_ROOT/MMI-Cockpit-Carplay.mirror.ready"
  BASE_READY="$TMP_ROOT/MMI-Cockpit-Carplay.mirror.basevideo.ready"
  VOLATILE_MODE=FLAT_TMP
fi
export ALT111_MIRROR_READY_FILE="$READY"
export ALT111_MIRROR_BASE_READY_FILE="$BASE_READY"

if [ ! -x "$BIN" ]; then
  echo "ERROR: mirror display binary not found/executable: $BIN" >&2
  exit 2
fi

if [ -f "$PIDFILE" ]; then
  OLD="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [ -n "$OLD" ] && kill -0 "$OLD" 2>/dev/null; then
    echo "ALREADY_RUNNING pid=$OLD"
    exit 0
  fi
  rm -f "$PIDFILE"
fi

rm -f "$READY" "$BASE_READY"
: > "$LOGFILE"
"$BIN" --verbose >>"$LOGFILE" 2>&1 &
PID=$!
echo "$PID" > "$PIDFILE"
sleep 1
if ! kill -0 "$PID" 2>/dev/null; then
  echo "ERROR: mirror display exited during startup" >&2
  tail -80 "$LOGFILE" 2>/dev/null || true
  rm -f "$PIDFILE"
  exit 3
fi

echo "MIRROR_DISPLAY=STARTED pid=$PID log=$LOGFILE volatile_mode=$VOLATILE_MODE"
echo "WAITING_FOR=private111_window58"
