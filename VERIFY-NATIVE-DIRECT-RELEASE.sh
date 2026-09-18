#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HOOK="$ROOT/Toolbox/carplay_alt_screen/universal/libcarplay_altscreen.so"
NATIVE="$ROOT/Toolbox/carplay_alt_screen/src/p1404_cockpit_native.c"
START="$ROOT/Toolbox/scripts/start_mmi_cockpit_carplay_rx_test.sh"
CTRL="$ROOT/Toolbox/scripts/altscreen_chain_test_universal.sh"
TOP="$ROOT/SHA256SUMS.txt"
MAP="$ROOT/PACKAGE_SOURCE_MAP.json"
REL="$ROOT/Toolbox/carplay_alt_screen/mirror_display/release/SHA256SUMS"

fail(){ echo "NATIVE_DIRECT_VERIFY=FAIL: $*" >&2; exit 1; }
sha256_file(){
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    else shasum -a 256 "$1" | awk '{print $1}'; fi
}
binary_strings(){ strings "$1" 2>/dev/null || grep -a -o '[[:print:]][[:print:]]*' "$1"; }

[ -s "$HOOK" ] || fail "hook missing"
for marker in   'PHASE=NATIVE_111_MANAGED_WINDOW'   'PHASE=NATIVE_111_ROUTE_ACTIVATE_RESULT'   'PHASE=NATIVE_111_COCKPIT_ACTIVE'   'screen_manage_window'   'displayable=58 context=76'
do
    binary_strings "$HOOK" | grep -Fq "$marker" || fail "direct-native hook marker missing: $marker"
done

binary_strings "$HOOK" | grep -Fq 'identity_override=DISABLED' &&
    fail "helper-isolation runtime unexpectedly present" || true

grep -q 'return altscreen_marker_present("FULL_CHAIN_MODE")' "$NATIVE" ||
    fail "native route is not marker-driven"
grep -q 'altscreen_marker_present("NATIVE_DISPLAY_MODE")' "$NATIVE" ||
    fail "native display marker missing"
grep -q 'g_screen_manage_window(window, DISPLAY_MANAGER_SECRET)' "$NATIVE" ||
    fail "DisplayManager native ownership handoff missing"
grep -q 'run_dmdt("dc", "76", "58")' "$NATIVE" ||
    fail "displayable58/context76 route missing"
grep -q 'run_dmdt("sc", "1", "74")' "$NATIVE" ||
    fail "context74 restore missing"
grep -q 'SCREEN_DISPLAY_MANAGER_CONTEXT' "$NATIVE" ||
    fail "DisplayManager geometry context missing"
if grep -q 'SCREEN_WINDOW_MANAGER_CONTEXT' "$NATIVE"; then
    fail "WindowManager context is forbidden in native-direct runtime"
fi

grep -q 'MIRROR_POLICY=DISABLED' "$START" || fail "native START does not disable Mirror"
if grep -q 'MIRROR_AUTOSTART=ENABLED' "$START"; then
    fail "Mirror autostart leaked into native-direct START"
fi
grep -q 'NATIVE_DISPLAY_MODE' "$CTRL" || fail "controller does not arm native display mode"

hook_sha=$(sha256_file "$HOOK")
top_sha=$(awk '$2 == "Toolbox/carplay_alt_screen/universal/libcarplay_altscreen.so" {print $1}' "$TOP")
map_sha=$(sed -n 's/.*"Toolbox\/carplay_alt_screen\/universal\/libcarplay_altscreen.so": "\([0-9a-fA-F]*\)".*/\1/p' "$MAP")
rel_sha=$(awk '$2 == "libcarplay_altscreen.so" {print $1}' "$REL")
[ "$hook_sha" = "$top_sha" ] || fail "top manifest hook mismatch"
[ "$hook_sha" = "$map_sha" ] || fail "package map hook mismatch"
[ "$hook_sha" = "$rel_sha" ] || fail "release manifest hook mismatch"

echo "NATIVE_DIRECT_VERIFY=PASS"
echo "hook_sha256=$hook_sha"
echo "data_plane=private111->stock_omx->stock_cscreenrender->displayable58->context76"
echo "mirror_readback=DISABLED"
echo "window_manager_context=DISABLED"
