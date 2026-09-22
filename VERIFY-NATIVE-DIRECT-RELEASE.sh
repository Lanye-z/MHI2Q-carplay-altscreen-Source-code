#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

HOOK="$ROOT/Toolbox/carplay_alt_screen/universal/libcarplay_altscreen.so"
BIN="$ROOT/Toolbox/carplay_alt_screen/mirror_display/release/carplay-alt111-mirror-display"
INFO="$ROOT/Toolbox/carplay_alt_screen/mirror_display/release/BUILD_INFO.txt"
REL="$ROOT/Toolbox/carplay_alt_screen/mirror_display/release/SHA256SUMS"
NATIVE="$ROOT/Toolbox/carplay_alt_screen/src/p1404_cockpit_native.c"
TAP="$ROOT/Toolbox/carplay_alt_screen/src/private111_direct_tap.c"
TAP_H="$ROOT/Toolbox/carplay_alt_screen/src/private111_direct_tap.h"
AIRPLAY_SRC="$ROOT/Toolbox/carplay_alt_screen/src/p1404_airplay.c"
RESOLVE="$ROOT/Toolbox/carplay_alt_screen/src/p1404_resolve.c"
SOURCE="$ROOT/Toolbox/carplay_alt_screen/mirror_display/src/private111_direct_source.cpp"
BACKEND_H="$ROOT/Toolbox/carplay_alt_screen/mirror_display/src/mhi2q_backend.h"
BACKEND_CPP="$ROOT/Toolbox/carplay_alt_screen/mirror_display/src/mhi2q_backend.cpp"
CLUSTER_CPP="$ROOT/Toolbox/carplay_alt_screen/mirror_display/src/cluster_video_display.cpp"
GL_RENDERER_CPP="$ROOT/Toolbox/carplay_alt_screen/mirror_display/src/gl_renderer.cpp"
MAIN_CPP="$ROOT/Toolbox/carplay_alt_screen/mirror_display/src/main.cpp"
HMI_SRC="$ROOT/Toolbox/carplay_alt_screen/hmi/src/com/luka/carplay/cluster/ClusterStateController.java"
WHEEL_SRC="$ROOT/Toolbox/carplay_alt_screen/hmi/src/com/luka/carplay/cluster/WheelZoomBridge.java"
HMI_BUILD_INFO="$ROOT/Toolbox/carplay_alt_screen/hmi/BUILD_INFO.txt"
WHEEL_PACING_TEST="$ROOT/Toolbox/carplay_alt_screen/tests/test_wheel_zoom_pacing.py"
START="$ROOT/Toolbox/scripts/start_mmi_cockpit_carplay_rx_test.sh"
CTRL="$ROOT/Toolbox/scripts/altscreen_chain_test_universal.sh"
LAUNCH="$ROOT/Toolbox/carplay_alt_screen/mirror_display/release/start_vehicle.sh"
RELEASE_STOP="$ROOT/Toolbox/carplay_alt_screen/mirror_display/release/stop_vehicle.sh"
STOP="$ROOT/Toolbox/scripts/stop_mmi_cockpit_carplay_test.sh"
INSTALL="$ROOT/Toolbox/scripts/install_mmi_cockpit_carplay_rx.sh"
STATUS="$ROOT/Toolbox/scripts/status_mmi_cockpit_carplay_test.sh"
CHAIN="$ROOT/Toolbox/scripts/altscreen_chain_test.sh"
RESTORE_TXN="$ROOT/Toolbox/scripts/altscreen_restore_transaction.sh"
RESTORE_APPLY="$ROOT/Toolbox/scripts/altscreen_restore_apply.sh"
PERSIST_DIAG="$ROOT/Toolbox/scripts/altscreen_persistent_diag.sh"
BOOT_DIAG="$ROOT/Toolbox/scripts/altscreen_boot_diag.sh"
START_TX_TEST="$ROOT/Toolbox/carplay_alt_screen/tests/test_start_autostart_transaction.sh"
STORAGE_POLICY_TEST="$ROOT/Toolbox/carplay_alt_screen/tests/test_storage_policy.sh"
RESTORE_TX_TEST="$ROOT/Toolbox/carplay_alt_screen/tests/test_restore_transaction.sh"
TOP="$ROOT/SHA256SUMS.txt"
MAP="$ROOT/PACKAGE_SOURCE_MAP.json"

fail(){ echo "PRIVATE111_DIRECT_VERIFY=FAIL: $*" >&2; exit 1; }
sha256_file(){
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print tolower($1)}'
    else shasum -a 256 "$1" | awk '{print tolower($1)}'; fi
}
binary_strings(){ strings "$1" 2>/dev/null || grep -a -o '[[:print:]][[:print:]]*' "$1"; }

for f in "$HOOK" "$BIN" "$INFO" "$REL" "$NATIVE" "$TAP" "$TAP_H" "$AIRPLAY_SRC" "$RESOLVE" "$SOURCE" "$BACKEND_H" "$BACKEND_CPP" "$CLUSTER_CPP" "$GL_RENDERER_CPP" "$MAIN_CPP" "$HMI_SRC" "$WHEEL_SRC" "$HMI_BUILD_INFO" "$WHEEL_PACING_TEST" "$START" "$CTRL" "$LAUNCH" "$RELEASE_STOP" "$STOP" "$INSTALL" "$STATUS" "$CHAIN" "$RESTORE_TXN" "$RESTORE_APPLY" "$PERSIST_DIAG" "$BOOT_DIAG" "$START_TX_TEST" "$STORAGE_POLICY_TEST" "$RESTORE_TX_TEST"; do
    [ -s "$f" ] || fail "missing/empty: $f"
done

