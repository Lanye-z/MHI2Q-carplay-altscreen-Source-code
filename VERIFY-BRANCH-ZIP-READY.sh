#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
READY="$ROOT/BRANCH-ZIP-READY.txt"
HMI_INFO="$ROOT/Toolbox/carplay_alt_screen/hmi/BUILD_INFO.txt"
JAR="$ROOT/Toolbox/carplay_alt_screen/hmi/carplay_hook-basevideo3.jar"
HOOK="$ROOT/Toolbox/carplay_alt_screen/universal/libcarplay_altscreen.so"
SUMS="$ROOT/SHA256SUMS.txt"

fail(){ echo "BRANCH_ZIP_VERIFY=FAIL: $*" >&2; exit 1; }
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

grep -Fq 'BRANCH_ZIP_READY=YES' "$READY" || fail "branch ZIP is not marked ready"
grep -Fq 'branch_zip_status=READY_FOR_VEHICLE_TEST' "$HMI_INFO" ||
    fail "HMI BUILD_INFO does not mark branch ZIP vehicle-ready"
grep -Fq 'branch_zip_policy=GITHUB_BRANCH_ZIP_INSTALLABLE' "$HMI_INFO" ||
    fail "HMI BUILD_INFO direct-download policy missing"
grep -Fq 'mode=PRIVATE111_DIRECT_DISPLAY_V3_WHEEL_ZOOM' "$HMI_INFO" ||
    fail "HMI mode is not V3 wheel zoom"
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

sh "$ROOT/VERIFY-NATIVE-DIRECT-RELEASE.sh"

if command -v sha256sum >/dev/null 2>&1; then
    (cd "$ROOT" && sha256sum -c SHA256SUMS.txt >/dev/null) ||
        fail "root SHA256 manifest mismatch"
else
    echo "BRANCH_ZIP_SHA256_MANIFEST=SKIPPED reason=sha256sum_unavailable"
fi

echo "BRANCH_ZIP_VERIFY=PASS"
echo "mode=PRIVATE111_DIRECT_DISPLAY_V3_WHEEL_ZOOM"
echo "jar_sha256=$actual_jar_sha"
echo "hook_sha256=$actual_hook_sha"
echo "download_policy=GITHUB_BRANCH_ZIP_INSTALLABLE"
