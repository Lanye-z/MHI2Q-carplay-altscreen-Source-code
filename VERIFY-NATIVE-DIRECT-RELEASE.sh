#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

HOOK="$ROOT/Toolbox/carplay_alt_screen/universal/libcarplay_altscreen.so"
BIN="$ROOT/Toolbox/carplay_alt_screen/mirror_display/release/carplay-alt111-mirror-display"
INFO="$ROOT/Toolbox/carplay_alt_screen/mirror_display/release/BUILD_INFO.txt"
REL="$ROOT/Toolbox/carplay_alt_screen/mirror_display/release/SHA256SUMS"
NATIVE="$ROOT/Toolbox/carplay_alt_screen/src/p1404_cockpit_native.c"
TAP="$ROOT/Toolbox/carplay_alt_screen/src/private111_direct_tap.c"
SOURCE="$ROOT/Toolbox/carplay_alt_screen/mirror_display/src/private111_direct_source.cpp"
BACKEND_H="$ROOT/Toolbox/carplay_alt_screen/mirror_display/src/mhi2q_backend.h"
BACKEND_CPP="$ROOT/Toolbox/carplay_alt_screen/mirror_display/src/mhi2q_backend.cpp"
CLUSTER_CPP="$ROOT/Toolbox/carplay_alt_screen/mirror_display/src/cluster_video_display.cpp"
MAIN_CPP="$ROOT/Toolbox/carplay_alt_screen/mirror_display/src/main.cpp"
START="$ROOT/Toolbox/scripts/start_mmi_cockpit_carplay_rx_test.sh"
CTRL="$ROOT/Toolbox/scripts/altscreen_chain_test_universal.sh"
LAUNCH="$ROOT/Toolbox/carplay_alt_screen/mirror_display/release/start_vehicle.sh"
RELEASE_STOP="$ROOT/Toolbox/carplay_alt_screen/mirror_display/release/stop_vehicle.sh"
STOP="$ROOT/Toolbox/scripts/stop_mmi_cockpit_carplay_test.sh"
TOP="$ROOT/SHA256SUMS.txt"
MAP="$ROOT/PACKAGE_SOURCE_MAP.json"

fail(){ echo "PRIVATE111_DIRECT_VERIFY=FAIL: $*" >&2; exit 1; }
sha256_file(){
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print tolower($1)}'
    else shasum -a 256 "$1" | awk '{print tolower($1)}'; fi
}
binary_strings(){ strings "$1" 2>/dev/null || grep -a -o '[[:print:]][[:print:]]*' "$1"; }

for f in "$HOOK" "$BIN" "$INFO" "$REL" "$NATIVE" "$TAP" "$SOURCE" "$BACKEND_H" "$BACKEND_CPP" "$CLUSTER_CPP" "$MAIN_CPP" "$START" "$CTRL" "$LAUNCH" "$RELEASE_STOP" "$STOP"; do
    [ -s "$f" ] || fail "missing/empty: $f"
done

for s in "$START" "$CTRL" "$LAUNCH" "$STOP"          "$ROOT/Toolbox/carplay_alt_screen/mirror_display/release/stop_vehicle.sh"; do
    sh -n "$s" || fail "shell syntax: $s"
done

for marker in     'carplay-private111-direct-display-v1'     'PHASE=H264_SHM_ATTACHED'     'PHASE=DECODER_FIRST_FRAME'     'PHASE=NV12_CSC_READY'     'PHASE=DISPLAYABLE3_FIRST_PRESENT'     'PHASE=DIRECT111_ACTIVE'     'window58_readback=0'
do
    binary_strings "$BIN" | grep -Fq "$marker" ||
        fail "sidecar marker missing: $marker"
done
if binary_strings "$BIN" | grep -Fq 'screen_read_window'; then
    fail "retired Window58 readback leaked into promoted sidecar"
fi

grep -Fq 'release_binary_status=PRIVATE111_DIRECT_DISPLAY_V1' "$INFO" ||
    fail "BUILD_INFO release status mismatch"
grep -Fq 'vehicle_zip_status=READY_FOR_VEHICLE_TEST' "$INFO" ||
    fail "BUILD_INFO vehicle status mismatch"
grep -Fq 'window58_readback=disabled' "$INFO" ||
    fail "BUILD_INFO Window58 policy mismatch"
grep -Fq 'mirror_sink=displayable3_gles' "$INFO" ||
    fail "BUILD_INFO sink mismatch"
grep -Fq 'context=80_java_only' "$INFO" ||
    fail "BUILD_INFO Java80 policy mismatch"
