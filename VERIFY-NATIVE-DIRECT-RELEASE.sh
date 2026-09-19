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
INSTALL="$ROOT/Toolbox/scripts/install_mmi_cockpit_carplay_rx.sh"
STATUS="$ROOT/Toolbox/scripts/status_mmi_cockpit_carplay_test.sh"
CHAIN="$ROOT/Toolbox/scripts/altscreen_chain_test.sh"
TOP="$ROOT/SHA256SUMS.txt"
MAP="$ROOT/PACKAGE_SOURCE_MAP.json"

fail(){ echo "PRIVATE111_DIRECT_VERIFY=FAIL: $*" >&2; exit 1; }
sha256_file(){
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print tolower($1)}'
    else shasum -a 256 "$1" | awk '{print tolower($1)}'; fi
}
binary_strings(){ strings "$1" 2>/dev/null || grep -a -o '[[:print:]][[:print:]]*' "$1"; }

for f in "$HOOK" "$BIN" "$INFO" "$REL" "$NATIVE" "$TAP" "$SOURCE" "$BACKEND_H" "$BACKEND_CPP" "$CLUSTER_CPP" "$MAIN_CPP" "$START" "$CTRL" "$LAUNCH" "$RELEASE_STOP" "$STOP" "$INSTALL" "$STATUS" "$CHAIN"; do
    [ -s "$f" ] || fail "missing/empty: $f"
done

for s in "$START" "$CTRL" "$LAUNCH" "$STOP"          "$ROOT/Toolbox/carplay_alt_screen/mirror_display/release/stop_vehicle.sh"; do
    sh -n "$s" || fail "shell syntax: $s"
done

SOURCE_ONLY=0
if grep -Fq 'release_binary_status=V1_BINARY_STALE_V2_SOURCE_REBUILD_REQUIRED' "$INFO"; then
    SOURCE_ONLY=1
    grep -Fq 'vehicle_zip_status=NOT_READY_QNX_SIDECAR_REBUILD_REQUIRED' "$INFO" ||
        fail "source-only V2 must not be marked vehicle-ready"
    for marker in 'carplay-private111-direct-display-v1' 'PHASE=H264_SHM_ATTACHED' 'PHASE=DECODER_FIRST_FRAME' 'PHASE=DISPLAYABLE3_FIRST_PRESENT' 'PHASE=DIRECT111_ACTIVE'
    do
        binary_strings "$BIN" | grep -Fq "$marker" ||
            fail "stale V1 sidecar marker missing: $marker"
    done
elif grep -Fq 'release_binary_status=V2_BINARY_STALE_HARDENING_REBUILD_REQUIRED' "$INFO"; then
    SOURCE_ONLY=1
    grep -Fq 'vehicle_zip_status=NOT_READY_QNX_SIDECAR_REBUILD_REQUIRED' "$INFO" ||
        fail "hardened V2 source must not be marked vehicle-ready before rebuild"
    for marker in 'carplay-private111-direct-display-v2' 'PHASE=DECODED_SHM_WAIT_SIZE' 'PHASE=SOURCE_SESSION' 'PHASE=GATE_RECOVER_CURRENT_SESSION' 'PHASE=DISPLAYABLE3_FIRST_PRESENT' 'PHASE=DIRECT111_ACTIVE'
    do
        binary_strings "$BIN" | grep -Fq "$marker" ||
            fail "previous V2 sidecar marker missing while awaiting hardening rebuild: $marker"
    done
    if binary_strings "$BIN" | grep -Fq 'matching_identity_plus_frame_progress'; then
        fail "BUILD_INFO says hardening rebuild required but binary already contains final recovery marker"
    fi
elif grep -Fq 'release_binary_status=PRIVATE111_DIRECT_DISPLAY_V2' "$INFO"; then
    grep -Fq 'vehicle_zip_status=READY_FOR_VEHICLE_TEST' "$INFO" ||
        fail "rebuilt V2 sidecar is not marked vehicle-ready"
    for marker in 'carplay-private111-direct-display-v2' 'PHASE=DECODED_SHM_WAIT_SIZE' 'PHASE=SOURCE_SESSION' 'PHASE=GATE_RECOVER_CURRENT_SESSION' 'matching_identity_plus_frame_progress' 'packed_tight_required=1' 'stream111_request_or_phone_marker' 'STREAM_111_REQUESTED=YES' 'PHASE=DISPLAYABLE3_FIRST_PRESENT' 'PHASE=DIRECT111_ACTIVE'
    do
        binary_strings "$BIN" | grep -Fq "$marker" ||
            fail "V2 sidecar marker missing: $marker"
    done
