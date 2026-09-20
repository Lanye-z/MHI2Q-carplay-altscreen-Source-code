#!/bin/sh
# Host fixture: stale marker is ignored, a fresh marker ends the live sidecar.
set -eu
LAUNCH=$(CDPATH= cd -- "$(dirname -- "$0")/../mirror_display/release" && pwd)/start_vehicle.sh
ROOT=$(mktemp -d)
case "$ROOT" in /tmp/*|/var/tmp/*) ;; *) exit 2 ;; esac
cleanup() {
    if [ -f "$ROOT/tmp/MMI-Cockpit-Carplay/mirror/pid" ]; then
        pid=$(cat "$ROOT/tmp/MMI-Cockpit-Carplay/mirror/pid" 2>/dev/null || true)
        [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
    fi
    if [ -f "$ROOT/tmp/MMI-Cockpit-Carplay/mirror/lifecycle.pid" ]; then
        pid=$(cat "$ROOT/tmp/MMI-Cockpit-Carplay/mirror/lifecycle.pid" 2>/dev/null || true)
        [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null || true
    fi
    rm -rf "$ROOT"
}
trap cleanup 0
CARD="$ROOT/card"
mkdir -p "$CARD/Toolbox" "$CARD/MMI-Cockpit-Carplay/state" "$CARD/MMI-Cockpit-Carplay/logs" "$ROOT/tmp"
MARKER="$CARD/MMI-Cockpit-Carplay/state/direct111_tap_stop.state"
printf 'OLD_EVENT\n' > "$MARKER"
cat > "$ROOT/mock-sidecar" <<'EOF'
#!/bin/sh
trap 'exit 0' TERM
while :; do sleep 1; done
EOF
chmod +x "$ROOT/mock-sidecar"
ALTSCREEN_CHAIN_TESTING=1 ALTSCREEN_CHAIN_VOLUME="$CARD" \
ALT111_MIRROR_TMP_ROOT="$ROOT/tmp" ALT111_MIRROR_BIN="$ROOT/mock-sidecar" \
ALT111_JAVA_BASE_READY_FILE="$ROOT/base.ready" \
sh "$LAUNCH" > "$ROOT/launch.out"
PIDFILE="$ROOT/tmp/MMI-Cockpit-Carplay/mirror/pid"
[ -s "$PIDFILE" ]
pid=$(cat "$PIDFILE")
sleep 2
kill -0 "$pid" 2>/dev/null
printf 'NEW_EVENT\n' > "$MARKER"
tries=0
while [ -e "$PIDFILE" ] && [ "$tries" -lt 6 ]; do
    sleep 1
    tries=$((tries + 1))
done
[ ! -e "$PIDFILE" ]
echo 'STOP_MARKER_WATCH_HOST_TEST=PASS'
