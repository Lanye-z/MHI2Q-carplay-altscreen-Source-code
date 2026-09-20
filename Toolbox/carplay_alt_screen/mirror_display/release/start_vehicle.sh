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
  RECOVERY_LOCK="$VOLATILE/recovery.lock"
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
  RECOVERY_LOCK="$TMP_ROOT/MMI-Cockpit-Carplay.mirror.recovery.lock"
  READY="$TMP_ROOT/MMI-Cockpit-Carplay.mirror.ready"
  BASE_READY="${ALT111_JAVA_BASE_READY_FILE:-/tmp/mmi-mirror-basevideo.ready}"
  GATE_TOKEN="$TMP_ROOT/MMI-Cockpit-Carplay.mirror.phone111.gate"
  HOOK_LOG="$TMP_ROOT/altscreen_hook.log"
  VOLATILE_MODE=FLAT_TMP
fi

# The active test SD is the primary log sink. Runtime state, PID files, gates
# and the fallback log remain in /tmp so loss of the card cannot block CarPlay.
TMP_LOGFILE="$LOGFILE"
TMP_HOOK_LOG="$HOOK_LOG"
SD_VOLUME=""
if [ "${ALTSCREEN_CHAIN_TESTING:-0}" = 1 ]; then
  candidate=${ALTSCREEN_CHAIN_VOLUME:-}
  if [ -n "$candidate" ] && [ -d "$candidate/Toolbox" ] && [ -d "$candidate/MMI-Cockpit-Carplay/state" ]; then
    SD_VOLUME=$candidate
  fi
else
  for candidate in /net/mmx/fs/sda0 /net/mmx/fs/sda1 /net/mmx/fs/sdb0 /net/mmx/fs/sdb1 /fs/sda0 /fs/sda1 /fs/sdb0 /fs/sdb1; do
    if [ -d "$candidate/Toolbox" ] && [ -d "$candidate/MMI-Cockpit-Carplay/state" ]; then
      SD_VOLUME=$candidate
      break
    fi
  done
fi
if [ -n "$SD_VOLUME" ] && [ -d "$SD_VOLUME/MMI-Cockpit-Carplay/logs" ]; then
  LOGFILE="$SD_VOLUME/MMI-Cockpit-Carplay/logs/mirror.log"
  HOOK_LOG="$SD_VOLUME/MMI-Cockpit-Carplay/logs/altscreen_hook.log"
fi

LOG_HELPER=""
for candidate in "$ROOT/../altscreen_log_ring.sh" "$ROOT/../../../scripts/altscreen_log_ring.sh"; do
  [ -f "$candidate" ] && { LOG_HELPER=$candidate; break; }
done
log_lines() {
  if [ -n "$LOG_HELPER" ]; then
    /bin/sh "$LOG_HELPER" pipe mirror "$TMP_LOGFILE" || cat > /dev/null
  else
    cat >> "$TMP_LOGFILE" 2>/dev/null || cat > /dev/null
  fi
  return 0
}
log_relaunch() {
  if [ -n "$LOG_HELPER" ]; then
    relaunch_fifo="$VOLATILE/relaunch.$$.fifo"
    if mkfifo "$relaunch_fifo" 2>/dev/null; then
      (
        exec 3< "$relaunch_fifo" || exit 0
        /bin/sh "$LOG_HELPER" pipe mirror "$TMP_LOGFILE" <&3 ||
          { cat <&3 >> "$TMP_LOGFILE" 2>/dev/null || cat <&3 > /dev/null; }
      ) &
      relaunch_reader=$!
      /bin/sh "$ROOT/start_vehicle.sh" > "$relaunch_fifo" 2>&1 || true
      wait "$relaunch_reader" 2>/dev/null || true
      rm -f "$relaunch_fifo"
    else
      /bin/sh "$ROOT/start_vehicle.sh" >> "$TMP_LOGFILE" 2>&1 || true
    fi
  else
    /bin/sh "$ROOT/start_vehicle.sh" >> "$TMP_LOGFILE" 2>&1 || true
  fi
  return 0
}

DEMAND="${ALT111_MIRROR_ACTIVE_FILE:-/tmp/mmi-mirror-active}"
RESTART_REASON="${ALT111_MIRROR_RESTART_REASON:-}"
RESTART_COUNT="${ALT111_MIRROR_RESTART_COUNT:-0}"
MAX_ABNORMAL_RESTARTS="${ALT111_MIRROR_MAX_ABNORMAL_RESTARTS:-3}"
RECOVER_CURRENT_SESSION="${ALT111_RECOVER_CURRENT_SESSION:-0}"
export ALT111_RECOVER_CURRENT_SESSION="$RECOVER_CURRENT_SESSION"
case "$RESTART_COUNT" in ''|*[!0-9]*) RESTART_COUNT=0 ;; esac
case "$MAX_ABNORMAL_RESTARTS" in ''|*[!0-9]*) MAX_ABNORMAL_RESTARTS=3 ;; esac

