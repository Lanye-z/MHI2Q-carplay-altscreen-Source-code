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
  WATCH_PIDFILE="$VOLATILE/lifecycle.pid"
  STOP_GUARD="$VOLATILE/stop.requested"
  LOGFILE="$VOLATILE/mirror.log"
  AUTORESTART_LOG="$VOLATILE/autorestart.log"
  READY="$VOLATILE/ready"
  BASE_READY="${ALT111_JAVA_BASE_READY_FILE:-/tmp/mmi-mirror-basevideo.ready}"
  GATE_TOKEN="$VOLATILE/phone111.gate"
  HOOK_LOG="$PROJECT_TMP/altscreen_hook.log"
  VOLATILE_MODE=NAMESPACE
else
  PIDFILE="$TMP_ROOT/MMI-Cockpit-Carplay.mirror.pid"
  WATCH_PIDFILE="$TMP_ROOT/MMI-Cockpit-Carplay.mirror.lifecycle.pid"
  STOP_GUARD="$TMP_ROOT/MMI-Cockpit-Carplay.mirror.stop.requested"
  LOGFILE="$TMP_ROOT/MMI-Cockpit-Carplay.mirror.log"
  AUTORESTART_LOG="$TMP_ROOT/MMI-Cockpit-Carplay.mirror.autorestart.log"
  READY="$TMP_ROOT/MMI-Cockpit-Carplay.mirror.ready"
  BASE_READY="${ALT111_JAVA_BASE_READY_FILE:-/tmp/mmi-mirror-basevideo.ready}"
  GATE_TOKEN="$TMP_ROOT/MMI-Cockpit-Carplay.mirror.phone111.gate"
  HOOK_LOG="$TMP_ROOT/altscreen_hook.log"
  VOLATILE_MODE=FLAT_TMP
fi

DEMAND="${ALT111_MIRROR_ACTIVE_FILE:-/tmp/mmi-mirror-active}"
RESTART_REASON="${ALT111_MIRROR_RESTART_REASON:-}"

export ALT111_MIRROR_READY_FILE="$READY"
export ALT111_MIRROR_BASE_READY_FILE="$BASE_READY"
export ALT111_MIRROR_GATE_TOKEN_FILE="$GATE_TOKEN"
export ALT111_MIRROR_HOOK_LOG="$HOOK_LOG"

SINK_TEST_GRID_MODE=0
MIRROR_ARGS="--verbose"
if [ "${ALT111_SINK_TEST_GRID:-0}" = "1" ]; then
  SINK_TEST_GRID_MODE=1
  MIRROR_ARGS="$MIRROR_ARGS --sink-test-grid"
fi

if [ ! -x "$BIN" ]; then
  echo "ERROR: mirror display binary not found/executable: $BIN" >&2
  exit 2
fi

# An explicit stop wins over an automatic next-session restart. A normal boot,
# manual START, or diagnostic launch clears a stale guard from an earlier stop.
if [ -n "$RESTART_REASON" ] && [ -f "$STOP_GUARD" ]; then
  echo "MIRROR_RESTART=SUPPRESSED reason=explicit_stop guard=$STOP_GUARD"
  exit 0
fi
if [ -z "$RESTART_REASON" ]; then
  rm -f "$STOP_GUARD"
fi

if [ -f "$PIDFILE" ]; then
  OLD="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [ -n "$OLD" ] && kill -0 "$OLD" 2>/dev/null; then
    echo "ALREADY_RUNNING pid=$OLD"
    exit 0
  fi
  rm -f "$PIDFILE"
fi

# A prior launcher may have died after its sidecar. Do not let a stale lifecycle
# watcher survive into the new session.
if [ -f "$WATCH_PIDFILE" ]; then
  OLD_WATCH="$(cat "$WATCH_PIDFILE" 2>/dev/null || true)"
  if [ -n "$OLD_WATCH" ] && kill -0 "$OLD_WATCH" 2>/dev/null; then
    kill -TERM "$OLD_WATCH" 2>/dev/null || true
  fi
  rm -f "$WATCH_PIDFILE"
fi

rm -f "$READY" "$BASE_READY"
if [ "$RESTART_REASON" = "private111_session_end" ]; then
  {
    echo ""
    echo "MIRROR_SESSION_RESTART reason=$RESTART_REASON launcher_pid=$$"
  } >> "$LOGFILE"
else
  : > "$LOGFILE"
fi

{
  echo "MIRROR_LAUNCH_ENV=READY pid=$$ bin=$BIN volatile_mode=$VOLATILE_MODE restart_reason=${RESTART_REASON:-NONE}"
  echo "PATH=$PATH"
  echo "LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-<unset>}"
  echo "HOOK_LOG=$HOOK_LOG"
  echo "GATE_TOKEN=$GATE_TOKEN"
  echo "SCREEN_CONTEXT_POLICY=JAVA80_ONLY native_context_writer=0"
  echo "READY_POLICY=destination_first_present_only base_ready=$BASE_READY"
  echo "DIRECT111_SOURCE=ScreenStreamProcessData+H264_SHM decoded_shm=/carplay111_decoded"
  echo "WINDOW58_POLICY=NOT_CONSUMED screen_read_window=0 window_manager_context=0"
  echo "SINK_TEST_GRID_MODE=$SINK_TEST_GRID_MODE opt_in_env=ALT111_SINK_TEST_GRID"
  echo "DECODER_POLICY=v1_stock_omx_buffer_tap_fallback h264_shm=/carplay111_h264"
  echo "SIDECAR_PRELOAD_POLICY=ISOLATED inherited_preload_ignored=${LD_PRELOAD:-<unset>}"
  echo "SESSION_END_POLICY=hook_DIRECT111_TAP_STOP after_first_present restart_while_demand=1"
} >> "$LOGFILE"

