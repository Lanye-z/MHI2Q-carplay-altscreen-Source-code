#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HOOK="$ROOT/Toolbox/carplay_alt_screen/universal/libcarplay_altscreen.so"
MIRROR="$ROOT/Toolbox/carplay_alt_screen/mirror_display/release/carplay-alt111-mirror-display"
START="$ROOT/Toolbox/scripts/start_mmi_cockpit_carplay_rx_test.sh"
STATUS="$ROOT/Toolbox/scripts/status_mmi_cockpit_carplay_test.sh"
CTRL="$ROOT/Toolbox/scripts/altscreen_chain_test_universal.sh"
ROUTER="$ROOT/Toolbox/scripts/altscreen_chain_test.sh"
NATIVE="$ROOT/Toolbox/carplay_alt_screen/src/p1404_cockpit_native.c"
HEADER="$ROOT/Toolbox/carplay_alt_screen/src/p1404_cockpit_native.h"
fail(){ echo "CONTEXT80_READBACK_VERIFY=FAIL: $*" >&2; exit 1; }
binary_strings(){ strings "$1" 2>/dev/null || grep -a -o '[[:print:]][[:print:]]*' "$1"; }

for s in "$START" "$STATUS" "$CTRL" "$ROUTER"  "$ROOT/Toolbox/scripts/install_mmi_cockpit_carplay_rx.sh"  "$ROOT/Toolbox/scripts/stop_mmi_cockpit_carplay_test.sh"  "$ROOT/Toolbox/carplay_alt_screen/mirror_display/release/start_vehicle.sh"  "$ROOT/Toolbox/carplay_alt_screen/mirror_display/release/stop_vehicle.sh"; do
  sh -n "$s" || fail "shell syntax: $s"
done

[ -s "$HOOK" ] || fail "Window58 producer hook missing"
[ -s "$MIRROR" ] || fail "readback sidecar missing"
binary_strings "$HOOK" | grep -Fq 'displayable=58' || fail "hook is not Window58 producer"
binary_strings "$MIRROR" | grep -Fq 'screen_read_window' || fail "sidecar lacks readback"
if binary_strings "$MIRROR" | grep -Fq '/eso/bin/apps/dmdt sc 1 76'; then fail "sidecar still writes context76"; fi

grep -Eq '#define[[:space:]]+ALT111_DISPLAYABLE_ID[[:space:]]+58u' "$HEADER" || fail "source identity is not Window58"
grep -A7 'static int native_route_requested' "$NATIVE" | grep -q 'return 0;' || fail "native context writer not hard-disabled"
grep -q 'annexb_observer_optional=1' "$NATIVE" || fail "AVCC observer policy missing"
grep -q 'READBACK_SIDECAR=RUNNING_OR_WAITING_FOR_PHONE_REQUEST_111' "$START" || fail "START does not launch sidecar"
grep -q 'meaning=destination_first_successful_gles_present' "$START" || fail "destination-ready semantics missing"
grep -q 'PHYSICAL_ROUTE_READY=SOFTWARE_CHAIN_COMPLETE' "$STATUS" || fail "split status gates missing"
grep -q 'rm -f "$STATE_DIR/FULL_CHAIN_MODE" "$STATE_DIR/NATIVE_DISPLAY_MODE"' "$CTRL" || fail "legacy native route markers not cleared"
grep -q 'MIRROR_SD=' "$ROUTER" || fail "router does not stage sidecar"

echo "CONTEXT80_READBACK_VERIFY=PASS"
echo "source=Window58"
echo "capture=screen_read_window"
echo "sink=displayable3_gles"
echo "context_owner=JAVA80"
echo "native_context_writer=DISABLED"
