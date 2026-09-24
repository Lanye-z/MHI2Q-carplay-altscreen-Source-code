#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
READY="$ROOT/BRANCH-ZIP-READY.txt"
HMI_INFO="$ROOT/Toolbox/carplay_alt_screen/hmi/BUILD_INFO.txt"
JAR="$ROOT/Toolbox/carplay_alt_screen/hmi/carplay_hook-basevideo3.jar"
HOOK="$ROOT/Toolbox/carplay_alt_screen/universal/libcarplay_altscreen.so"
RGI_META="$ROOT/Toolbox/carplay_alt_screen/rgi_meta/libcarplay_rgi_meta.so"
SUMS="$ROOT/SHA256SUMS.txt"
MAP="$ROOT/PACKAGE_SOURCE_MAP.json"
SD_RW="$ROOT/Toolbox/scripts/altscreen_sd_writable.sh"
SUPERVISOR="$ROOT/Toolbox/carplay_alt_screen/mirror_display/release/stream_supervisor.sh"

fail(){ echo "BRANCH_ZIP_VERIFY=FAIL: $*" >&2; exit 1; }
check_unique_keys(){
    file=$1
    dup=$(awk -F= '
        /^[A-Za-z0-9_.-]+=/ {
            if (++seen[$1] > 1) {
                print $1
                exit
            }
        }
    ' "$file")
    [ -z "$dup" ] || fail "duplicate metadata key in $file: $dup"
}
sha256_file(){
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print tolower($1)}'
    else shasum -a 256 "$1" | awk '{print tolower($1)}'; fi
}
file_size(){ wc -c < "$1" | tr -d ' '; }
file_cksum(){ cksum < "$1" | awk '{print $1}'; }

[ -s "$READY" ] || fail "BRANCH-ZIP-READY.txt missing"
[ -s "$HMI_INFO" ] || fail "HMI BUILD_INFO missing"
[ -s "$JAR" ] || fail "V3 HMI JAR missing"
[ -s "$HOOK" ] || fail "universal hook missing"
[ -s "$SUMS" ] || fail "SHA256SUMS.txt missing"
[ -s "$MAP" ] || fail "PACKAGE_SOURCE_MAP.json missing"
[ -s "$SD_RW" ] || fail "shared SD writable helper missing"
[ -s "$SUPERVISOR" ] || fail "V3.4 stream supervisor missing"
sh -n "$SUPERVISOR" || fail "V3.4 stream supervisor shell syntax"
grep -Fq 'altscreen_sd_ensure_writable()' "$SD_RW" || fail "SD writable helper contract missing"
grep -Fq 'AFTER_REMOUNT' "$SD_RW" || fail "SD remount re-probe contract missing"
grep -Fq 'Toolbox/scripts/altscreen_sd_writable.sh' "$MAP" || fail "SD writable helper missing from PACKAGE_SOURCE_MAP"
grep -Fq 'Toolbox/scripts/altscreen_sd_writable.sh' "$SUMS" || fail "SD writable helper missing from SHA256SUMS"
grep -Fq 'Toolbox/carplay_alt_screen/mirror_display/release/stream_supervisor.sh' "$MAP" ||
    fail "V3.4 stream supervisor missing from PACKAGE_SOURCE_MAP"
grep -Fq 'Toolbox/carplay_alt_screen/mirror_display/release/stream_supervisor.sh' "$SUMS" ||
    fail "V3.4 stream supervisor missing from SHA256SUMS"

check_unique_keys "$READY"
check_unique_keys "$HMI_INFO"

grep -Fq 'BRANCH_ZIP_READY=YES' "$READY" || fail "branch ZIP is not marked ready"
grep -Fq 'branch_zip_status=READY_FOR_VEHICLE_TEST' "$HMI_INFO" ||
    fail "HMI BUILD_INFO does not mark branch ZIP vehicle-ready"
grep -Fq 'branch_zip_policy=GITHUB_BRANCH_ZIP_INSTALLABLE' "$HMI_INFO" ||
    fail "HMI BUILD_INFO direct-download policy missing"
mode=$(sed -n 's/^mode=//p' "$HMI_INFO")
case "$mode" in
  PRIVATE111_DIRECT_DISPLAY_V3_WHEEL_ZOOM|PRIVATE111_DIRECT_DISPLAY_V3_3_OEM_LOWER_BAR|PRIVATE111_DIRECT_DISPLAY_V3_4_STREAM_DRIVEN|PRIVATE111_DIRECT_DISPLAY_V3_5_COLD_START) ;;
  *) fail "unsupported HMI mode: $mode" ;;