grep -Fq 'private111_session_end_policy=hook_DIRECT111_TAP_STOP_watchdog' "$INFO" ||
    fail "BUILD_INFO private111 session-end policy mismatch"
grep -Fq 'private111_session_restart=enabled_while_basevideo_demand_active' "$INFO" ||
    fail "BUILD_INFO private111 restart policy mismatch"
grep -Fq 'lifecycle_watchdog_binary_rebuild_required=no' "$INFO" ||
    fail "BUILD_INFO lifecycle rebuild policy mismatch"

grep -Fq 'p111_frame_tap_write_window(stream, stock_window' "$NATIVE" ||
    fail "V2 Screen linearizer is not wired after stock render"
grep -Fq 'screen_window_t window;' "$NATIVE" ||
    fail "V2 native slot does not retain exact Screen window handle"
grep -Fq 'managed_window = g_managed_config.window;' "$NATIVE" ||
    fail "V2 config does not capture exact Screen window handle"
grep -Fq 'slot->window = managed_window;' "$NATIVE" ||
    fail "V2 exact Screen window handle is not persisted"
grep -Fq 'stock_window = slot->window;' "$NATIVE" ||
    fail "V2 render does not consume persisted Screen window handle"
if grep -Fq 'CSCREEN_WINDOW_OFF' "$NATIVE"; then
    fail "V2 must not infer Screen window via CScreenRender object offset"
fi
grep -Fq 'PHASE=FRAME_LINEARIZER_RAW_FALLBACK' "$NATIVE" ||
    fail "V2 raw diagnostic fail-open path missing"
grep -Fq 'rate_limited=1' "$NATIVE" ||
    fail "V2 raw fallback logging is not rate limited"
grep -A8 'static int native_route_requested' "$NATIVE" | grep -Fq 'return 0;' ||
    fail "native route is not hard-disabled for direct-display V2"
grep -Fq 'P111_QNX_NV12_FORMAT 65548u' "$TAP" ||
    fail "measured vendor Screen format support missing"
grep -Fq 'P111_SCREEN_FORMAT_NV12 12' "$TAP" ||
    fail "V2 standard NV12 readback target missing"
grep -Fq 'P111_SCREEN_FORMAT_RGBA8888 8' "$TAP" ||
    fail "V2 RGBA readback fallback missing"
grep -Fq 'P111_SCREEN_PROPERTY_PLANAR_OFFSETS 33' "$TAP" ||
    fail "V2 authoritative plane-offset query missing"
grep -Fq 'screen_read_window' "$TAP" ||
    fail "V2 Screen window linearizer missing"
grep -Fq 'PHASE=FRAME_LINEARIZER_FIRST_FRAME' "$TAP" ||
    fail "V2 first linearized frame diagnostic missing"
grep -Fq 'valid_uniform_frame' "$TAP" ||
    fail "V2 uniform/black-frame acceptance missing"
grep -Fq 'FREEZE_LAST_GOOD' "$TAP" ||
    fail "V2 transient-failure freeze policy missing"
grep -Fq 'decoder_backend=stock-omx-tap' "$SOURCE" ||
    fail "sidecar decoded source backend mismatch"

# ---- Reliability contract: EGL swap failure must propagate to first present ----
grep -Fq 'bool swap();' "$BACKEND_H" ||
    fail "Mhi2qBackend::swap() must return bool"
grep -Fq 'bool Mhi2qBackend::swap()' "$BACKEND_CPP" ||
    fail "swap() implementation must return bool"
grep -Fq 'if (!backend_.swap()) {' "$CLUSTER_CPP" ||
    fail "present_uploaded_frame() must check swap() result"
grep -Fq 'PHASE=EGL_SWAP_FAILED' "$BACKEND_CPP" ||
    fail "eglSwapBuffers failure must emit EGL_SWAP_FAILED diagnostic"
grep -Fq 'PHASE=DECODED_SOURCE_RECOVERED' "$MAIN_CPP" ||
    fail "stall recovery diagnostic missing"
grep -Fq 'freeze_last_frame=1' "$MAIN_CPP" ||
    fail "decoded stall must freeze last frame"
if grep -Fq 'failures > 150' "$MAIN_CPP"; then
    fail "fixed ~3s stall auto-exit must not remain in main loop"
fi
if grep -Fq 'PHASE=DECODED_SOURCE_LOST' "$MAIN_CPP"; then
    fail "DECODED_SOURCE_LOST auto-exit must not remain"
fi

# ---- Session lifecycle contract: freeze temporary stalls, release on real teardown ----
grep -Fq 'PHASE=DIRECT111_TAP_STOP' "$LAUNCH" ||
    fail "launcher does not observe explicit private111 teardown"
