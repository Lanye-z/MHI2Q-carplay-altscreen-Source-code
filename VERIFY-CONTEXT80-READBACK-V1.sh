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
HOOK_SOURCE="$ROOT/Toolbox/carplay_alt_screen/src/altscreen_hook.c"
PRIVATE111_SOURCE="$ROOT/Toolbox/carplay_alt_screen/src/p1404_private111_backend.c"

fail(){ echo "CONTEXT80_READBACK_VERIFY=FAIL: $*" >&2; exit 1; }
binary_strings(){ strings "$1" 2>/dev/null || grep -a -o '[[:print:]][[:print:]]*' "$1"; }
sha256_file(){
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print tolower($1)}'
  else shasum -a 256 "$1" | awk '{print tolower($1)}'; fi
}

for s in "$START" "$STATUS" "$CTRL" "$ROUTER"   "$ROOT/Toolbox/scripts/install_mmi_cockpit_carplay_rx.sh"   "$ROOT/Toolbox/scripts/stop_mmi_cockpit_carplay_test.sh"   "$MIRROR_START"   "$ROOT/Toolbox/carplay_alt_screen/mirror_display/release/stop_vehicle.sh"; do
  sh -n "$s" || fail "shell syntax: $s"
done

[ -s "$HOOK" ] || fail "universal hook missing"
binary_strings "$HOOK" | grep -Fq 'identity_override=DISABLED' ||
  fail "runtime hook lacks strict child-process identity containment"
binary_strings "$HOOK" | grep -Fq '/mnt/app/root/carplay-altscreen/lib/libcarplay_altscreen.so' ||
  fail "runtime hook lacks self-preload token"
grep -Fq 'altscreen_strip_self_from_child_preload();' "$HOOK_SOURCE" ||
  fail "source does not strip AltScreen from child LD_PRELOAD"
grep -Fq 'if (!process_allowed || !p1404_probe_stack())' "$HOOK_SOURCE" ||
  fail "source does not enforce measured process identity"
if grep -Fq '(!process_allowed && !force_start)' "$HOOK_SOURCE"; then
  fail "FORCE_START can still bypass process identity"
fi

python3 - "$PRIVATE111_SOURCE" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
accept = text.index('PHASE=STREAM_111_ACCEPT_RETURN')
net = text.index('be.net_socket_create_native(&net_socket, native_fd)', accept)
start = text.index('PHASE=STREAM_111_START_CALL', net)
if 'pair_close_firewall(p, "listener_closed")' in text[accept:net]:
    raise SystemExit('post-accept path still performs synchronous PF cleanup')
if not (accept < net < start):
    raise SystemExit('Private111 checkpoint ordering drift')
teardown = text.index('static int teardown_private')
delete = text.index('if (be.del) be.del(alt_screen_session);', teardown)
fw = text.index('pair_close_firewall(p, "teardown_post_session")', delete)
if not delete < fw:
    raise SystemExit('PF cleanup must remain after private ScreenSession delete')
print('PRIVATE111_POSTACCEPT_GATE=PASS accept_to_netsocket_pf_free=1 teardown_pf_after_delete=1')
PY
binary_strings "$HOOK" | grep -Fq 'displayable=58' ||
  fail "runtime hook is not the Window58 producer"

[ -s "$MIRROR" ] || fail "readback sidecar missing"
binary_strings "$MIRROR" | grep -Fq 'screen_read_window' || fail "sidecar lacks readback"
if binary_strings "$MIRROR" | grep -Fq '/eso/bin/apps/dmdt sc 1 76'; then
  fail "sidecar still writes context76"
fi

[ -s "$BRIDGE" ] || fail "Window58 ID-string bridge release artifact missing"
binary_strings "$BRIDGE" | grep -Fq 'SCREEN_ID_DLSYM_BRIDGE=READY' ||
  fail "ID bridge does not intercept the V4 dlsym lookup"
binary_strings "$BRIDGE" | grep -Fq 'WINDOW58_ID_BRIDGE' ||
  fail "ID bridge target marker missing"
binary_strings "$BRIDGE" | grep -Fq 'screen_get_window_property_cv' ||
  fail "ID bridge does not read Screen owner identity"
binary_strings "$BRIDGE" | grep -Fq 'ID_STRING(20)' ||
  fail "ID bridge is not using SCREEN_PROPERTY_ID_STRING=20"
grep -Fq 'numeric == 58' "$ROOT/Toolbox/carplay_alt_screen/mirror_display/src/screen_id_bridge.c" ||
  fail "ID bridge lacks fail-closed numeric-58 suppression"
grep -Fq 'LD_PRELOAD="$ID_BRIDGE" "$BIN"' "$MIRROR_START" ||
  fail "sidecar launcher does not isolate/load ID bridge"
grep -Fq 'SIDECAR_PRELOAD_POLICY=ISOLATED' "$MIRROR_START" ||
  fail "sidecar preload isolation marker missing"

grep -Fq 'get_window_cv_' "$SOURCE_H" ||
  fail "vendored Window58 source lacks character-property accessor"
grep -Fq 'SCREEN_PROPERTY_ID_STRING 20' "$SOURCE" ||
  fail "vendored Window58 source does not use owner-defined ID_STRING"
grep -Fq 'id_string' "$SOURCE" ||
  fail "vendored Window58 source lacks string identity diagnostics"
grep -Fq 'match_basis' "$SOURCE" ||
  fail "vendored Window58 source lacks ID_STRING match diagnostics"
if grep -Fq 'NUMERIC_FALLBACK' "$SOURCE"; then
  fail "vendored Window58 source still permits numeric-ID target fallback"
fi

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
grep -Fq 'WINDOW58_IDENTITY=ID_STRING_MATCH' "$STATUS" ||
  fail "STATUS does not expose Window58 string identity"
grep -q 'PHYSICAL_ROUTE_READY=SOFTWARE_CHAIN_COMPLETE' "$STATUS" ||
  fail "split route completion gate missing"
grep -q 'rm -f "$STATE_DIR/FULL_CHAIN_MODE" "$STATE_DIR/NATIVE_DISPLAY_MODE"' "$CTRL" ||
  fail "legacy native route markers not cleared"
grep -q 'libscreen_id_bridge.so' "$ROUTER" ||
  fail "router does not stage the ID bridge"

echo "CONTEXT80_READBACK_VERIFY=PASS"
echo "carplay_runtime_hook=PRIVATE111_POSTACCEPT_NONBLOCKING_PF_CHILD_PRELOAD_ISOLATED sha256=$(sha256_file "$HOOK")"
echo "source=Window58 identity=SCREEN_PROPERTY_ID_STRING_20_PRIMARY"
echo "capture=screen_read_window"
echo "sink=displayable3_gles"
echo "context_owner=JAVA80 actual_readback=REQUIRED"
echo "native_context_runtime_gate=MARKERS_DISABLED"
echo "native_context_source_gate=HARD_DISABLED_SOURCE_ONLY"