esac
grep -Fq 'wheel_zoom_build_status=COMPILED_READY_FOR_VEHICLE_TEST' "$HMI_INFO" ||
    fail "V3 wheel JAR is not marked compiled"

expected_size=$(sed -n 's/^jar_size=//p' "$HMI_INFO")
expected_cksum=$(sed -n 's/^jar_cksum=//p' "$HMI_INFO")
expected_jar_sha=$(sed -n 's/^jar_sha256=//p' "$HMI_INFO" | tr 'A-F' 'a-f')
expected_hook_sha=$(sed -n 's/^universal_runtime_sha256=//p' "$HMI_INFO" | tr 'A-F' 'a-f')
actual_size=$(file_size "$JAR")
actual_cksum=$(file_cksum "$JAR")
actual_jar_sha=$(sha256_file "$JAR")
actual_hook_sha=$(sha256_file "$HOOK")

[ "$actual_size" = "$expected_size" ] || fail "HMI JAR size mismatch"
[ "$actual_cksum" = "$expected_cksum" ] || fail "HMI JAR cksum mismatch"
[ "$actual_jar_sha" = "$expected_jar_sha" ] || fail "HMI JAR SHA256 mismatch"
[ "$actual_hook_sha" = "$expected_hook_sha" ] || fail "universal hook SHA256 mismatch"

grep -Fq "jar_sha256=$actual_jar_sha" "$READY" ||
    fail "ready marker JAR SHA mismatch"
grep -Fq "universal_runtime_sha256=$actual_hook_sha" "$READY" ||
    fail "ready marker hook SHA mismatch"

if [ "$mode" = PRIVATE111_DIRECT_DISPLAY_V3_3_OEM_LOWER_BAR ]; then
    [ -s "$RGI_META" ] || fail "V3.3 RGI metadata hook missing"
    actual_rgi_sha=$(sha256_file "$RGI_META")
    [ "$actual_rgi_sha" = 87d10f67fbb3dc142642d899977bab0a6eb4009f61d3bcd873d0cce9e01511f7 ] ||
        fail "V3.3 RGI metadata hook identity mismatch"
    grep -Fq 'oem_lower_bar=CARPLAY_RGI_FCT19_21_22_PARTIAL_V2' "$HMI_INFO" ||
        fail "V3.3 partial lower-bar contract missing"
    grep -Fq 'oem_lower_bar_teardown=RELEASE_FIELDS_NO_SYNTHETIC_CLEAR_RESTORE_STOCK_LISTENER' "$HMI_INFO" ||
        fail "V3.3 fail-open lower-bar teardown contract missing"
    grep -Fq 'lower_bar_gate_policy=LAZY_PER_FIELD_REVALIDATE_UNWRAP_WHEN_IDLE' "$HMI_INFO" ||
        fail "V3.3 per-field lazy gate policy missing"
    grep -Fq 'carplay_hook_sd_log=streams/carplay_hook.log' "$HMI_INFO" ||
        fail "V3.3 Java/RGI SD log contract missing"
    grep -Fq 'oem_lower_bar_map_scale=FCT45_STOCK_PASSTHROUGH' "$HMI_INFO" ||
        fail "V3.3 OEM map-scale passthrough missing"
    grep -Fq 'safearea_policy=V33_OEM_X_VERTICAL_68_450' "$HMI_INFO" ||
        fail "V3.3 HMI safeArea policy is not top68/bottom450"
    grep -Fq 'geometry_safearea_space=OEM_X_VERTICAL_68_450' "$HMI_INFO" ||
        fail "V3.3 HMI safeArea coordinate-space marker missing"
    grep -Fq 'safearea_full=370,68,700,382' "$READY" ||
        fail "V3.3 FULL safeArea ready marker mismatch"
    grep -Fq 'safearea_small=490,68,460,382' "$READY" ||
        fail "V3.3 SMALL safeArea ready marker mismatch"
    grep -Fq "rgi_metadata_sha256=$actual_rgi_sha" "$READY" ||
        fail "V3.3 ready marker RGI SHA mismatch"
fi

