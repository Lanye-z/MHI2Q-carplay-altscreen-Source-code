#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HOOK="$ROOT/Toolbox/carplay_alt_screen/universal/libcarplay_altscreen.so"
NATIVE="$ROOT/Toolbox/carplay_alt_screen/src/p1404_cockpit_native.c"
HEADER="$ROOT/Toolbox/carplay_alt_screen/src/p1404_cockpit_native.h"
START="$ROOT/Toolbox/scripts/start_mmi_cockpit_carplay_rx_test.sh"
STATUS="$ROOT/Toolbox/scripts/status_mmi_cockpit_carplay_test.sh"
TOP="$ROOT/SHA256SUMS.txt"
MAP="$ROOT/PACKAGE_SOURCE_MAP.json"
REL="$ROOT/Toolbox/carplay_alt_screen/mirror_display/release/SHA256SUMS"

fail(){ echo "BASEVIDEO3_VISIBLE_VERIFY=FAIL: $*" >&2; exit 1; }
sha256_file(){
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    else shasum -a 256 "$1" | awk '{print $1}'; fi
}
binary_strings(){ strings "$1" 2>/dev/null || grep -a -o '[[:print:]][[:print:]]*' "$1"; }

[ -s "$HOOK" ] || fail "hook missing"

for marker in   'PHASE=BASEVIDEO3_NATIVE_POLICY'   'PHASE=BASEVIDEO3_WINDOW_PROBE'   'PHASE=BASEVIDEO3_FORCE_VISIBLE'   'PHASE=BASEVIDEO3_READY'   '/tmp/mmi-mirror-basevideo.ready'   'screen_manage_window'
do
    binary_strings "$HOOK" | grep -Fq "$marker" ||
        fail "BaseVideo3 hook marker missing: $marker"
done

binary_strings "$HOOK" | grep -Fq 'identity_override=DISABLED' &&
    fail "helper-isolation runtime unexpectedly present" || true

grep -Eq '#define[[:space:]]+ALT111_DISPLAYABLE_ID[[:space:]]+3u' "$HEADER" ||
    fail "private111 displayable identity is not 3"
grep -Eq '#define[[:space:]]+ALT111_JAVA_CONTEXT[[:space:]]+80u' "$HEADER" ||
    fail "Java context contract is not 80"

grep -q 'output->window_id = ALT111_DISPLAYABLE_ID' "$NATIVE" ||
    fail "private CScreenRender config rewrite missing"
grep -q 'PHASE=BASEVIDEO3_FORCE_VISIBLE' "$NATIVE" ||
    fail "visible probe missing"
grep -q 'SCREEN_PROPERTY_VISIBLE' "$NATIVE" ||
    fail "private visible property write missing"
grep -q 'basevideo3_publish_ready' "$NATIVE" ||
    fail "ready publication missing"
grep -q 'g_spawnl = NULL' "$NATIVE" ||
    fail "native spawn/dmdt path is not fail-closed"
grep -A6 'static int native_route_requested' "$NATIVE" | grep -q 'return 0;' ||
    fail "legacy native context route is not hard-disabled"

if grep -q 'SCREEN_WINDOW_MANAGER_CONTEXT' "$NATIVE"; then
    fail "WindowManager context is forbidden in BaseVideo3 native runtime"
fi

grep -q 'MIRROR_POLICY=DISABLED' "$START" ||
    fail "START does not disable Mirror"
grep -q 'DISPLAY_PATH=BASEVIDEO3_NATIVE' "$START" ||
    fail "START does not declare BaseVideo3 native path"
grep -q 'CONTEXT_POLICY=JAVA_ONLY context=80 native_dmdt=0' "$START" ||
    fail "START does not declare Java-only context ownership"
if grep -q 'MIRROR_AUTOSTART=ENABLED' "$START"; then
    fail "Mirror autostart leaked into BaseVideo3 START"
fi

grep -q 'DISPLAY_PATH=BASEVIDEO3_NATIVE' "$STATUS" ||
    fail "STATUS does not declare BaseVideo3 native path"
grep -q 'WINDOW_VISIBLE_POLICY=FORCED_PRIVATE_ONLY value=1' "$STATUS" ||
    fail "STATUS does not expose the visible probe"

hook_sha=$(sha256_file "$HOOK")
top_sha=$(awk '$2 == "Toolbox/carplay_alt_screen/universal/libcarplay_altscreen.so" {print $1}' "$TOP")
map_sha=$(sed -n 's/.*"Toolbox\/carplay_alt_screen\/universal\/libcarplay_altscreen.so": "\([0-9a-fA-F]*\)".*/\1/p' "$MAP")
rel_sha=$(awk '$2 == "libcarplay_altscreen.so" {print $1}' "$REL")
[ "$hook_sha" = "$top_sha" ] || fail "top manifest hook mismatch"
[ "$hook_sha" = "$map_sha" ] || fail "package map hook mismatch"
[ "$hook_sha" = "$rel_sha" ] || fail "release manifest hook mismatch"

echo "BASEVIDEO3_VISIBLE_VERIFY=PASS"
echo "hook_sha256=$hook_sha"
echo "data_plane=private111->stock_omx->stock_cscreenrender->managed_displayable3"
echo "context_owner=JAVA80"
echo "force_visible=1"
echo "mirror_readback=DISABLED"
echo "native_dmdt=DISABLED"