for s in "$START" "$CTRL" "$CHAIN" "$RESTORE_TXN" "$RESTORE_APPLY" "$PERSIST_DIAG" "$LAUNCH" "$STOP" "$BOOT_DIAG" "$START_TX_TEST" "$RESTORE_TX_TEST" "$ROOT/Toolbox/carplay_alt_screen/mirror_display/release/stop_vehicle.sh"; do
    sh -n "$s" || fail "shell syntax: $s"
done

# ---- V3 transactional restore safety contract ----
grep -Fq 'RESTORE_ENTRY=TRANSACTIONAL_V3' "$STOP" ||
    fail "V3 RESTORE ORIGINAL does not enter the transactional wrapper"
grep -Fq 'RESTORE_TRANSACTION=PREPARED' "$RESTORE_TXN" ||
    fail "restore transaction PREPARED marker/log missing"
grep -Fq 'ROLLBACK=PASS persistent_state=PRE_RESTORE' "$RESTORE_TXN" ||
    fail "restore rollback contract missing"
grep -Fq 'STALE_RESTORE_TRANSACTION=DETECTED action=ROLLBACK_FIRST' "$RESTORE_TXN" ||
    fail "stale restore transaction recovery missing"
grep -Fq 'RESTORE_VERIFY=PASS' "$RESTORE_TXN" ||
    fail "full-state restore verification marker missing"
grep -Fq 'DO_NOT_TEST_CARPLAY_BEFORE_FULL_MMI_REBOOT' "$RESTORE_TXN" ||
    fail "post-restore reboot safety gate missing"
grep -Fq 'restore-precheck) cmd_restore_precheck' "$CTRL" ||
    fail "universal non-mutating restore precheck missing"
grep -Fq 'restore-precheck)' "$CHAIN" ||
    fail "router restore-precheck route missing"
grep -Fq 'restore transaction is active; START is blocked' "$CHAIN" ||
    fail "START is not blocked during an incomplete restore transaction"
grep -Fq 'restore transaction is active; recover/finish RESTORE ORIGINAL before INSTALL' "$CHAIN" ||
    fail "INSTALL is not blocked during an incomplete restore transaction"
grep -Fq 'STAGING_ROOT/controller-txn' "$CTRL" ||
    fail "universal restore scratch still depends on fragile nested /tmp storage"
grep -Fq 'staging/diag-txn' "$PERSIST_DIAG" ||
    fail "persistent diagnostics restore scratch still depends on fragile nested /tmp storage"


AUTH_MARKER="/mnt/app/root/carplay-altscreen/state/fullchain_probe"
LEGACY_AUTH_MARKER="/mnt/app/root/hooks/.mibcarplay_fullchain_probe"
grep -Fq "#define ALTSCREEN_PROBE_MARKER \"$AUTH_MARKER\"" "$RESOLVE" ||
    fail "native authorization marker source is not aligned with persistent runtime"
grep -Fq "PROBE_MARKER=\"\$(p $AUTH_MARKER)\"" "$CTRL" ||
    fail "controller authorization marker is not aligned with native hook"
if grep -Fq "$LEGACY_AUTH_MARKER" "$RESOLVE"; then
    fail "legacy authorization marker remains in native source"
fi

SOURCE_ONLY=0
HOOK_PENDING=0
NATIVE_REBUILDS=0
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
elif grep -Fq 'release_binary_status=V2_BINARY_STALE_LAYOUT_PROTOCOL_REBUILDS_REQUIRED' "$INFO"; then
    SOURCE_ONLY=1
    HOOK_PENDING=1
    NATIVE_REBUILDS=1
    grep -Fq 'vehicle_zip_status=NOT_READY_NATIVE_REBUILDS_REQUIRED' "$INFO" ||
        fail "layout protocol experiment must remain blocked until hook and sidecar rebuild"
    grep -Fq 'hook_runtime_rebuild_required=yes' "$INFO" ||
        fail "layout protocol experiment must declare hook rebuild pending"
    grep -Fq 'sidecar_source_driven_rebuild_required=yes' "$INFO" ||
        fail "layout protocol experiment must declare sidecar rebuild pending"
    grep -Fq 'hook_layout_safearea_rebuild_required=yes' "$INFO" ||
        fail "layout protocol experiment must declare safeArea hook rebuild pending"
    for marker in 'carplay-private111-direct-display-v2' 'PHASE=DECODED_SHM_WAIT_SIZE' 'PHASE=SOURCE_SESSION' 'PHASE=GATE_RECOVER_CURRENT_SESSION' 'matching_identity_plus_frame_progress' 'PHASE=DISPLAYABLE3_FIRST_PRESENT' 'PHASE=DISPLAYABLE3_OWNERSHIP' 'DISPLAYABLE3_OWNERSHIP_V1' 'PHASE=DIRECT111_ACTIVE'
    do
        binary_strings "$BIN" | grep -Fq "$marker" ||
            fail "previous clean V2 sidecar marker missing while awaiting source-driven rebuild: $marker"
    done
    if binary_strings "$BIN" | grep -Fq 'carplay-private111-direct-display-v2-source-driven-layout-live-v4'; then
        fail "BUILD_INFO says source/live-layout rebuild required but sidecar already contains new build id"
    fi
    if binary_strings "$HOOK" | grep -Fq 'ALTAREA_LAYOUT_SAFE_V3'; then
        fail "BUILD_INFO says safeArea hook rebuild required but hook already contains new marker"
    fi
