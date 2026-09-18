#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HOOK="$ROOT/Toolbox/carplay_alt_screen/universal/libcarplay_altscreen.so"
MIRROR="$ROOT/Toolbox/carplay_alt_screen/mirror_display/release/carplay-alt111-mirror-display"
BRIDGE="$ROOT/Toolbox/carplay_alt_screen/mirror_display/release/libscreen_id_bridge.so"
MIRROR_START="$ROOT/Toolbox/carplay_alt_screen/mirror_display/release/start_vehicle.sh"
SOURCE="$ROOT/Toolbox/carplay_alt_screen/mirror_display/src/carplay_window_source.cpp"
SOURCE_H="$ROOT/Toolbox/carplay_alt_screen/mirror_display/src/carplay_window_source.h"
JAR="$ROOT/Toolbox/carplay_alt_screen/hmi/carplay_hook-basevideo3.jar"
START="$ROOT/Toolbox/scripts/start_mmi_cockpit_carplay_rx_test.sh"
STATUS="$ROOT/Toolbox/scripts/status_mmi_cockpit_carplay_test.sh"
CTRL="$ROOT/Toolbox/scripts/altscreen_chain_test_universal.sh"
ROUTER="$ROOT/Toolbox/scripts/altscreen_chain_test.sh"
NATIVE="$ROOT/Toolbox/carplay_alt_screen/src/p1404_cockpit_native.c"
HEADER="$ROOT/Toolbox/carplay_alt_screen/src/p1404_cockpit_native.h"
PINNED_HOOK_SHA=07a96cad6121cfc9fae259d47e6c95142b5e09b7ef3e8cd7a180de009579cb39

fail(){ echo "CONTEXT80_READBACK_VERIFY=FAIL: $*" >&2; exit 1; }
binary_strings(){ strings "$1" 2>/dev/null || grep -a -o '[[:print:]][[:print:]]*' "$1"; }
sha256_file(){
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print tolower($1)}'
  else shasum -a 256 "$1" | awk '{print tolower($1)}'; fi
}

for s in "$START" "$STATUS" "$CTRL" "$ROUTER"   "$ROOT/Toolbox/scripts/install_mmi_cockpit_carplay_rx.sh"   "$ROOT/Toolbox/scripts/stop_mmi_cockpit_carplay_test.sh"   "$MIRROR_START"   "$ROOT/Toolbox/carplay_alt_screen/mirror_display/release/stop_vehicle.sh"; do
  sh -n "$s" || fail "shell syntax: $s"
done

[ -s "$HOOK" ] || fail "known-good universal hook missing"
[ "$(sha256_file "$HOOK")" = "$PINNED_HOOK_SHA" ] ||
  fail "CarPlay-facing runtime hook drifted from known-good 07a96 baseline"
binary_strings "$HOOK" | grep -Fq 'displayable=58' ||
  fail "known-good hook is not the Window58 producer"

[ -s "$MIRROR" ] || fail "readback sidecar missing"
binary_strings "$MIRROR" | grep -Fq 'screen_read_window' || fail "sidecar lacks readback"
if binary_strings "$MIRROR" | grep -Fq '/eso/bin/apps/dmdt sc 1 76'; then
  fail "sidecar still writes context76"
fi

[ -s "$BRIDGE" ] || fail "Window58 ID-string bridge release artifact missing"
binary_strings "$BRIDGE" | grep -Fq 'WINDOW58_ID_BRIDGE' ||
  fail "ID bridge marker missing"
binary_strings "$BRIDGE" | grep -Fq 'screen_get_window_property_cv' ||
  fail "ID bridge does not read Screen string identity"
grep -Fq 'LD_PRELOAD="$ID_BRIDGE" "$BIN"' "$MIRROR_START" ||
  fail "sidecar launcher does not isolate/load ID bridge"
grep -Fq 'SIDECAR_PRELOAD_POLICY=ISOLATED' "$MIRROR_START" ||
  fail "sidecar preload isolation marker missing"

grep -Fq 'get_window_cv_' "$SOURCE_H" ||
  fail "vendored Window58 source lacks character-property accessor"
grep -Fq 'id_string' "$SOURCE" ||
  fail "vendored Window58 source lacks string identity diagnostics"
grep -Fq 'match_basis' "$SOURCE" ||
  fail "vendored Window58 source lacks STRING/fallback match diagnostics"

[ -s "$JAR" ] || fail "Java80 HMI JAR missing"
if command -v unzip >/dev/null 2>&1; then
  TMP_CLASS="${TMPDIR:-/tmp}/ctx80-controller.$$.class"
  unzip -p "$JAR" com/luka/carplay/cluster/ClusterStateController.class > "$TMP_CLASS" ||
    fail "ClusterStateController.class missing from JAR"
  binary_strings "$TMP_CLASS" | grep -Fq 'CTX80_OBSERVED' ||
    fail "JAR lacks positive ctx80 readback proof marker"
  binary_strings "$TMP_CLASS" | grep -Fq 'getCurrentContextID' ||
    fail "JAR lacks actual-context HMI readback"
  rm -f "$TMP_CLASS"
else
  binary_strings "$JAR" | grep -Fq 'CTX80_OBSERVED' ||
    fail "JAR lacks ctx80 proof marker"
fi

grep -Eq '#define[[:space:]]+ALT111_DISPLAYABLE_ID[[:space:]]+58u' "$HEADER" ||
  fail "source identity is not Window58"
grep -A7 'static int native_route_requested' "$NATIVE" | grep -q 'return 0;' ||
  fail "vendored source does not hard-disable native context writes"
grep -q 'annexb_observer_optional=1' "$NATIVE" ||
  fail "vendored source AVCC observer policy missing"

grep -q 'READBACK_SIDECAR=RUNNING_OR_WAITING_FOR_PHONE_REQUEST_111' "$START" ||
  fail "START does not launch sidecar"
grep -q 'meaning=destination_first_successful_gles_present' "$START" ||
  fail "destination-ready semantics missing"
grep -Fq 'JAVA_CTX80_ACTUAL=80 source=IDisplayManager.getCurrentContextID' "$STATUS" ||
  fail "STATUS does not require actual ctx80 readback"
grep -Fq 'WINDOW58_IDENTITY=STRING_MATCH' "$STATUS" ||
  fail "STATUS does not expose Window58 string identity"
grep -q 'PHYSICAL_ROUTE_READY=SOFTWARE_CHAIN_COMPLETE' "$STATUS" ||
  fail "split route completion gate missing"
grep -q 'rm -f "$STATE_DIR/FULL_CHAIN_MODE" "$STATE_DIR/NATIVE_DISPLAY_MODE"' "$CTRL" ||
  fail "legacy native route markers not cleared"
grep -q 'libscreen_id_bridge.so' "$ROUTER" ||
  fail "router does not stage the ID bridge"

echo "CONTEXT80_READBACK_VERIFY=PASS"
echo "carplay_runtime_hook=PINNED_KNOWN_GOOD sha256=$PINNED_HOOK_SHA"
echo "source=Window58 identity=ID_STRING_PRIMARY"
echo "capture=screen_read_window"
echo "sink=displayable3_gles"
echo "context_owner=JAVA80 actual_readback=REQUIRED"
echo "native_context_runtime_gate=MARKERS_DISABLED"
echo "native_context_source_gate=HARD_DISABLED_SOURCE_ONLY"