else
    fail "unknown sidecar release state"
fi

if binary_strings "$BIN" | grep -Fq 'screen_read_window'; then
    fail "Screen readback must remain in hook, not sidecar"
fi

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
grep -Fq 'PHASE=FRAME_LINEARIZER_AUX_DROP' "$NATIVE" ||
    fail "V2 safe auxiliary-drop path missing"
grep -Fq 'raw_vendor_publish=0' "$NATIVE" ||
    fail "V2 must explicitly forbid raw vendor publication"
if grep -Fq 'p111_frame_tap_write(stream, buffer' "$NATIVE"; then
    fail "unsafe raw vendor frame publication remains in native render hook"
fi
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
grep -Fq 'DROP_AUX_FRAME' "$TAP" ||
    fail "V2 pre-first-frame safe drop policy missing"
grep -Fq 'H264_TAP_SESSION_RESET' "$TAP" ||
    fail "producer H264 session reset missing"
grep -Fq 'FRAME_TAP_SESSION_RESET' "$TAP" ||
    fail "producer decoded session reset missing"
grep -Fq 'ready_published_last=1' "$TAP" ||
    fail "producer ready/owner publication ordering missing"
grep -Fq 'shm_publish_success=1' "$TAP" ||
    fail "readback vs SHM publish success accounting missing"
grep -Fq 'readback_p50_ms=' "$TAP" ||
    fail "readback latency percentile diagnostics missing"
grep -Fq 'PHASE=FRAME_LINEARIZER_SLOW' "$TAP" ||
    fail "slow synchronous readback diagnostic missing"
grep -Fq 'DIRECT111_TAP_STOP_STALE' "$TAP" ||
    fail "stale-stream teardown isolation missing"
grep -Fq 'ALT111_LINEARIZER_SAMPLE_NV12' "$TAP" ||
    fail "opt-in producer NV12 sampling missing"
if grep -Fq 'V1_RAW_FAIL_OPEN' "$TAP"; then
    fail "retired raw fallback policy remains in linearizer"
fi

grep -Fq 'fstat(frame_fd_' "$SOURCE" ||
    fail "decoded SHM fstat size guard missing"
grep -Fq 'PHASE=DECODED_SHM_WAIT_SIZE' "$SOURCE" ||
    fail "decoded SHM size wait diagnostic missing"
grep -Fq 'PHASE=H264_SHM_WAIT_SIZE' "$SOURCE" ||
    fail "H264 SHM size wait diagnostic missing"
grep -Fq 'PHASE=SOURCE_SESSION' "$SOURCE" ||
    fail "consumer writer/session identity tracking missing"
grep -Fq 'current_session_active' "$SOURCE" ||
    fail "same-session recovery validation missing"
grep -Fq 'packed_tight_required=1' "$SOURCE" ||
    fail "packed NV12 metadata guard missing"
grep -Fq 'ALT111_CONSUMER_SAMPLE_NV12' "$SOURCE" ||
    fail "opt-in consumer NV12 sampling missing"
grep -Fq 'decoder_backend=stock-omx-tap' "$SOURCE" ||
    fail "sidecar decoded source backend mismatch"

grep -Fq 'PHASE=GATE_RECOVER_CURRENT_SESSION' "$MAIN_CPP" ||
    fail "same-session gate recovery path missing"
grep -Fq 'matching_identity_plus_frame_progress' "$MAIN_CPP" ||
    fail "same-session recovery does not require fresh frame progress"
grep -Fq 'stream111_request_or_phone_marker' "$MAIN_CPP" ||
    fail "normal reconnect gate does not accept the repeated type111 request marker"
grep -Fq 'STREAM_111_REQUESTED=YES' "$MAIN_CPP" ||
    fail "normal reconnect gate lacks per-session type111 request evidence"
