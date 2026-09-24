#!/bin/sh
# V3.4 stream-driven display supervisor.
# private111 negotiation/production is always owned by the preloaded native hook.
# This process only starts the display consumer after the current private111
# producer has published a stable decoded stream marker.
set -eu

PATH=${PATH:+$PATH:}/proc/boot:/armle/bin:/armle/scripts:/bin:/usr/bin:/usr/sbin:/sbin:/mnt/app/armle/bin:/mnt/app/armle/sbin:/mnt/app/armle/usr/bin:/mnt/app/armle/usr/sbin:/eso/bin:/eso/bin/apps
export PATH

case "$0" in
  */*) ROOT=${0%/*} ;;
  *) ROOT=. ;;
esac
ROOT=$(CDPATH= cd "$ROOT" 2>/dev/null && pwd) || exit 2

TMP_ROOT="${ALT111_MIRROR_TMP_ROOT:-/tmp}"
PIDFILE="$TMP_ROOT/altscreen_stream_supervisor.pid"
STATEFILE="$TMP_ROOT/altscreen_stream_supervisor.active"
LOGFILE="$TMP_ROOT/altscreen_stream_supervisor.log"
STREAM_READY="$TMP_ROOT/altscreen-private111.stream-ready"
ACTIVE="${ALT111_MIRROR_ACTIVE_FILE:-/tmp/mmi-mirror-active}"
MIRROR_PID="$TMP_ROOT/altscreen_mirror.pid"
START="$ROOT/start_vehicle.sh"
STOP="$ROOT/stop_vehicle.sh"

[ -x "$START" ] || { echo "ERROR missing start_vehicle.sh" >&2; exit 2; }
[ -x "$STOP" ] || { echo "ERROR missing stop_vehicle.sh" >&2; exit 2; }

if [ -f "$PIDFILE" ]; then
  OLD=$(cat "$PIDFILE" 2>/dev/null || true)
  if [ -n "$OLD" ] && kill -0 "$OLD" 2>/dev/null; then
    echo "STREAM_SUPERVISOR=ALREADY_RUNNING pid=$OLD"
    exit 0
  fi
  rm -f "$PIDFILE"
fi

echo "$$" > "$PIDFILE"
: > "$LOGFILE"
echo "STREAM_SUPERVISOR=STARTED pid=$$ policy=private111_stable_frames_no_fixed_delay marker=$STREAM_READY" >> "$LOGFILE"

read_stream_key() {
  [ -s "$STREAM_READY" ] || return 1
  producer_pid=$(sed -n 's/^pid=//p' "$STREAM_READY" 2>/dev/null | head -n 1)
  generation=$(sed -n 's/^generation=//p' "$STREAM_READY" 2>/dev/null | head -n 1)
  cookie=$(sed -n 's/^cookie=//p' "$STREAM_READY" 2>/dev/null | head -n 1)
  frames=$(sed -n 's/^frames=//p' "$STREAM_READY" 2>/dev/null | head -n 1)
  case "$producer_pid" in ''|*[!0-9]*) return 1 ;; esac
  case "$generation" in ''|*[!0-9]*) return 1 ;; esac
  case "$frames" in ''|*[!0-9]*) return 1 ;; esac
  [ "$generation" -gt 0 ] || return 1
  [ "$frames" -ge 2 ] || return 1
  [ -n "$cookie" ] || return 1
  kill -0 "$producer_pid" 2>/dev/null || return 1
  printf '%s:%s:%s\n' "$producer_pid" "$generation" "$cookie"
}

mirror_running() {
  [ -s "$MIRROR_PID" ] || return 1
  mpid=$(cat "$MIRROR_PID" 2>/dev/null || true)
  case "$mpid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$mpid" 2>/dev/null
}

stop_display() {
  rm -f "$ACTIVE" 2>/dev/null || true
  ALT111_SUPERVISOR_CHILD=1 /bin/sh "$STOP" >> "$LOGFILE" 2>&1 || true
  rm -f "$STATEFILE" 2>/dev/null || true
}

cleanup() {
  trap - 0 1 2 15
  stop_display
  rm -f "$PIDFILE" 2>/dev/null || true
  echo "STREAM_SUPERVISOR=STOPPED pid=$$" >> "$LOGFILE" 2>/dev/null || true
}
trap cleanup 0 1 2 15

while :; do
  KEY=$(read_stream_key 2>/dev/null || true)
  OLD_KEY=$(cat "$STATEFILE" 2>/dev/null || true)

  if [ -n "$KEY" ]; then
    if [ -n "$OLD_KEY" ] && [ "$OLD_KEY" != "$KEY" ]; then
      echo "STREAM_SESSION_CHANGE old=$OLD_KEY new=$KEY action=RESTART_DISPLAY" >> "$LOGFILE"
      stop_display
      OLD_KEY=""
    fi

    if ! mirror_running; then
      echo "STREAM_READY key=$KEY action=START_DISPLAY recover_current_session=1" >> "$LOGFILE"
      touch "$ACTIVE"
      if ALT111_STREAM_SUPERVISED=1 ALT111_RECOVER_CURRENT_SESSION=1 /bin/sh "$START" >> "$LOGFILE" 2>&1; then
        printf '%s\n' "$KEY" > "$STATEFILE"
      else
        rc=$?
        rm -f "$ACTIVE" "$STATEFILE" 2>/dev/null || true
        echo "STREAM_DISPLAY_START_FAILED key=$KEY rc=$rc fail_open=YES" >> "$LOGFILE"
      fi
    else
      [ -f "$ACTIVE" ] || touch "$ACTIVE"
      [ "$OLD_KEY" = "$KEY" ] || printf '%s\n' "$KEY" > "$STATEFILE"
    fi
  else
    if mirror_running || [ -f "$ACTIVE" ] || [ -s "$STATEFILE" ]; then
      echo "STREAM_NOT_READY action=STOP_DISPLAY" >> "$LOGFILE"
      stop_display
    fi
  fi

  sleep 1
done