elif grep -Fq 'release_binary_status=V2_BINARY_STALE_OWNERSHIP_REBUILD_REQUIRED' "$INFO"; then
    SOURCE_ONLY=1
    HOOK_PENDING=1
    NATIVE_REBUILDS=1
    grep -Fq 'vehicle_zip_status=NOT_READY_NATIVE_REBUILDS_REQUIRED' "$INFO" ||
        fail "clean ownership source must remain blocked until sidecar and hook rebuild"
    grep -Fq 'hook_runtime_rebuild_required=yes' "$INFO" ||
        fail "uncapped hook rebuild must remain pending"
    grep -Fq 'displayable3_ownership_observer=DISPLAYABLE3_OWNERSHIP_V1' "$INFO" ||
        fail "ownership observer metadata missing"
elif grep -Fq 'release_binary_status=V3_BINARY_STALE_V31_SOURCE_REBUILD_REQUIRED' "$INFO"; then
    SOURCE_ONLY=1
    NATIVE_REBUILDS=1
    grep -Fq 'sidecar_source_driven_rebuild_required=yes' "$INFO" ||
        fail "V3.1 must declare QNX sidecar rebuild pending"

    if grep -Fq 'hook_runtime_rebuild_required=yes' "$INFO"; then
        HOOK_PENDING=1
        grep -Fq 'hook_layout_safearea_rebuild_required=yes' "$INFO" ||
            fail "V3.1 hook-pending state must declare safeArea rebuild pending"
        grep -Fq 'vehicle_zip_status=NOT_READY_NATIVE_REBUILDS_REQUIRED' "$INFO" ||
            fail "V3.1 hook+sidecar pending state must remain blocked"
        if binary_strings "$HOOK" | grep -Fq 'safe_yh_mapping=map_local_unscaled'; then
            fail "V3.1 hook metadata says pending but rebuilt safeArea marker is already present"
        fi
    else
        HOOK_PENDING=0
        grep -Fq 'hook_layout_safearea_rebuild_required=no' "$INFO" ||
            fail "V3.1 rebuilt-hook state must clear safeArea rebuild flag"
        grep -Fq 'vehicle_zip_status=NOT_READY_QNX_SIDECAR_REBUILD_REQUIRED' "$INFO" ||
            fail "V3.1 rebuilt-hook state must remain blocked on QNX sidecar only"
        binary_strings "$HOOK" | grep -Fq 'safe_yh_mapping=map_local_unscaled' ||
            fail "V3.1 rebuilt hook missing map-local safeArea marker"
        binary_strings "$HOOK" | grep -Fq 'geometry_revision=V31_ONE_TO_ONE_CLIP' ||
            fail "V3.1 rebuilt hook missing geometry revision marker"
    fi

    for marker in 'carplay-private111-direct-display-v2-source-driven-layout-live-v4' 'PHASE=DECODED_SHM_WAIT_SIZE' 'PHASE=SOURCE_SESSION' 'PHASE=GATE_RECOVER_CURRENT_SESSION' 'matching_identity_plus_frame_progress' 'PHASE=DISPLAYABLE3_FIRST_PRESENT' 'PHASE=DISPLAYABLE3_OWNERSHIP' 'DISPLAYABLE3_OWNERSHIP_V1' 'PHASE=DIRECT111_ACTIVE'
    do
        binary_strings "$BIN" | grep -Fq "$marker" ||
            fail "previous V3 sidecar marker missing while awaiting V3.1 rebuild: $marker"
    done
    if binary_strings "$BIN" | grep -Fq 'carplay-private111-direct-display-v3.1-oem-map-1to1-clip'; then
        fail "BUILD_INFO says V3.1 sidecar rebuild required but binary already contains V3.1 build id"
    fi
elif grep -Fq 'release_binary_status=PRIVATE111_DIRECT_DISPLAY_V2' "$INFO"; then
    if grep -Fq 'vehicle_zip_status=NOT_READY_HOOK_REBUILD_REQUIRED' "$INFO"; then
        HOOK_PENDING=1
        grep -Fq 'hook_runtime_rebuild_required=yes' "$INFO" ||
            fail "hook-pending package must declare hook_runtime_rebuild_required=yes"
        grep -Fq 'hook_runtime_policy=uncapped_source_callbacks' "$INFO" ||
            fail "hook-pending package does not declare uncapped source callback policy"
    else
        grep -Fq 'vehicle_zip_status=READY_FOR_VEHICLE_TEST' "$INFO" ||
            fail "rebuilt V2 package has unknown vehicle-ready state"
        grep -Fq 'hook_runtime_rebuild_required=no' "$INFO" ||
            fail "vehicle-ready V2 package must declare rebuilt hook runtime"
    fi
    if grep -Fq 'geometry_policy=OEM_MAP_PLANE_1TO1_CLIP_V31' "$INFO"; then
        grep -Fq 'sidecar_source_driven_rebuild_required=no' "$INFO" ||
            fail "vehicle-ready V3.1 package must clear sidecar rebuild flag"
        grep -Fq 'hook_layout_safearea_rebuild_required=no' "$INFO" ||
            fail "vehicle-ready V3.1 package must clear safeArea rebuild flag"
        for marker in 'carplay-private111-direct-display-v3.1-oem-map-1to1-clip' 'PHASE=OEM_GEOMETRY_V31' 'geometry_policy=OEM_MAP_PLANE_1TO1_CLIP_V31' 'PHASE=DECODED_SHM_WAIT_SIZE' 'PHASE=SOURCE_SESSION' 'PHASE=GATE_RECOVER_CURRENT_SESSION' 'matching_identity_plus_frame_progress' 'packed_tight_required=1' 'stream111_request_or_phone_marker' 'STREAM_111_REQUESTED=YES' 'PHASE=PIPELINE_SOURCE_PRIMED' 'startup_frame_progress_required=2' 'PHASE=DISPLAYABLE3_FIRST_PRESENT' 'PHASE=DISPLAYABLE3_OWNERSHIP' 'DISPLAYABLE3_OWNERSHIP_V1' '/tmp/mmi-mirror-displayable3.state' 'PHASE=DIRECT111_ACTIVE' 'present_policy=source-driven'
        do
            binary_strings "$BIN" | grep -Fq "$marker" ||
                fail "V3.1 sidecar marker missing: $marker"
        done
        binary_strings "$HOOK" | grep -Fq 'safe_yh_mapping=map_local_unscaled' ||
            fail "V3.1 universal hook missing map-local safeArea mapping"
        binary_strings "$HOOK" | grep -Fq 'geometry_revision=V31_ONE_TO_ONE_CLIP' ||
            fail "V3.1 universal hook missing geometry revision marker"
    else
        for marker in 'carplay-private111-direct-display-v2-source-driven-layout-live-v4' 'PHASE=DECODED_SHM_WAIT_SIZE' 'PHASE=SOURCE_SESSION' 'PHASE=GATE_RECOVER_CURRENT_SESSION' 'matching_identity_plus_frame_progress' 'packed_tight_required=1' 'stream111_request_or_phone_marker' 'STREAM_111_REQUESTED=YES' 'PHASE=PIPELINE_SOURCE_PRIMED' 'startup_frame_progress_required=2' 'PHASE=DISPLAYABLE3_FIRST_PRESENT' 'PHASE=DISPLAYABLE3_OWNERSHIP' 'DISPLAYABLE3_OWNERSHIP_V1' '/tmp/mmi-mirror-displayable3.state' 'PHASE=DIRECT111_ACTIVE' 'present_policy=source-driven'
        do
            binary_strings "$BIN" | grep -Fq "$marker" ||
                fail "V2 sidecar marker missing: $marker"
        done
    fi