if grep -Fq 'branch=experiment/oem-layout-second-screen_v3.5' "$READY"; then
    [ "$mode" = PRIVATE111_DIRECT_DISPLAY_V3_5_COLD_START ] ||
        fail "V3.5 HMI mode mismatch"
    [ -s "$RGI_META" ] || fail "V3.5 RGI metadata hook missing"
    actual_rgi_sha=$(sha256_file "$RGI_META")
    [ "$actual_rgi_sha" = 87d10f67fbb3dc142642d899977bab0a6eb4009f61d3bcd873d0cce9e01511f7 ] ||
        fail "V3.5 RGI metadata hook identity mismatch"
    grep -Fq "rgi_metadata_sha256=$actual_rgi_sha" "$READY" ||
        fail "V3.5 ready marker RGI SHA mismatch"
    grep -Fq 'oem_lower_bar_map_scale=FCT45_STOCK_PASSTHROUGH' "$HMI_INFO" ||
        fail "V3.5 OEM map-scale passthrough missing"
    grep -Fq 'safearea_policy=V35_OEM_X_VERTICAL_75_450' "$HMI_INFO" ||
        fail "V3.5 HMI safeArea policy is not top75/bottom450"
    grep -Fq 'geometry_safearea_space=OEM_X_VERTICAL_75_450' "$HMI_INFO" ||
        fail "V3.5 HMI safeArea coordinate-space marker missing"
    grep -Fq 'safearea_policy=V3_5_OEM_X_VERTICAL_75_450' "$READY" ||
        fail "V3.5 ready safeArea policy mismatch"
    grep -Fq 'safearea_full=370,75,700,375' "$READY" ||
        fail "V3.5 FULL safeArea ready marker mismatch"
    grep -Fq 'safearea_small=490,75,460,375' "$READY" ||
        fail "V3.5 SMALL safeArea ready marker mismatch"
    grep -Fq 'lower_bar_observability=KOMO_FOLLOW_RG_RGI_BEFORE_AFTER_V35' "$HMI_INFO" ||
        fail "V3.5 HMI gray-bar observability metadata missing"
    grep -Fq 'lower_bar_observability_behavior=READ_ONLY_NO_PRESENTATION_MUTATION' "$HMI_INFO" ||
        fail "V3.5 HMI gray-bar read-only observability policy missing"
    grep -Fq 'lower_bar_observability=KOMO_FOLLOW_RG_RGI_BEFORE_AFTER_V35' "$READY" ||
        fail "V3.5 ready gray-bar observability metadata missing"
    grep -Fq 'lower_bar_observability_policy=READ_ONLY_NO_PRESENTATION_MUTATION' "$READY" ||
        fail "V3.5 ready gray-bar read-only observability policy missing"
    grep -Fq 'mode=PRIVATE111_DIRECT_DISPLAY_V3_5_COLD_START' "$READY" ||
        fail "V3.5 ready marker mode mismatch"
    grep -Fq 'vehicle_zip_status=READY_FOR_V3_5_VEHICLE_TEST' "$READY" ||
        fail "V3.5 ready marker vehicle status mismatch"
    grep -Fq 'negotiation_policy=V35_EARLY_PROTOCOL_READY' "$READY" ||
        fail "V3.5 early negotiation policy missing"
    grep -Fq 'cold_start_policy=EARLY_NEGOTIATION_READY' "$READY" ||
        fail "V3.5 cold-start policy missing"
    grep -Fq 'cold_start_capability_wait_ms=500' "$READY" ||
        fail "V3.5 capability wait contract missing"
    grep -Fq 'cold_start_geometry_gate=ASYNC' "$READY" ||
        fail "V3.5 async geometry gate missing"
    grep -Fq 'cold_start_bootstrap_canvas=1440x542_NEGOTIATION_ONLY' "$READY" ||
        fail "V3.5 negotiation-only bootstrap canvas missing"
    grep -Fq 'cold_start_renderer_geometry=LIVE_SCREEN_MATCH_REQUIRED' "$READY" ||
        fail "V3.5 renderer live-match fence missing"
    grep -Fq 'sd_runtime_gate=DISABLED' "$READY" ||
        fail "V3.5 SD runtime gate is not disabled"
    grep -Fq 'display_start_policy=STREAM_DRIVEN' "$READY" ||
        fail "V3.5 display policy is not stream-driven"
    grep -Fq 'stream_ready_stable_decoded_frames=2' "$READY" ||
        fail "V3.5 stable-frame threshold missing"
    grep -Fq 'fixed_display_delay=NONE' "$READY" ||
        fail "V3.5 unexpectedly uses a fixed display delay"
    grep -Fq 'sidecar_attach_policy=RECOVER_CURRENT_SESSION' "$READY" ||
        fail "V3.5 current-session attach policy missing"
    grep -Fq 'oem_lower_bar=CARPLAY_RGI_FCT19_21_22_PLUS_KOMO_GRAY_BAR_V4' "$READY" ||
        fail "V3.5 OEM gray-bar contract missing"
    grep -Fq 'lower_bar_context_policy=KOMO_FOLLOW_INFO_NO_RGI_PRESENTATION' "$READY" ||
        fail "V3.5 KOMO gray-bar context contract missing"
