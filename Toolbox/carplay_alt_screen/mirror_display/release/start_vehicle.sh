#!/bin/sh
set -eu

# Mirror can be launched from startup.sh, GEM, diagnostics, or an SSH shell.
# Do not rely on the caller having inherited the MHI2Q/QNX runtime search path.
# Keep this in sync with the integrated Mirror boot block and diagnostics block.
PATH=${PATH:+$PATH:}/proc/boot:/armle/bin:/armle/scripts:/bin:/usr/bin:/usr/sbin:/sbin:/mnt/app/armle/bin:/mnt/app/armle/sbin:/mnt/app/armle/usr/bin:/mnt/app/armle/usr/sbin:/eso/bin:/eso/bin/apps
export PATH
# Only publish the QNX loader path on a real target. This keeps host-side
# fixtures usable while production MHI2Q launches remain deterministic.
if [ -d /proc/boot ] && [ -d /mnt/app ]; then
  LD_LIBRARY_PATH=${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}/proc/boot:/usr/lib:/armle/lib:/armle/lib/dll:/lib:/mnt/app/root/carplay-altscreen/lib:/eso/lib:/mnt/app/usr/lib:/mnt/app/armle/lib:/mnt/app/armle/lib/dll:/mnt/app/armle/usr/lib:/lib/dll
  export LD_LIBRARY_PATH
fi

case "$0" in
  */*) ROOT=${0%/*} ;;
  *)   ROOT=. ;;
esac

ROOT=$(CDPATH= cd "$ROOT" 2>/dev/null && pwd) || {
  echo "ERROR: cannot resolve mirror script directory from $0" >&2
  exit 2
}

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
  GATE_TOKEN="$VOLATILE/phone111.gate"
  HOOK_LOG="$PROJECT_TMP/altscreen_hook.log"
  VOLATILE_MODE=NAMESPACE
else
  PIDFILE="$TMP_ROOT/MMI-Cockpit-Carplay.mirror.pid"
  LOGFILE="$TMP_ROOT/MMI-Cockpit-Carplay.mirror.log"
  READY="$TMP_ROOT/MMI-Cockpit-Carplay.mirror.ready"
  BASE_READY="$TMP_ROOT/MMI-Cockpit-Carplay.mirror.basevideo.ready"
  GATE_TOKEN="$TMP_ROOT/MMI-Cockpit-Carplay.mirror.phone111.gate"
  HOOK_LOG="$TMP_ROOT/altscreen_hook.log"
  VOLATILE_MODE=FLAT_TMP
fi

export ALT111_MIRROR_READY_FILE="$READY"
export ALT111_MIRROR_BASE_READY_FILE="$BASE_READY"
export ALT111_MIRROR_GATE_TOKEN_FILE="$GATE_TOKEN"
export ALT111_MIRROR_HOOK_LOG="$HOOK_LOG"

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
{
  echo "MIRROR_LAUNCH_ENV=READY pid=$$ bin=$BIN volatile_mode=$VOLATILE_MODE"
  echo "PATH=$PATH"
  echo "LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-<unset>}"
  echo "HOOK_LOG=$HOOK_LOG"
  echo "GATE_TOKEN=$GATE_TOKEN"
  echo "SCREEN_CONTEXT_POLICY=NONE_BEFORE_PHONE_REQUEST_111"
} >> "$LOGFILE"

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
echo "WAITING_FOR=PHONE_REQUEST_111_then_Window58_CREATE_POST"