else
    fail "unknown sidecar release state"
fi

if binary_strings "$BIN" | grep -Fq 'screen_read_window'; then
    fail "Screen readback must remain in hook, not sidecar"
fi

if [ "$HOOK_PENDING" = 0 ]; then
    binary_strings "$HOOK" | grep -Fq "$AUTH_MARKER" ||
        fail "universal hook binary is stale: authorization marker path mismatch"
    if binary_strings "$HOOK" | grep -Fq "$LEGACY_AUTH_MARKER"; then
        fail "universal hook binary still embeds legacy authorization marker"
    fi
    binary_strings "$HOOK" | grep -Fq 'rate_policy=uncapped_source_callbacks' ||
        fail "universal hook binary is stale: rebuild/promote uncapped source-callback readback"
    binary_strings "$HOOK" | grep -Fq 'ALTAREA_LAYOUT_SAFE_V3' ||
        fail "universal hook binary is stale: rebuilt live CarPlay view-area marker missing"
    binary_strings "$HOOK" | grep -Fq 'OEM_STEPS_V1' ||
        fail "universal hook binary is stale: OEM wheel event model missing"
    binary_strings "$HOOK" | grep -Fq 'OEM_TARGET_FOLLOW_V1' ||
        fail "universal hook binary is stale: OEM target-follow scheduler missing"
    binary_strings "$HOOK" | grep -Fq 'PHASE=WHEEL_ZOOM_TARGET' ||
        fail "universal hook binary is stale: wheel target marker missing"
    binary_strings "$HOOK" | grep -Fq 'PHASE=WHEEL_ZOOM_STALL_ABORT' ||
        fail "universal hook binary is stale: wheel stall-abort marker missing"
    binary_strings "$HOOK" | grep -Fq 'PHASE=WHEEL_ZOOM_PACED_SEND' ||
        fail "universal hook binary is stale: wheel target-follow pacing marker missing"
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
grep -Fq 'rate_policy=uncapped_source_callbacks' "$TAP" ||
    fail "hook source is not configured for uncapped source callbacks"
grep -Fq 'sink_target_fps=30' "$TAP" ||
    fail "hook diagnostics do not preserve the independent 30fps sink policy"
if grep -Fq 'P111_LINEARIZER_TARGET_INTERVAL_US' "$TAP" ||
   grep -Fq 'next_readback_due_us' "$TAP" ||
   grep -Fq 'rate_limit_skips' "$TAP"; then
    fail "producer-side readback rate limiter still remains"
fi
grep -Fq 'static const unsigned kNoFramePollUs = 5000u;' "$MAIN_CPP" ||
    fail "source-driven sidecar must use the bounded 5ms no-new-frame poll"
grep -Fq 'static const unsigned kDecodedStallReportUs = 120000u;' "$MAIN_CPP" ||
    fail "source-driven sidecar must debounce normal frame gaps before stall reporting"
grep -Fq 'present_policy=source-driven' "$MAIN_CPP" ||
    fail "source-driven presentation marker missing"
if grep -Fq 'static const unsigned kTargetFps = 30;' "$MAIN_CPP" ||
   grep -Fq 'frame_period_us' "$MAIN_CPP"; then
    fail "retired relative 30fps success-sleep limiter still remains"
fi
grep -Fq 'DIRECT111_TAP_STOP_STALE' "$TAP" ||
    fail "stale-stream teardown isolation missing"
grep -Fq 'DIRECT111_TAP_STALE_CALLBACK' "$TAP" ||
    fail "stale callback cannot be proven unable to switch producer session"
grep -Fq 'FRAME_LINEARIZER_STALE_CALLBACK' "$TAP" ||
    fail "stale render callback is not rejected before Screen readback"
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
grep -Fq 'PHASE=PIPELINE_SOURCE_PRIMED' "$MAIN_CPP" ||
    fail "startup does not require decoded frame progress before displayable creation"
grep -Fq 'startup_frame_progress_required=2' "$MAIN_CPP" ||
    fail "startup fresh-frame threshold marker missing"