fi

if grep -Fq 'branch=experiment/oem-layout-second-screen_v3.4' "$READY"; then
    [ "$mode" = PRIVATE111_DIRECT_DISPLAY_V3_4_STREAM_DRIVEN ] ||
        fail "V3.4 HMI mode mismatch"
    [ -s "$RGI_META" ] || fail "V3.4 RGI metadata hook missing"
    actual_rgi_sha=$(sha256_file "$RGI_META")
    [ "$actual_rgi_sha" = 87d10f67fbb3dc142642d899977bab0a6eb4009f61d3bcd873d0cce9e01511f7 ] ||
        fail "V3.4 RGI metadata hook identity mismatch"
    grep -Fq "rgi_metadata_sha256=$actual_rgi_sha" "$READY" ||
        fail "V3.4 ready marker RGI SHA mismatch"
    grep -Fq 'oem_lower_bar_map_scale=FCT45_STOCK_PASSTHROUGH' "$HMI_INFO" ||
        fail "V3.4 OEM map-scale passthrough missing"
    grep -Fq 'safearea_policy=V33_OEM_X_VERTICAL_68_450' "$HMI_INFO" ||
        fail "V3.4 HMI safeArea policy is not top68/bottom450"
    grep -Fq 'geometry_safearea_space=OEM_X_VERTICAL_68_450' "$HMI_INFO" ||
        fail "V3.4 HMI safeArea coordinate-space marker missing"
    grep -Fq 'safearea_full=370,68,700,382' "$READY" ||
        fail "V3.4 FULL safeArea ready marker mismatch"
    grep -Fq 'safearea_small=490,68,460,382' "$READY" ||
        fail "V3.4 SMALL safeArea ready marker mismatch"
    grep -Fq 'mode=PRIVATE111_DIRECT_DISPLAY_V3_4_STREAM_DRIVEN' "$READY" ||
        fail "V3.4 ready marker mode mismatch"
    grep -Fq 'vehicle_zip_status=READY_FOR_V3_4_VEHICLE_TEST' "$READY" ||
        fail "V3.4 ready marker vehicle status mismatch"
    grep -Fq 'negotiation_policy=ALWAYS_ON_WHILE_PRELOAD_INSTALLED' "$READY" ||
        fail "V3.4 negotiation policy missing"
    grep -Fq 'sd_runtime_gate=DISABLED' "$READY" ||
        fail "V3.4 SD runtime gate is not disabled"
    grep -Fq 'display_start_policy=STREAM_DRIVEN' "$READY" ||
        fail "V3.4 display policy is not stream-driven"
    grep -Fq 'stream_ready_stable_decoded_frames=2' "$READY" ||
        fail "V3.4 stable-frame threshold missing"
    grep -Fq 'fixed_display_delay=NONE' "$READY" ||
        fail "V3.4 unexpectedly uses a fixed display delay"
    grep -Fq 'sidecar_attach_policy=RECOVER_CURRENT_SESSION' "$READY" ||
        fail "V3.4 current-session attach policy missing"
    grep -Fq 'oem_lower_bar=CARPLAY_RGI_FCT19_21_22_PLUS_KOMO_GRAY_BAR_V4' "$READY" ||
        fail "V3.4 OEM gray-bar contract missing"
    grep -Fq 'lower_bar_context_policy=KOMO_FOLLOW_INFO_NO_RGI_PRESENTATION' "$READY" ||
        fail "V3.4 KOMO gray-bar context contract missing"
fi

sh "$ROOT/VERIFY-NATIVE-DIRECT-RELEASE.sh"

if command -v sha256sum >/dev/null 2>&1; then
    (cd "$ROOT" && sha256sum -c SHA256SUMS.txt >/dev/null) ||
        fail "root SHA256 manifest mismatch"
else
    echo "BRANCH_ZIP_SHA256_MANIFEST=SKIPPED reason=sha256sum_unavailable"
fi

echo "BRANCH_ZIP_VERIFY=PASS"
echo "mode=$mode"
echo "jar_sha256=$actual_jar_sha"
echo "hook_sha256=$actual_hook_sha"
echo "download_policy=GITHUB_BRANCH_ZIP_INSTALLABLE"