export ALT111_MIRROR_READY_FILE="$READY"
export ALT111_MIRROR_BASE_READY_FILE="$BASE_READY"
export ALT111_MIRROR_GATE_TOKEN_FILE="$GATE_TOKEN"
export ALT111_MIRROR_HOOK_LOG="$HOOK_LOG"
export ALT111_MIRROR_HOOK_FALLBACK_LOG="$TMP_HOOK_LOG"

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

# An abnormal-restart lock prevents the startup probe and lifecycle watcher from
# scheduling the same recovery twice. Keep it until the delayed child actually
# starts, then release it for future failures.
if [ "$RESTART_REASON" = "sidecar_abnormal" ]; then
  rmdir "$RECOVERY_LOCK" 2>/dev/null || true
elif [ -z "$RESTART_REASON" ]; then
  rmdir "$RECOVERY_LOCK" 2>/dev/null || true
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
if [ -n "$RESTART_REASON" ]; then
  {
    echo ""
    echo "MIRROR_SESSION_RESTART reason=$RESTART_REASON launcher_pid=$$"
  } | log_lines &
fi

{
  echo "MIRROR_LAUNCH_ENV=READY pid=$ bin=$BIN volatile_mode=$VOLATILE_MODE restart_reason=${RESTART_REASON:-NONE} restart_count=$RESTART_COUNT max_abnormal_restarts=$MAX_ABNORMAL_RESTARTS recover_current_session=$RECOVER_CURRENT_SESSION"
  echo "PATH=$PATH"
  echo "LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-<unset>}"
  echo "HOOK_LOG=$HOOK_LOG fallback=$TMP_HOOK_LOG"
  echo "GATE_TOKEN=$GATE_TOKEN"
  echo "SCREEN_CONTEXT_POLICY=JAVA80_ONLY native_context_writer=0"
  echo "READY_POLICY=destination_first_present_only base_ready=$BASE_READY"
  echo "DIRECT111_SOURCE=ScreenStreamProcessData+H264_SHM decoded_shm=/carplay111_decoded"
  echo "WINDOW58_POLICY=NOT_ENUMERATED sidecar_screen_read_window=0 hook_exact_stock_window_readback=1 window_manager_context=0"
  echo "SINK_TEST_GRID_MODE=$SINK_TEST_GRID_MODE opt_in_env=ALT111_SINK_TEST_GRID"
  echo "DECODER_POLICY=stock_omx_then_screen_linearizer decoded_shm=/carplay111_decoded h264_shm=/carplay111_h264 raw_vendor_fallback=DISABLED"
  echo "SHM_POLICY=fstat_size_guard writer_ready_last=1 session_identity=writer_pid+generation+stream_cookie"
  echo "SIDECAR_PRELOAD_POLICY=ISOLATED inherited_preload_ignored=${LD_PRELOAD:-<unset>}"
  echo "SESSION_END_POLICY=hook_DIRECT111_TAP_STOP after_first_present restart_while_demand=1"
} | log_lines &

SD_STOP_MARKER=""
[ -z "$SD_VOLUME" ] || SD_STOP_MARKER="$SD_VOLUME/MMI-Cockpit-Carplay/state/direct111_tap_stop.state"
TMP_STOP_MARKER="$PROJECT_TMP/direct111_tap_stop.state"
FLAT_STOP_MARKER="$TMP_ROOT/direct111_tap_stop.state"
read_stop_marker() {
  [ -n "$1" ] && [ -s "$1" ] || return 0
  sed -n '1p' "$1" 2>/dev/null || true
}
tap_stop_changed() {
  CURRENT_STOP_SOURCE=""
  CURRENT_SD_STOP=$(read_stop_marker "$SD_STOP_MARKER")
  CURRENT_TMP_STOP=$(read_stop_marker "$TMP_STOP_MARKER")
  CURRENT_FLAT_STOP=$(read_stop_marker "$FLAT_STOP_MARKER")
  if [ -n "$CURRENT_SD_STOP" ] && [ "$CURRENT_SD_STOP" != "$BASELINE_SD_STOP" ]; then CURRENT_STOP_SOURCE=SD; return 0; fi
  if [ -n "$CURRENT_TMP_STOP" ] && [ "$CURRENT_TMP_STOP" != "$BASELINE_TMP_STOP" ]; then CURRENT_STOP_SOURCE=TMP; return 0; fi
  if [ -n "$CURRENT_FLAT_STOP" ] && [ "$CURRENT_FLAT_STOP" != "$BASELINE_FLAT_STOP" ]; then CURRENT_STOP_SOURCE=FLAT_TMP; return 0; fi
  return 1
}