grep -Fq 'carplay-private111-direct-display-v3.1-oem-map-1to1-clip' "$MAIN_CPP" ||
    fail "V3.1 OEM geometry sidecar build id missing"

# ---- OEM target-follow wheel intent / CarPlay paced drain contract ----
grep -Fq 'model=OEM_STEPS_V1' "$WHEEL_SRC" ||
    fail "Java wheel observer does not publish OEM signed-step intent model"
grep -Fq 'step=0' "$WHEEL_SRC" ||
    fail "Java wheel intent schema is not single-record-per-callback"
if grep -Fq 'for (i = 1; i <= steps; ++i)' "$WHEEL_SRC"; then
    fail "retired per-step Java event expansion remains"
fi
grep -Fq '#define WHEEL_ZOOM_EVENT_MODEL "OEM_STEPS_V1"' "$NATIVE" ||
    fail "native wheel event parser model mismatch"
grep -Fq '#define WHEEL_ZOOM_SCHEDULER_MODEL "OEM_TARGET_FOLLOW_V1"' "$NATIVE" ||
    fail "native OEM target-follow scheduler marker missing"
grep -Fq '#define WHEEL_ZOOM_TARGET_LIMIT 12' "$NATIVE" ||
    fail "wheel outstanding-target safety clamp mismatch"
grep -Fq '#define WHEEL_ZOOM_MAX_EVENT_STEPS 16' "$NATIVE" ||
    fail "wheel event-step corruption guard mismatch"
grep -Fq 'zoom_have_send_time' "$NATIVE" ||
    fail "wheel send timing validity flag missing"
grep -Fq 'zoom_have_input_time' "$NATIVE" ||
    fail "wheel input timing validity flag missing"
if grep -Fq 'zoom_last_send_at == 0' "$NATIVE"; then
    fail "wheel send timing still relies on timestamp-zero sentinel"
fi
if grep -Fq 'zoom_last_send_at != 0' "$NATIVE"; then
    fail "wheel gate reset still relies on timestamp-nonzero sentinel"
fi
if grep -Fq 'new_burst = !zoom_last_input_at' "$NATIVE"; then
    fail "wheel input timing still relies on timestamp-zero sentinel"
fi
if grep -Fq 'zoom_stall_latched && zoom_stall_started_at &&' "$NATIVE"; then
    fail "wheel stall timing still relies on timestamp-zero sentinel"
fi
grep -Fq '#define WHEEL_ZOOM_MONITOR_TICK_US 50000u' "$NATIVE" ||
    fail "wheel scheduler quantum must remain 50 ms"
grep -Fq '#define WHEEL_ZOOM_MIN_PACE_US 100000u' "$NATIVE" ||
    fail "healthy target-follow minimum pacing must remain 100 ms"
grep -Fq '#define WHEEL_ZOOM_SEND_RETRY_US 150000u' "$NATIVE" ||
    fail "failed zoom submissions must use a 150 ms retry backoff"
grep -Fq 'zoom_have_failed_send_time' "$NATIVE" ||
    fail "failed zoom submission retry state missing"
grep -Fq 'reason=successful_catchup' "$NATIVE" ||
    fail "successful target catch-up is not rebased immediately"
grep -Fq '#define WHEEL_ZOOM_FALLBACK_PACE_US 150000u' "$NATIVE" ||
    fail "target-follow telemetry fallback must remain 150 ms"
grep -Fq '#define WHEEL_ZOOM_FRESH_FRAME_AGE_US 100000u' "$NATIVE" ||
    fail "stall-recovery fresh-frame age threshold mismatch"
grep -Fq '#define WHEEL_ZOOM_STALL_AGE_US 150000u' "$NATIVE" ||
    fail "wheel stall threshold mismatch"
grep -Fq '#define WHEEL_ZOOM_RECOVERY_FRAMES 3u' "$NATIVE" ||
    fail "stall-recovery frame count mismatch"
grep -Fq '#define WHEEL_ZOOM_BURST_GAP_US 300000u' "$NATIVE" ||
    fail "new-burst gap mismatch"
grep -Fq '#define WHEEL_ZOOM_STALL_ABORT_QUIET_US 350000u' "$NATIVE" ||
    fail "stall-abort quiet threshold mismatch"
grep -Fq '#define WHEEL_ZOOM_STALL_ABORT_US 1200000u' "$NATIVE" ||
    fail "stall-abort lifetime mismatch"
grep -Fq 'static uint32_t wheel_now_us32(void)' "$NATIVE" ||
    fail "dedicated wheel microsecond timebase missing"
grep -Fq 'native_wheel_zoom_target_accumulate' "$NATIVE" ||
    fail "desired wheel target accumulator missing"
grep -Fq 'p111_frame_tap_get_progress' "$NATIVE" ||
    fail "wheel stall guard does not consume decoded-frame progress"
grep -Fq 'struct p111_frame_progress_snapshot' "$TAP_H" ||
    fail "decoded-frame progress snapshot ABI declaration missing"
grep -Fq 'g_last_frame_publish_us32' "$TAP" ||
    fail "process-local decoded-frame freshness timestamp missing"
grep -Fq 'PHASE=WHEEL_ZOOM_TARGET' "$NATIVE" ||
    fail "wheel target diagnostics missing"
grep -Fq 'PHASE=WHEEL_ZOOM_TARGET_REBASE' "$NATIVE" ||
    fail "wheel settled-target rebase diagnostic missing"
grep -Fq 'PHASE=WHEEL_ZOOM_FRAME_STALL' "$NATIVE" ||
    fail "wheel stall diagnostic missing"
grep -Fq 'PHASE=WHEEL_ZOOM_FRAME_RECOVERED' "$NATIVE" ||
    fail "wheel recovery diagnostic missing"
