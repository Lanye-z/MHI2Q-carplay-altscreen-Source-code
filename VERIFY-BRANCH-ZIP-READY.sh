#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
READY="$ROOT/BRANCH-ZIP-READY.txt"
HMI_INFO="$ROOT/Toolbox/carplay_alt_screen/hmi/BUILD_INFO.txt"
JAR="$ROOT/Toolbox/carplay_alt_screen/hmi/carplay_hook-basevideo3.jar"
HOOK="$ROOT/Toolbox/carplay_alt_screen/universal/libcarplay_altscreen.so"
RGI_META="$ROOT/Toolbox/carplay_alt_screen/rgi_meta/libcarplay_rgi_meta.so"
SUMS="$ROOT/SHA256SUMS.txt"

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

check_unique_keys "$READY"
check_unique_keys "$HMI_INFO"

grep -Fq 'BRANCH_ZIP_READY=YES' "$READY" || fail "branch ZIP is not marked ready"
grep -Fq 'branch_zip_status=READY_FOR_VEHICLE_TEST' "$HMI_INFO" ||
    fail "HMI BUILD_INFO does not mark branch ZIP vehicle-ready"
grep -Fq 'branch_zip_policy=GITHUB_BRANCH_ZIP_INSTALLABLE' "$HMI_INFO" ||
    fail "HMI BUILD_INFO direct-download policy missing"
mode=$(sed -n 's/^mode=//p' "$HMI_INFO")
case "$mode" in
  PRIVATE111_DIRECT_DISPLAY_V3_WHEEL_ZOOM|PRIVATE111_DIRECT_DISPLAY_V3_3_OEM_LOWER_BAR) ;;
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
    grep -Fq 'safearea_policy=V33_OEM_X_VERTICAL_60_450' "$HMI_INFO" ||
        fail "V3.3 HMI safeArea policy is not top60/bottom450"
    grep -Fq 'geometry_safearea_space=OEM_X_VERTICAL_60_450' "$HMI_INFO" ||
        fail "V3.3 HMI safeArea coordinate-space marker missing"
    grep -Fq 'safearea_full=370,60,700,390' "$READY" ||
        fail "V3.3 FULL safeArea ready marker mismatch"
    grep -Fq 'safearea_small=490,60,460,390' "$READY" ||
        fail "V3.3 SMALL safeArea ready marker mismatch"
    grep -Fq "rgi_metadata_sha256=$actual_rgi_sha" "$READY" ||
        fail "V3.3 ready marker RGI SHA mismatch"
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