grep -Fq 'carplay-private111-direct-display-v2' "$MAIN_CPP" ||
    fail "V2 sidecar source build id missing"

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
grep -Fq 'MIRROR_ABNORMAL_RESTART=SCHEDULED' "$LAUNCH" ||
    fail "launcher abnormal pre-first-present recovery missing"
grep -Fq 'ALT111_RECOVER_CURRENT_SESSION=1' "$LAUNCH" ||
    fail "launcher does not request validated same-session recovery"
grep -Fq 'phase=before_first_present' "$LAUNCH" ||
    fail "launcher does not honor private111 teardown before first present"
grep -Fq 'ALT111_MIRROR_RESTART_REASON=private111_session_end' "$LAUNCH" ||
    fail "launcher next-session autorestart missing"
grep -Fq 'stop.requested' "$LAUNCH" ||
    fail "launcher explicit-stop race guard missing"
grep -Fq 'lifecycle.pid' "$RELEASE_STOP" ||
    fail "release stop does not terminate lifecycle watcher"
grep -Fq ': > "$STOP_GUARD"' "$RELEASE_STOP" ||
    fail "release stop does not publish stop guard before teardown"
grep -Fq 'RECOVERY_LOCK=' "$RELEASE_STOP" ||
    fail "release stop recovery lock path missing"
if grep -F 'rm -f' "$RELEASE_STOP" | grep -Fq 'stop.requested'; then
    fail "release stop must retain stop guard to suppress delayed restart"
fi
grep -Fq 'stop_guard=RETAINED' "$RELEASE_STOP" ||
    fail "release stop does not advertise retained stop guard"

grep -Fq 'echo observe > "$STATE_DIR/IAP2_PROFILE"' "$CTRL" ||
    fail "corrected iAP2 observe policy missing"
grep -Fq 'rm -f "$STATE_DIR/ARMED_IAP2"' "$CTRL" ||
    fail "retired ThemeAssets arm marker is not disabled"
grep -Fq 'rm -f "$STATE_DIR/FULL_CHAIN_MODE" "$STATE_DIR/NATIVE_DISPLAY_MODE"' "$CTRL" ||
    fail "legacy native context route markers are not cleared"
grep -Fq 'DISPLAY_PATH=PRIVATE111_DIRECT' "$CTRL" ||
    fail "controller does not report private111 direct path"
grep -Fq 'decoder_backend=stock_omx_screen_linearized_shm' "$CTRL" ||
    fail "controller still reports stale V1 decoded backend"
grep -Fq 'PACKAGE_MODE=CARPLAY_PRIVATE111_DIRECT_DISPLAY_V2' "$INSTALL" ||
    fail "integrated installer does not identify V2 package"
grep -Fq 'release_binary_status=PRIVATE111_DIRECT_DISPLAY_V2' "$INSTALL" ||
    fail "integrated installer does not gate on rebuilt V2 release status"
grep -Fq 'vehicle_zip_status=READY_FOR_VEHICLE_TEST' "$INSTALL" ||
    fail "integrated installer does not gate on vehicle-ready release status"
grep -Fq 'release_binary_status=PRIVATE111_DIRECT_DISPLAY_V2' "$CHAIN" ||
    fail "runtime stager does not gate on rebuilt V2 release"
grep -Fq 'mode=carplay-private111-direct-display-v2' "$CHAIN" ||
    fail "runtime ownership marker is not V2"
grep -Fq 'CarPlay private111 Direct Display V2' "$STATUS" ||
    fail "STATUS still identifies the old V1 display path"
grep -Fq 'FRAME_LINEARIZER_SLOW_EVENTS=' "$STATUS" ||
    fail "STATUS does not surface Screen readback latency evidence"
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
echo "session_identity=writer_pid+generation+stream_cookie"
echo "raw_vendor_fallback=DISABLED"
echo "same_session_recovery=VALIDATED_SHM_ONLY"
if [ "$SOURCE_ONLY" = 1 ]; then
    echo "vehicle_zip_status=NOT_READY_QNX_SIDECAR_REBUILD_REQUIRED"
else
    echo "vehicle_zip_status=READY_FOR_VEHICLE_TEST"
fi