grep -Fq 'PHASE=WHEEL_ZOOM_STALL_ABORT' "$NATIVE" ||
    fail "long-stall no-late-replay diagnostic missing"
grep -Fq 'PHASE=WHEEL_ZOOM_PACED_SEND' "$NATIVE" ||
    fail "target-follow CarPlay zoom dispatch missing"
grep -Fq 'response_gates_next=0' "$NATIVE" ||
    fail "CarPlay acceptance callback must remain observational"
if grep -Fq 'WHEEL_ZOOM_PENDING_HARD_EXPIRE' "$NATIVE"; then
    fail "retired hard-expire pending queue remains"
fi
python3 "$WHEEL_PACING_TEST" ||
    fail "OEM target-follow wheel behavioral contract failed"

# ---- CarPlay protocol-level live layout/safe-area + OEM map placement contract ----
grep -Fq 'ALTAREA_LAYOUT_SAFE_V3' "$AIRPLAY_SRC" ||
    fail "CarPlay cluster live safeArea marker missing"
grep -Fq '/tmp/mmi-mirror-hmi.state' "$AIRPLAY_SRC" ||
    fail "early HMI layout state input missing"
if grep -Fq '/tmp/carplay-oem-geometry.state' "$AIRPLAY_SRC"; then
    fail "OBSERVE_ONLY ListModel176 geometry state must not drive CarPlay safeArea"
fi
grep -Fq 'LayoutMIB2HighB9' "$AIRPLAY_SRC" ||
    fail "K1004 measured layout guard missing"
if grep -Fq 'static int alt_kv_u32' "$AIRPLAY_SRC"; then
    fail "unused alt_kv_u32 helper would fail the -Werror universal build"
fi
if grep -Fq 'alt_safe_y_455_to_canvas' "$AIRPLAY_SRC"; then
    fail "V3.1 must not scale OEM map-local safeArea Y/H from 455 to 542"
fi
grep -Fq 'safe_yh_mapping=map_local_unscaled' "$AIRPLAY_SRC" ||
    fail "V3.1 map-local safeArea coordinate-space diagnostic missing"
grep -Fq 'geometry_revision=V31_ONE_TO_ONE_CLIP' "$AIRPLAY_SRC" ||
    fail "V3.1 safeArea geometry revision marker missing"
grep -Fq 'r.x = 370u;' "$AIRPLAY_SRC" ||
    fail "FULL safeArea X missing"
grep -Fq 'r.y = 49u;' "$AIRPLAY_SRC" ||
    fail "FULL/SMALL safeArea Y must remain OEM map-local 49"
grep -Fq 'r.w = 700u;' "$AIRPLAY_SRC" ||
    fail "FULL safeArea width missing"
grep -Fq 'r.h = 300u;' "$AIRPLAY_SRC" ||
    fail "FULL/SMALL safeArea height must remain OEM map-local 300"
grep -Fq 'r.x = 490u;' "$AIRPLAY_SRC" ||
    fail "SMALL safeArea X missing"
grep -Fq 'r.w = 460u;' "$AIRPLAY_SRC" ||
    fail "SMALL safeArea width missing"
grep -Fq 'map_plane_terminal_y_policy=metadata_only_not_renderer_offset' "$AIRPLAY_SRC" ||
    fail "OEM terminal Y=26 must remain metadata-only in V3.1"
grep -Fq 'physical_y = 49 + (int64_t)r.renderer_dy;' "$AIRPLAY_SRC" ||
    fail "physical safe-region Y must stay in the measured 455 sink plane"
if grep -Fq 'r.physical_x - (int64_t)r.renderer_dx' "$AIRPLAY_SRC" ||
   grep -Fq 'source x=966' "$AIRPLAY_SRC"; then
    fail "retired Sport SMALL safeArea compensation still present"
fi
grep -Fq 'small_stage_dx' "$AIRPLAY_SRC" ||
    fail "hook does not consume OEM small-stage X offset"
grep -Fq '*small_dx = -476;' "$AIRPLAY_SRC" ||
    fail "verified B9Sport SMALL -476 fallback missing"
grep -Fq 'make_cluster_layout_view_areas' "$AIRPLAY_SRC" ||
    fail "type111 does not declare FULL+SMALL viewAreas"
grep -Fq 'display_h == 542u || display_h == 540u || display_h == 455u' "$AIRPLAY_SRC" ||
    fail "measured B9 canvas guard must include observed private111 1440x542"
grep -Fq 'predeclared_even_if_hmi_late=%d' "$AIRPLAY_SRC" ||
    fail "cold-start two-view-area predeclaration diagnostic missing"
grep -Fq 'initialViewArea' "$AIRPLAY_SRC" ||
    fail "type111 initial view-area selection missing"
grep -Fq 'adjacentViewAreas' "$AIRPLAY_SRC" ||
    fail "type111 view-area adjacency missing"
grep -Fq 'type111_transition_flags=omitted' "$AIRPLAY_SRC" ||
    fail "type111 Apple SDK transition-flag gating not documented"
grep -Fq 'updateViewArea' "$AIRPLAY_SRC" ||
    fail "standard same-session updateViewArea command missing"
grep -Fq 'PHASE=ALT111_VIEWAREA_SUBMIT' "$AIRPLAY_SRC" ||
    fail "same-session view-area submit diagnostic missing"
grep -Fq 'animationDurationMillis' "$AIRPLAY_SRC" ||
    fail "updateViewArea animation-duration field missing"
grep -Fq 'ALT111_EVENT_UPDATE_VIEW_AREA' "$NATIVE" ||
    fail "native layout watcher does not drive the view-area event"
grep -Fq 'PHASE=ALT111_VIEWAREA_TARGET' "$NATIVE" ||
    fail "native HMI view-area target observer missing"