count_tap_stops() {
  N="$(grep -c 'PHASE=DIRECT111_TAP_STOP' "$HOOK_LOG" 2>/dev/null || true)"
  case "$N" in
    ''|*[!0-9]*) N=0 ;;
  esac
  echo "$N"
}

sidecar_is_current() {
  [ -f "$PIDFILE" ] || return 1
  CURRENT="$(cat "$PIDFILE" 2>/dev/null || true)"
  [ "$CURRENT" = "$PID" ] || return 1
  kill -0 "$PID" 2>/dev/null
}

# Deliberately do not inherit the CarPlay/dio_manager preload into the sidecar.
# Direct-display consumes SHM only and does not need any Window58 ID bridge.
LD_PRELOAD= "$BIN" $MIRROR_ARGS >>"$LOGFILE" 2>&1 &
PID=$!
echo "$PID" > "$PIDFILE"

# The QNX sidecar deliberately freezes the last decoded frame through temporary
# stalls. The stock hook already emits DIRECT111_TAP_STOP only when the private
# stream is really torn down. Observe that append-only log after first present:
# teardown -> SIGTERM sidecar -> marker(false) -> Java releases Context80.
# If BaseVideo demand remains active, start a fresh sidecar so a later CarPlay
# reconnect can consume the next PHONE_REQUEST_111 gate without rebooting MMI.
if [ "$SINK_TEST_GRID_MODE" = "0" ]; then
  (
    BASELINE="$(count_tap_stops)"

    # Before first physical destination present, absorb stop records into the
    # baseline. This avoids killing a new attempt because an earlier failed
    # private111 setup was torn down before displayable3 became ready.
    while sidecar_is_current && [ ! -f "$STOP_GUARD" ] && [ ! -f "$BASE_READY" ]; do
      BASELINE="$(count_tap_stops)"
      sleep 1
    done

    sidecar_is_current || exit 0
    [ ! -f "$STOP_GUARD" ] || exit 0

    echo "LIFECYCLE_WATCH=ARMED sidecar_pid=$PID stop_count=$BASELINE hook_log=$HOOK_LOG base_ready=$BASE_READY"

    while sidecar_is_current && [ ! -f "$STOP_GUARD" ]; do
      CURRENT_STOPS="$(count_tap_stops)"
      if [ "$CURRENT_STOPS" -lt "$BASELINE" ]; then
        # Defensive handling for an unexpected log replacement/truncation.
        BASELINE="$CURRENT_STOPS"
      elif [ "$CURRENT_STOPS" -gt "$BASELINE" ]; then
        echo "LIFECYCLE_WATCH=PRIVATE111_STOP detected=1 sidecar_pid=$PID stop_count=$CURRENT_STOPS action=TERM_AND_RESTART_IF_DEMAND"
        kill -TERM "$PID" 2>/dev/null || true
        WAIT_N=0
        while kill -0 "$PID" 2>/dev/null && [ "$WAIT_N" -lt 10 ]; do
          sleep 1
          WAIT_N=$((WAIT_N + 1))
        done
        if kill -0 "$PID" 2>/dev/null; then
          echo "LIFECYCLE_WATCH=SIDECAR_TERM_TIMEOUT action=KILL pid=$PID"
          kill -KILL "$PID" 2>/dev/null || true
        fi

        rm -f "$PIDFILE" "$READY" "$BASE_READY"
        rm -f "$WATCH_PIDFILE"

        if [ -f "$DEMAND" ] && [ ! -f "$STOP_GUARD" ]; then
          echo "LIFECYCLE_WATCH=RESTART_NEXT_SESSION demand=$DEMAND gate_policy=next_PHONE_REQUEST_111"
          ALT111_MIRROR_RESTART_REASON=private111_session_end             /bin/sh "$ROOT/start_vehicle.sh" >>"$AUTORESTART_LOG" 2>&1 &
        else
          echo "LIFECYCLE_WATCH=NO_RESTART demand_present=$([ -f "$DEMAND" ] && echo 1 || echo 0) explicit_stop=$([ -f "$STOP_GUARD" ] && echo 1 || echo 0)"
        fi
        exit 0
      fi
      sleep 1
    done
  ) >>"$LOGFILE" 2>&1 &
  WATCH_PID=$!
  echo "$WATCH_PID" > "$WATCH_PIDFILE"
  echo "MIRROR_LIFECYCLE_WATCH=STARTED pid=$WATCH_PID trigger=DIRECT111_TAP_STOP after_first_present=1 restart_while_demand=1"
fi

sleep 1
if ! kill -0 "$PID" 2>/dev/null; then
  echo "ERROR: mirror display exited during startup" >&2
  tail -80 "$LOGFILE" 2>/dev/null || true
  if [ -f "$WATCH_PIDFILE" ]; then
    WATCH_PID="$(cat "$WATCH_PIDFILE" 2>/dev/null || true)"
    [ -z "$WATCH_PID" ] || kill -TERM "$WATCH_PID" 2>/dev/null || true
  fi
  rm -f "$PIDFILE" "$WATCH_PIDFILE"
  exit 3
fi

echo "MIRROR_DISPLAY=STARTED pid=$PID log=$LOGFILE volatile_mode=$VOLATILE_MODE sink_test_grid=$SINK_TEST_GRID_MODE"
if [ "$SINK_TEST_GRID_MODE" = 1 ]; then
  echo "WAITING_FOR=BASEVIDEO_ACTIVE_then_Java_CTX80 test_grid_already_presented=1"
else
  echo "WAITING_FOR=PHONE_REQUEST_111_then_H264_TAP_then_DECODER_FIRST_FRAME_then_DISPLAYABLE3"
fi
