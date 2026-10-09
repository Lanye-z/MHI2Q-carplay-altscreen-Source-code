#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../../.." && pwd)
START="$ROOT/Toolbox/scripts/start_mmi_cockpit_carplay_rx_test.sh"
JAR="$ROOT/Toolbox/carplay_alt_screen/hmi/carplay_hook-basevideo3.jar"

fail(){ echo "START_AUTOSTART_TRANSACTION_TEST=FAIL: $*" >&2; exit 1; }

make_fixture(){
    base=$1
    live="$base/live"
    vol="$base/vol"
    app="$live/mnt/app/root/carplay-altscreen"
    mkdir -p "$app/bin/mirror" "$app/state" "$live/mnt/app/eso/hmi/lsd/jars"              "$live/mnt/system/etc/boot" "$live/tmp" "$vol/Toolbox/scripts"
    cp "$START" "$app/bin/start_mmi_cockpit_carplay_rx_test.sh"
    cp "$ROOT/Toolbox/scripts/altscreen_sd_writable.sh" "$vol/Toolbox/scripts/altscreen_sd_writable.sh"
    chmod 755 "$vol/Toolbox/scripts/altscreen_sd_writable.sh"
    cp "$JAR" "$live/mnt/app/eso/hmi/lsd/jars/carplay_hook.jar"

    cat > "$app/bin/altscreen_chain_test.sh" <<'MOCK_CTRL'
#!/bin/sh
state="$ALTSCREEN_CHAIN_VOLUME/MMI-Cockpit-Carplay/state"
mkdir -p "$state"
touch "$state/ACTIVE"
echo fixture_run > "$state/run_id"
echo fixture_session > "$state/session_path"
exit "${MOCK_CONTROLLER_RC:-0}"
MOCK_CTRL

    cat > "$app/bin/mirror/start_vehicle.sh" <<'MOCK_START'
#!/bin/sh
exit "${MOCK_MIRROR_RC:-0}"
MOCK_START
    cat > "$app/bin/mirror/stop_vehicle.sh" <<'MOCK_STOP'
#!/bin/sh
exit 0
MOCK_STOP
    cat > "$app/bin/mirror/stream_supervisor.sh" <<'MOCK_SUP'
#!/bin/sh
pf="$ALTSCREEN_CHAIN_ROOT/tmp/altscreen_stream_supervisor.pid"
old=$(cat "$pf" 2>/dev/null || true)
if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then exit 0; fi
sleep 300 &
pid=$!
echo "$pid" > "$pf"
exit 0
MOCK_SUP
    cat > "$app/bin/mirror/carplay-alt111-mirror-display" <<'MOCK_BIN'
#!/bin/sh
exit 0
MOCK_BIN
    chmod 755 "$app/bin/"*.sh "$app/bin/mirror/"*

    cat > "$live/mnt/system/etc/boot/startup.sh" <<'STOCK'
#!/bin/sh
echo stock-startup
STOCK
    chmod 755 "$live/mnt/system/etc/boot/startup.sh"
    printf '%s\n' "$live" "$vol"
}

run_start(){
    live=$1; vol=$2; out=$3
    shift 3
    env ALTSCREEN_CHAIN_TESTING=1 ALTSCREEN_CHAIN_ROOT="$live" ALTSCREEN_CHAIN_VOLUME="$vol" "$@"         /bin/sh "$live/mnt/app/root/carplay-altscreen/bin/start_mmi_cockpit_carplay_rx_test.sh" >"$out" 2>&1
}

tmp=${TMPDIR:-/tmp}/altscreen-start-autostart-test.$$
rm -rf "$tmp"
cleanup(){
    find "$tmp" -type f -name altscreen_stream_supervisor.pid 2>/dev/null | while IFS= read -r pf; do
        pid=$(cat "$pf" 2>/dev/null || true)
        [ -z "$pid" ] || kill "$pid" 2>/dev/null || true
    done
    rm -rf "$tmp"
}
trap cleanup EXIT HUP INT TERM
mkdir -p "$tmp"

# Success with a pre-existing state directory proves QNX-safe idempotent setup.
set -- $(make_fixture "$tmp/success")
live=$1; vol=$2
run_start "$live" "$vol" "$tmp/success1.log" || fail "first START failed"
grep -Fq 'START=PASS integrated=' "$tmp/success1.log" || fail "first START pass marker missing"
[ -f "$live/mnt/app/root/carplay-altscreen/state/basevideo3.enabled" ] || fail "boot-demand marker missing"
[ ! -e "$live/tmp/mmi-mirror-active" ] || fail "V3.4 asserted display demand before stream-ready"
[ -s "$live/tmp/altscreen_stream_supervisor.pid" ] || fail "stream supervisor pid missing"
sup=$(cat "$live/tmp/altscreen_stream_supervisor.pid" 2>/dev/null || true)
[ -n "$sup" ] && kill -0 "$sup" 2>/dev/null || fail "stream supervisor is not alive"
[ "$(grep -c '^# BEGIN ALT111 BASEVIDEO3 AUTOSTART$' "$live/mnt/system/etc/boot/startup.sh")" = 1 ] ||
    fail "autostart block count is not one"