grep -Fq 'PHASE=ALT111_VIEWAREA_RESULT' "$NATIVE" ||
    fail "native view-area response/retry observer missing"
grep -Fq 'strstr(layout, "LayoutMIB2HighB9")' "$NATIVE" ||
    fail "view-area sender is not gated to the measured B9 layout family"
grep -Fq 'native_measured_view_area_canvas' "$NATIVE" ||
    fail "view-area sender does not gate on measured private111 canvas geometry"
grep -Fq 'route_ready &&' "$NATIVE" ||
    fail "view-area update may run before the private route has a validated first frame"
grep -Fq 'height == 542u || height == 540u || height == 455u' "$NATIVE" ||
    fail "view-area sender canvas gate does not match the declared B9 geometry set"
grep -Fq 'gate=LayoutMIB2HighB9' "$NATIVE" ||
    fail "B9-only view-area gate diagnostic missing"
grep -Fq 'canvas_gate=%d' "$NATIVE" ||
    fail "view-area canvas gate diagnostic missing"
grep -Fq '#define WHEEL_ZOOM_MONITOR_TICK_US 50000u' "$NATIVE" ||
    fail "wheel target-follow scheduler must keep its 50ms master tick"
grep -Fq '#define ALT111_VIEW_AREA_POLL_US 100000u' "$NATIVE" ||
    fail "live CarPlay layout watcher must retain a 100ms poll interval"
grep -Fq 'wheel_now - view_area_last_poll_at' "$NATIVE" ||
    fail "ViewArea polling is not decoupled from the 50ms wheel scheduler"
grep -Fq 'renderer_scale=0' "$AIRPLAY_SRC" ||
    fail "protocol safeArea path must explicitly keep renderer scaling disabled"

grep -Fq 'PHASE=OEM_MAP_PLACEMENT' "$MAIN_CPP" ||
    fail "live OEM map placement marker missing"
grep -Fq 'PHASE=OEM_MAP_PLACEMENT_STATE_GAP' "$MAIN_CPP" ||
    fail "HMI state atomic-replace gap retention marker missing"
grep -Fq 'action=retain_previous' "$MAIN_CPP" ||
    fail "sidecar must retain the previous placement across transient HMI-state gaps"
grep -Fq 'bool state_complete;' "$MAIN_CPP" ||
    fail "sidecar cannot distinguish incomplete HMI state from a valid unknown layout"
grep -Fq 'PHASE=OEM_MAP_RERENDER' "$MAIN_CPP" ||
    fail "layout change does not redraw the current frame immediately"
grep -Fq 'next_layout_probe_us' "$MAIN_CPP" ||
    fail "sidecar live layout poll missing"
grep -Fq '50000ULL' "$MAIN_CPP" ||
    fail "sidecar live layout poll must be bounded to 50ms"
grep -Fq 'small_stage_dx' "$MAIN_CPP" ||
    fail "sidecar does not consume OEM small-stage X offset"
grep -Fq 'small_dx = -476;' "$MAIN_CPP" ||
    fail "sidecar verified B9Sport SMALL -476 fallback missing"
grep -Fq 'display.set_destination_rect(p.dx, p.dy, 1440, 542)' "$MAIN_CPP" ||
    fail "V3.1 sidecar must keep the 1440x542 source canvas at 1:1 scale"
grep -Fq 'PHASE=OEM_GEOMETRY_V31' "$MAIN_CPP" ||
    fail "V3.1 OEM geometry runtime marker missing"
grep -Fq 'geometry_policy=OEM_MAP_PLANE_1TO1_CLIP_V31' "$MAIN_CPP" ||
    fail "V3.1 1:1 viewport clipping policy marker missing"
grep -Fq 'clip_bottom=87' "$MAIN_CPP" ||
    fail "V3.1 542-to-455 viewport clip extent marker missing"
grep -Fq 'live_switch=1' "$MAIN_CPP" ||
    fail "sidecar map placement is not marked live"
grep -Fq 'renderer_scale=0' "$MAIN_CPP" ||
    fail "sidecar map placement must keep scaling disabled"
grep -Fq 'natural_clip=1' "$MAIN_CPP" ||
    fail "translated renderer natural clipping marker missing"
grep -Fq 'V3.1 may also' "$GL_RENDERER_CPP" ||
    fail "GLES V3.1 1:1 viewport clipping contract missing"
if grep -Fq 'visible_active_x' "$MAIN_CPP"; then
    fail "physical safe rectangle must not be reused as a renderer scale box"
fi

# ---- displayable3 ownership source contract (targeted observer only) ----
grep -Fq 'struct Mhi2qWindowState' "$BACKEND_H" ||
    fail "displayable3 physical-state struct missing"
grep -Fq 'sample_window_state(Mhi2qWindowState' "$BACKEND_H" ||
    fail "displayable3 state sampler declaration missing"
grep -Fq 'bool Mhi2qBackend::sample_window_state' "$BACKEND_CPP" ||
    fail "displayable3 state sampler implementation missing"
grep -Fq 'observer=DISPLAYABLE3_OWNERSHIP_V1' "$MAIN_CPP" ||
    fail "displayable3 ownership state publication missing"
grep -Fq '/tmp/mmi-mirror-displayable3.state' "$MAIN_CPP" ||
    fail "displayable3 ownership state path missing"
grep -Fq 'OWNERSHIP_SNAPSHOT' "$HMI_SRC" ||
    fail "Context80/displayable3 ownership correlation missing"
grep -Fq 'COLD_START_OWNERSHIP_DIAG_V1' "$HMI_SRC" ||
    fail "cold-start ownership observer marker missing"
grep -Fq 'mmi-mirror-displayable3.state' "$BOOT_DIAG" ||
    fail "boot diagnostics do not collect displayable3 snapshot"