grep -Fq 'MIRROR_LIFECYCLE_WATCH=STARTED' "$LAUNCH" ||
    fail "launcher lifecycle watcher missing"
grep -Fq 'LIFECYCLE_WATCH=PRIVATE111_STOP' "$LAUNCH" ||
    fail "launcher session-end action missing"
grep -Fq 'ALT111_MIRROR_RESTART_REASON=private111_session_end' "$LAUNCH" ||
    fail "launcher next-session autorestart missing"
grep -Fq 'stop.requested' "$LAUNCH" ||
    fail "launcher explicit-stop race guard missing"
grep -Fq 'lifecycle.pid' "$RELEASE_STOP" ||
    fail "release stop does not terminate lifecycle watcher"
grep -Fq ': > "$STOP_GUARD"' "$RELEASE_STOP" ||
    fail "release stop does not publish stop guard before teardown"

grep -Fq 'echo observe > "$STATE_DIR/IAP2_PROFILE"' "$CTRL" ||
    fail "corrected iAP2 observe policy missing"
grep -Fq 'rm -f "$STATE_DIR/ARMED_IAP2"' "$CTRL" ||
    fail "retired ThemeAssets arm marker is not disabled"
grep -Fq 'rm -f "$STATE_DIR/FULL_CHAIN_MODE" "$STATE_DIR/NATIVE_DISPLAY_MODE"' "$CTRL" ||
    fail "legacy native context route markers are not cleared"
grep -Fq 'DISPLAY_PATH=PRIVATE111_DIRECT' "$CTRL" ||
    fail "controller does not report private111 direct path"
if grep -Fq 'DISPLAY_PATH=WINDOW58_READBACK' "$CTRL"; then
    fail "controller still advertises retired Window58 readback"
fi

grep -Fq 'touch /tmp/mmi-mirror-active' "$START" ||
    fail "Java80 demand boot marker missing"
grep -Fq '/mnt/app/root/carplay-altscreen/bin/mirror/start_vehicle.sh' "$START" ||
    fail "direct-display sidecar boot launch missing"
grep -Fq 'meaning=destination_first_successful_gles_present' "$START" ||
    fail "destination-ready semantics missing"
grep -Fq 'LD_PRELOAD= "$BIN"' "$LAUNCH" ||
    fail "sidecar LD_PRELOAD isolation missing"
grep -Fq 'DIRECT_DISPLAY_SIDECAR=STOPPED' "$STOP" ||
    fail "restore script is not aligned with direct-display V1"

check_release_sha(){
    rel_name="$1"
    rel_path="$2"
    expected=$(awk -v name="$rel_name" '$2 == name {print tolower($1)}' "$REL")
    actual=$(sha256_file "$rel_path")
    [ -n "$expected" ] && [ "$actual" = "$expected" ] ||
        fail "release SHA256 mismatch: $rel_name"
}

check_release_sha "BUILD_INFO.txt" "$INFO"
check_release_sha "carplay-alt111-mirror-display" "$BIN"
check_release_sha "start_vehicle.sh" "$LAUNCH"
check_release_sha "stop_vehicle.sh" "$RELEASE_STOP"

bin_sha=$(sha256_file "$BIN")

hook_sha=$(sha256_file "$HOOK")
top_hook_sha=$(awk '$2 == "Toolbox/carplay_alt_screen/universal/libcarplay_altscreen.so" {print tolower($1)}' "$TOP")
map_hook_sha=$(sed -n 's/.*"Toolbox\/carplay_alt_screen\/universal\/libcarplay_altscreen.so": "\([0-9a-fA-F]*\)".*/\1/p' "$MAP" | tr 'A-F' 'a-f')
[ -n "$top_hook_sha" ] && [ "$hook_sha" = "$top_hook_sha" ] ||
    fail "top manifest hook mismatch"
[ -n "$map_hook_sha" ] && [ "$hook_sha" = "$map_hook_sha" ] ||
    fail "package map hook mismatch"

echo "PRIVATE111_DIRECT_VERIFY=PASS"
echo "pipeline=type111->H264Tap->stockOMX->stockPost->ScreenLinearizer->NV12SHM->CPU_CSC_GLES->displayable3->Java80"
echo "sidecar_sha256=$bin_sha"
echo "hook_sha256=$hook_sha"
echo "sidecar_window58_observer=DISABLED"
echo "hook_exact_stock_window_linearizer=ENABLED"
echo "context_owner=JAVA80_ONLY"
echo "session_end_policy=HOOK_DIRECT111_TAP_STOP_WATCHDOG_RESTART"
echo "vehicle_zip_status=READY_FOR_VEHICLE_TEST"