sidecar_is_current() {
  [ -f "$PIDFILE" ] || return 1
  CURRENT="$(cat "$PIDFILE" 2>/dev/null || true)"
  [ "$CURRENT" = "$PID" ] || return 1
  kill -0 "$PID" 2>/dev/null
}

schedule_abnormal_restart() {
  WHY=$1
  if ! mkdir "$RECOVERY_LOCK" 2>/dev/null; then
    echo "MIRROR_ABNORMAL_RESTART=ALREADY_SCHEDULED reason=$WHY lock=$RECOVERY_LOCK"
    return 0
  fi
  NEXT=$((RESTART_COUNT + 1))
  if [ "$NEXT" -gt "$MAX_ABNORMAL_RESTARTS" ]; then
    echo "MIRROR_ABNORMAL_RESTART=EXHAUSTED reason=$WHY count=$RESTART_COUNT max=$MAX_ABNORMAL_RESTARTS"
    rmdir "$RECOVERY_LOCK" 2>/dev/null || true
    return 1
  fi
  [ -f "$DEMAND" ] || {
    echo "MIRROR_ABNORMAL_RESTART=SUPPRESSED reason=$WHY demand_present=0"
    rmdir "$RECOVERY_LOCK" 2>/dev/null || true
    return 1
  }
  [ ! -f "$STOP_GUARD" ] || {
    echo "MIRROR_ABNORMAL_RESTART=SUPPRESSED reason=$WHY explicit_stop=1"
    rmdir "$RECOVERY_LOCK" 2>/dev/null || true
    return 1
  }

  DELAY=$NEXT
  rm -f "$PIDFILE" "$READY" "$BASE_READY"
  echo "MIRROR_ABNORMAL_RESTART=SCHEDULED reason=$WHY next_count=$NEXT delay_s=$DELAY recover_current_session=1"
  (
    sleep "$DELAY"
    ALT111_MIRROR_RESTART_REASON=sidecar_abnormal \
    ALT111_MIRROR_RESTART_COUNT="$NEXT" \
    ALT111_RECOVER_CURRENT_SESSION=1 \
      log_relaunch
  ) &
  return 0
}

# Deliberately do not inherit the CarPlay/dio_manager preload into the sidecar.
# A FIFO reader owns SD-first rotation; stdout/stderr never hold an old renamed
# segment open. If the pipe cannot be created, use the /tmp fallback directly.
# Capture the event baseline before starting the sidecar; an immediate teardown
# must not be mistaken for an old event while the watcher is being scheduled.
BASELINE_SD_STOP=$(read_stop_marker "$SD_STOP_MARKER")
BASELINE_TMP_STOP=$(read_stop_marker "$TMP_STOP_MARKER")
BASELINE_FLAT_STOP=$(read_stop_marker "$FLAT_STOP_MARKER")
FIFO="$VOLATILE/output.fifo"
if [ -n "$LOG_HELPER" ] && { [ -p "$FIFO" ] || mkfifo "$FIFO" 2>/dev/null; }; then
  (
    exec 3< "$FIFO" || exit 0
    /bin/sh "$LOG_HELPER" pipe mirror "$TMP_LOGFILE" <&3 ||
      { cat <&3 >> "$TMP_LOGFILE" 2>/dev/null || cat <&3 > /dev/null; }
  ) &
  LD_PRELOAD= "$BIN" $MIRROR_ARGS > "$FIFO" 2>&1 &
else
  LOGFILE="$TMP_LOGFILE"
  if ( : >> "$TMP_LOGFILE" ) 2>/dev/null; then
    LD_PRELOAD= "$BIN" $MIRROR_ARGS >>"$TMP_LOGFILE" 2>&1 &
  else
    LD_PRELOAD= "$BIN" $MIRROR_ARGS >/dev/null 2>&1 &
  fi
fi
PID=$!
echo "$PID" > "$PIDFILE"