# Explicitly reject the removed yuedizhibo logging/telemetry port.
if grep -Fq 'FRAME_PRESENT_TIMING' "$MAIN_CPP" ||
   grep -Fq 'FRAME_CHAIN_HEALTH' "$MAIN_CPP"; then
    fail "removed per-frame/chain telemetry reintroduced into sidecar"
fi
if grep -Fq 'DIAG_QUEUE' "$HMI_SRC" ||
   grep -Fq 'SD_DIAG_SEGMENT_BYTES' "$HMI_SRC"; then
    fail "removed async Java SD logging reintroduced"
fi
[ ! -e "$ROOT/Toolbox/scripts/altscreen_log_ring.sh" ] ||
    fail "removed SD log-ring helper reintroduced"

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
grep -Fq "grep -c 'PHASE=DIRECT111_TAP_STOP stream='" "$LAUNCH" ||
    fail "launcher teardown counter can be polluted by stale teardown markers"
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
grep -Fq 'ensure_dirs()' "$INSTALL" ||
    fail "integrated installer lacks QNX-safe directory helper"
if grep -Fq 'mkdir -p "$JAR_TARGET_DIR"' "$INSTALL"; then
    fail "integrated installer still uses fatal EEXIST-prone mkdir -p for HMI target"
fi
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
grep -Fq 'select_controller_log_source' "$BOOT_DIAG" ||
    fail "boot diagnostics do not locate mmi-mirror-controller.log"
grep -Fq 'flat_controller_offset=$(flat_capture_delta "$(select_controller_log_source)"' "$BOOT_DIAG" ||
    fail "flat boot diagnostics do not persist Java Context80 controller log"
grep -Fq 'streams/mmi-mirror-controller.log' "$BOOT_DIAG" ||
    fail "flat SD fallback does not persist Java Context80 controller log"
if grep -Fq 'DISPLAY_PATH=WINDOW58_READBACK' "$CTRL"; then
    fail "controller still advertises retired Window58 readback"
fi

grep -Fq 'START_FAIL_STAGE=' "$START" ||
    fail "START persistent stage/failure diagnostics missing"
grep -Fq 'logs/operations' "$START" ||
    fail "START persistent operation journal path missing"
grep -Fq 'tmp/altscreen_$journal_name' "$START" ||
    fail "START flat /tmp journal fallback missing"
grep -Fq '/tmp/altscreen_autostart.log' "$START" ||
    fail "canonical Mirror autostart log path missing"
if grep -Eq '/tmp/MMI-Cockpit-Carplay/.+autostart\.log' "$START"; then
    fail "retired nested Mirror autostart log path remains"
fi
grep -Fq 'MIRROR_START_RC=' "$START" ||
    fail "boot autostart launcher return code diagnostic missing"
grep -Fq 'ensure_dirs "$STATE"' "$START" ||
    fail "QNX-safe idempotent runtime state creation missing"
if grep -Fq 'mkdir -p "$STATE"' "$START"; then
    fail "fatal QNX EEXIST-prone mkdir -p remains for runtime state"
fi
grep -Fq 'START_ROLLBACK_CONTROLLER=DISARMED_NEW_TRANSACTION' "$START" ||
    fail "START cannot transactionally disarm a newly-created controller state"
grep -Fq 'altscreen_start_*.log' "$BOOT_DIAG" ||
    fail "boot diagnostics do not flush flat START journals to SD"
grep -Fq 'altscreen_operation_*.log' "$BOOT_DIAG" ||
    fail "boot diagnostics do not flush flat controller journals to SD"

# Release gate: the fault-injection fixture must prove full rollback before a V3 ZIP can be vehicle-ready.
sh "$START_TX_TEST" || fail "START/autostart host transaction fixture failed"
sh "$STORAGE_POLICY_TEST" || fail "storage policy fixture failed"
sh "$RESTORE_TX_TEST" || fail "RESTORE rollback fault-injection fixture failed"

grep -Fq 'touch /tmp/mmi-mirror-active' "$START" ||
    fail "Java80 demand boot marker missing"
grep -Fq '/mnt/app/root/carplay-altscreen/bin/mirror/start_vehicle.sh' "$START" ||
    fail "direct-display sidecar boot launch missing"
grep -Fq 'meaning=destination_first_successful_gles_present' "$START" ||
    fail "destination-ready semantics missing"
grep -Fq 'LD_PRELOAD= "$BIN"' "$LAUNCH" ||
    fail "sidecar LD_PRELOAD isolation missing"
grep -Fq 'DIRECT_DISPLAY_SIDECAR=STOPPED' "$RESTORE_APPLY" ||
    fail "transactional restore APPLY step is not aligned with direct-display V3"

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
hmi_hook_sha=$(sed -n 's/^universal_runtime_sha256=\([0-9a-fA-F]*\)$/\1/p' "$HMI_BUILD_INFO" | tr 'A-F' 'a-f')
[ -n "$hmi_hook_sha" ] && [ "$hook_sha" = "$hmi_hook_sha" ] ||
    fail "HMI BUILD_INFO universal runtime SHA mismatch"

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
if [ "$NATIVE_REBUILDS" = 1 ]; then
    echo "vehicle_zip_status=NOT_READY_NATIVE_REBUILDS_REQUIRED"
elif [ "$SOURCE_ONLY" = 1 ]; then
    echo "vehicle_zip_status=NOT_READY_QNX_SIDECAR_REBUILD_REQUIRED"
elif [ "$HOOK_PENDING" = 1 ]; then
    echo "vehicle_zip_status=NOT_READY_HOOK_REBUILD_REQUIRED"
else
    echo "vehicle_zip_status=READY_FOR_VEHICLE_TEST"
fi
