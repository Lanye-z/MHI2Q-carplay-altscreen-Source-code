#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
HOOK="$ROOT/Toolbox/carplay_alt_screen/universal/libcarplay_altscreen.so"
JAR="$ROOT/Toolbox/carplay_alt_screen/hmi/carplay_hook-basevideo3.jar"
NATIVE="$ROOT/Toolbox/carplay_alt_screen/src/p1404_cockpit_native.c"
HEADER="$ROOT/Toolbox/carplay_alt_screen/src/p1404_cockpit_native.h"
INSTALL="$ROOT/Toolbox/scripts/install_mmi_cockpit_carplay_rx.sh"
START="$ROOT/Toolbox/scripts/start_mmi_cockpit_carplay_rx_test.sh"
STATUS="$ROOT/Toolbox/scripts/status_mmi_cockpit_carplay_test.sh"
RESTORE="$ROOT/Toolbox/scripts/stop_mmi_cockpit_carplay_test.sh"
CTRL="$ROOT/Toolbox/scripts/altscreen_chain_test_universal.sh"
GEM="$ROOT/Toolbox/GEM/mqb-carplayAltScreen.esd"
TOP="$ROOT/SHA256SUMS.txt"
MAP="$ROOT/PACKAGE_SOURCE_MAP.json"

fail(){ echo "BASEVIDEO3_STANDALONE_VERIFY=FAIL: $*" >&2; exit 1; }
sha256_file(){
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print tolower($1)}'
    else shasum -a 256 "$1" | awk '{print tolower($1)}'; fi
}
binary_strings(){ strings "$1" 2>/dev/null || grep -a -o '[[:print:]][[:print:]]*' "$1"; }

for s in "$INSTALL" "$START" "$STATUS" "$RESTORE" "$CTRL"; do
    sh -n "$s" || fail "shell syntax: $s"
done

[ -s "$HOOK" ] || fail "QNX hook missing"
[ -s "$JAR" ] || fail "standalone Java80 JAR missing"
[ "$(wc -c < "$JAR" | tr -d ' ')" = 141858 ] || fail "Java80 JAR size mismatch"
[ "$(sha256_file "$JAR")" = eafebf9fd1a7f4d3962fa5330b6908f45570756ade24676baf1f2bf66edc2c8a ] ||
    fail "Java80 JAR SHA256 mismatch"

for marker in   'PHASE=BASEVIDEO3_NATIVE_POLICY'   'PHASE=BASEVIDEO3_WINDOW_PROBE'   'PHASE=BASEVIDEO3_FORCE_VISIBLE'   'PHASE=BASEVIDEO3_READY'   '/tmp/mmi-mirror-basevideo.ready'   'screen_manage_window'
do
    binary_strings "$HOOK" | grep -Fq "$marker" || fail "hook marker missing: $marker"
done

grep -Eq '#define[[:space:]]+ALT111_DISPLAYABLE_ID[[:space:]]+3u' "$HEADER" ||
    fail "private111 displayable is not 3"
grep -Eq '#define[[:space:]]+ALT111_JAVA_CONTEXT[[:space:]]+80u' "$HEADER" ||
    fail "Java context contract is not 80"
grep -q 'output->window_id = ALT111_DISPLAYABLE_ID' "$NATIVE" ||
    fail "private CScreenRender identity rewrite missing"
grep -q 'g_spawnl = NULL' "$NATIVE" || fail "native dmdt spawn backend not disabled"
grep -A6 'static int native_route_requested' "$NATIVE" | grep -q 'return 0;' ||
    fail "legacy native context route not hard-disabled"

grep -q 'carplay_hook-basevideo3.jar' "$INSTALL" || fail "INSTALL does not package standalone HMI JAR"
grep -q '/mnt/app/eso/hmi/lsd/jars/carplay_hook.jar' "$INSTALL" || fail "INSTALL HMI target missing"
grep -q 'MMI_MIRROR_RUNTIME=NOT_INCLUDED' "$INSTALL" || fail "INSTALL standalone policy missing"
if grep -q 'mirror_display/release' "$INSTALL"; then fail "INSTALL still depends on Mirror release"; fi
if grep -q 'carplay-alt111-mirror-display' "$INSTALL"; then fail "INSTALL still deploys Mirror sidecar"; fi

grep -q '# BEGIN ALT111 BASEVIDEO3 AUTOSTART' "$START" || fail "BaseVideo3 boot marker block missing"
grep -q 'touch /tmp/mmi-mirror-active' "$START" || fail "BaseVideo demand boot marker missing"
grep -q 'CONTEXT_POLICY=JAVA_ONLY' "$START" || fail "START does not declare Java-only context owner"
grep -q 'MMI_MIRROR_SIDECAR=DISABLED' "$START" || fail "START Mirror policy missing"

grep -q 'HMI_CONTROL_PLANE=PASS' "$STATUS" || fail "STATUS HMI identity check missing"
grep -q 'JAVA_CONTROLLER=STARTED' "$STATUS" || fail "STATUS Java controller evidence missing"
grep -q 'BASEVIDEO3_READY=YES' "$STATUS" || fail "STATUS BaseVideo readiness missing"

grep -q 'basevideo3-hmi-original' "$RESTORE" || fail "RESTORE Java backup path missing"
grep -q 'HMI_CONTROL_PLANE=RESTORED' "$RESTORE" || fail "RESTORE Java rollback evidence missing"
grep -q 'DISPLAY_PATH=BASEVIDEO3_NATIVE' "$CTRL" || fail "controller still reports legacy 58 route"
grep -q 'Standalone flow:' "$GEM" || fail "GEM menu is not labeled standalone"

hook_sha=$(sha256_file "$HOOK")
top_sha=$(awk '$2 == "Toolbox/carplay_alt_screen/universal/libcarplay_altscreen.so" {print tolower($1)}' "$TOP")
map_sha=$(sed -n 's/.*"Toolbox\/carplay_alt_screen\/universal\/libcarplay_altscreen.so": "\([0-9a-fA-F]*\)".*/\1/p' "$MAP" | tr 'A-F' 'a-f')
[ "$hook_sha" = "$top_sha" ] || fail "top manifest hook mismatch"
[ "$hook_sha" = "$map_sha" ] || fail "package map hook mismatch"

echo "BASEVIDEO3_STANDALONE_VERIFY=PASS"
echo "hook_sha256=$hook_sha"
echo "hmi_jar_sha256=$(sha256_file "$JAR")"
echo "package=type111_native+displayable3+java80"
echo "mmi_mirror_runtime=ABSENT"
echo "rgi98_native_renderer=ABSENT"
echo "context_owner=JAVA80"
echo "native_dmdt=DISABLED"