# The QNX sidecar deliberately freezes the last decoded frame through temporary
# stalls. The stock hook already emits DIRECT111_TAP_STOP only when the private
# stream is really torn down. Observe the asynchronous stop marker:
# teardown -> SIGTERM sidecar -> marker(false) -> Java releases Context80.
# If BaseVideo demand remains active, start a fresh sidecar so a later CarPlay
# reconnect can consume the next PHONE_REQUEST_111 gate without rebooting MMI.
if [ "$SINK_TEST_GRID_MODE" = "0" ]; then
  WATCH_LOG=/dev/null
  WATCH_FIFO="$VOLATILE/watch.fifo"
  if [ -n "$LOG_HELPER" ] && { [ -p "$WATCH_FIFO" ] || mkfifo "$WATCH_FIFO" 2>/dev/null; }; then
    (
      exec 3< "$WATCH_FIFO" || exit 0
      /bin/sh "$LOG_HELPER" pipe mirror "$TMP_LOGFILE" <&3 ||
        { cat <&3 >> "$TMP_LOGFILE" 2>/dev/null || cat <&3 > /dev/null; }
    ) &
    WATCH_LOG=$WATCH_FIFO
  elif ( : >> "$TMP_LOGFILE" ) 2>/dev/null; then
    WATCH_LOG=$TMP_LOGFILE
  fi
  (
    # Before first present, a new stop marker ends the current attempt.
    while [ ! -f "$STOP_GUARD" ] && [ ! -f "$BASE_READY" ]; do
      if ! sidecar_is_current; then
        rm -f "$WATCH_PIDFILE"
        schedule_abnormal_restart "before_first_present" || true
        exit 0
      fi

      if tap_stop_changed; then
        echo "LIFECYCLE_WATCH=PRIVATE111_STOP detected=1 phase=before_first_present sidecar_pid=$PID source=$CURRENT_STOP_SOURCE action=TERM_AND_RESTART_IF_DEMAND"
        kill -TERM "$PID" 2>/dev/null || true
        WAIT_N=0
        while kill -0 "$PID" 2>/dev/null && [ "$WAIT_N" -lt 10 ]; do
          sleep 1
          WAIT_N=$((WAIT_N + 1))
        done
        if kill -0 "$PID" 2>/dev/null; then
          echo "LIFECYCLE_WATCH=SIDECAR_TERM_TIMEOUT phase=before_first_present action=KILL pid=$PID"
          kill -KILL "$PID" 2>/dev/null || true
        fi
        rm -f "$PIDFILE" "$READY" "$BASE_READY" "$WATCH_PIDFILE"

        if [ -f "$DEMAND" ] && [ ! -f "$STOP_GUARD" ]; then
          echo "LIFECYCLE_WATCH=RESTART_NEXT_SESSION phase=before_first_present demand=$DEMAND gate_policy=next_PHONE_REQUEST_111"
          ALT111_MIRROR_RESTART_REASON=private111_session_end \
          ALT111_MIRROR_RESTART_COUNT=0 \
          ALT111_RECOVER_CURRENT_SESSION=0 \
            log_relaunch &
        fi
        exit 0
      fi
      sleep 1
    done

    sidecar_is_current || {
      schedule_abnormal_restart "before_watch_armed" || true
      exit 0
    }
    [ ! -f "$STOP_GUARD" ] || exit 0

    echo "LIFECYCLE_WATCH=ARMED sidecar_pid=$PID stop_marker=$SD_STOP_MARKER base_ready=$BASE_READY"

    while [ ! -f "$STOP_GUARD" ]; do
      if ! sidecar_is_current; then
        rm -f "$WATCH_PIDFILE"
        schedule_abnormal_restart "after_first_present" || true
        exit 0
      fi
      if tap_stop_changed; then
        echo "LIFECYCLE_WATCH=PRIVATE111_STOP detected=1 sidecar_pid=$PID source=$CURRENT_STOP_SOURCE action=TERM_AND_RESTART_IF_DEMAND"
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
          ALT111_MIRROR_RESTART_REASON=private111_session_end \
          ALT111_MIRROR_RESTART_COUNT=0 \
          ALT111_RECOVER_CURRENT_SESSION=0 \
            log_relaunch &
        else
          echo "LIFECYCLE_WATCH=NO_RESTART demand_present=$([ -f "$DEMAND" ] && echo 1 || echo 0) explicit_stop=$([ -f "$STOP_GUARD" ] && echo 1 || echo 0)"
        fi
        exit 0
      fi
      sleep 1
    done
  ) >>"$WATCH_LOG" 2>&1 &
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
  if schedule_abnormal_restart "startup_probe"; then
    echo "MIRROR_DISPLAY=RECOVERY_SCHEDULED current_session_validation=required"
    exit 0
  fi
  exit 3
fi

echo "MIRROR_DISPLAY=STARTED pid=$PID log=$LOGFILE volatile_mode=$VOLATILE_MODE sink_test_grid=$SINK_TEST_GRID_MODE"
if [ "$SINK_TEST_GRID_MODE" = 1 ]; then
  echo "WAITING_FOR=BASEVIDEO_ACTIVE_then_Java_CTX80 test_grid_already_presented=1"
else
  echo "WAITING_FOR=PHONE_REQUEST_111_then_H264_TAP_then_DECODER_FIRST_FRAME_then_DISPLAYABLE3"
fi