grep -Fq '/tmp/altscreen_autostart.log' "$live/mnt/system/etc/boot/startup.sh" ||
    fail "autostart log path is not canonical"
grep -Fq '/mnt/app/root/carplay-altscreen/bin/mirror/stream_supervisor.sh' "$live/mnt/system/etc/boot/startup.sh" ||
    fail "V3.4 autostart does not launch the stream supervisor"
if grep -Fq 'touch /tmp/mmi-mirror-active' "$live/mnt/system/etc/boot/startup.sh"; then
    fail "V3.4 boot autostart still asserts display demand before stream-ready"
fi
if find "$live/mnt/system/etc/boot" -type f -name 'startup.sh.basevideo3.*' | grep -q .; then
    fail "START leaked transaction scratch into /mnt/system"
fi
if find "$live/tmp" -maxdepth 1 -type f -name 'altscreen_start_*' 2>/dev/null | grep -q .; then
    fail "START left flat volatile transaction files after success"
fi
ls "$vol/MMI-Cockpit-Carplay/logs/operations"/start_*.log >/dev/null 2>&1 ||
    fail "persistent START journal missing"

# Repeated START must stay idempotent even though state/basevideo3.enabled exists.
run_start "$live" "$vol" "$tmp/success2.log" || fail "repeated START failed"
grep -Fq 'START_COMPAT=BOOT_DEMAND_ALREADY_ENABLED' "$tmp/success2.log" ||
    fail "repeated START did not recognize existing boot demand"
[ "$(grep -c '^# BEGIN ALT111 BASEVIDEO3 AUTOSTART$' "$live/mnt/system/etc/boot/startup.sh")" = 1 ] ||
    fail "repeated START duplicated autostart block"

# A failing repeated controller must preserve the already-active transaction.
cp "$live/mnt/system/etc/boot/startup.sh" "$tmp/startup.before"
set +e
run_start "$live" "$vol" "$tmp/repeat_fail.log" MOCK_CONTROLLER_RC=7
rc=$?
set -e
[ "$rc" = 7 ] || fail "repeated controller failure rc=$rc expected=7"
cmp -s "$tmp/startup.before" "$live/mnt/system/etc/boot/startup.sh" ||
    fail "repeated failure did not restore startup.sh"
[ -f "$vol/MMI-Cockpit-Carplay/state/ACTIVE" ] ||
    fail "pre-existing controller transaction state was incorrectly removed"
[ -f "$live/mnt/app/root/carplay-altscreen/state/basevideo3.enabled" ] ||
    fail "pre-existing boot demand was incorrectly removed"
[ ! -e "$live/tmp/mmi-mirror-active" ] ||
    fail "repeated START incorrectly asserted display demand without stream-ready"
grep -Fq 'START_FAIL_STAGE=CONTROLLER_START rc=7' "$tmp/repeat_fail.log" ||
    fail "repeated failure stage/rc diagnostic missing"

# A first START that fails after the controller partially arms must fully disarm
# the new transaction and restore stock startup content.
set -- $(make_fixture "$tmp/freshfail")
live2=$1; vol2=$2
cp "$live2/mnt/system/etc/boot/startup.sh" "$tmp/fresh.before"
set +e
run_start "$live2" "$vol2" "$tmp/fresh_fail.log" MOCK_CONTROLLER_RC=7
rc=$?
set -e
[ "$rc" = 7 ] || fail "fresh controller failure rc=$rc expected=7"
cmp -s "$tmp/fresh.before" "$live2/mnt/system/etc/boot/startup.sh" ||
    fail "fresh failure did not restore stock startup.sh"
[ ! -e "$live2/mnt/app/root/carplay-altscreen/state/basevideo3.enabled" ] ||
    fail "fresh failure left boot-demand marker"
[ ! -e "$live2/tmp/mmi-mirror-active" ] ||
    fail "fresh failure left current-boot demand"
for marker in ACTIVE run_id session_path; do
    [ ! -e "$vol2/MMI-Cockpit-Carplay/state/$marker" ] || fail "fresh failure left controller marker $marker"
done
[ ! -e "$live2/mnt/app/root/carplay-altscreen/state/fullchain_probe" ] ||
    fail "V3.4 unexpectedly created a runtime authorization probe"
grep -Fq 'START_ROLLBACK_CONTROLLER=DISARMED_NEW_TRANSACTION' "$tmp/fresh_fail.log" ||
    fail "fresh failure controller rollback diagnostic missing"
grep -Fq 'START_ROLLBACK_AUTOSTART=RESTORED' "$tmp/fresh_fail.log" ||
    fail "fresh failure startup rollback diagnostic missing"
if find "$live2/mnt/system/etc/boot" -type f -name 'startup.sh.basevideo3.*' | grep -q .; then
    fail "failed START leaked transaction scratch into /mnt/system"
fi

echo "START_AUTOSTART_TRANSACTION_TEST=PASS idempotent_state=1 persistent_journal=1 rollback=transactional stream_supervisor=1 demand_before_stream=0 canonical_autolog=1 system_scratch=tmp_only"
