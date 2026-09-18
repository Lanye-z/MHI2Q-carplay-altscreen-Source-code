#!/bin/sh
set -eu

# VERIFY-MIRROR-RELEASE.sh
# Validates the Mirror display sidecar release binary, manifests, and
# the frozen universal CarPlay AltScreen hook. Replaces VERIFY-V3-RELEASE.sh.
#
# Usage:
#   sh VERIFY-MIRROR-RELEASE.sh [--require-v4]

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
RELEASE="$ROOT/Toolbox/carplay_alt_screen/mirror_display/release"
BIN="$RELEASE/carplay-alt111-mirror-display"
HOOK="$ROOT/Toolbox/carplay_alt_screen/universal/libcarplay_altscreen.so"
RELEASE_SUMS="$RELEASE/SHA256SUMS"
TOP_SUMS="$ROOT/SHA256SUMS.txt"
SOURCE_MAP="$ROOT/PACKAGE_SOURCE_MAP.json"
HOOK_BASELINE=0dea2efef91b842cdaae6973a9b8ec3fd95c06cb48e9f3118fc545a78ee288de

REQUIRE_V4=0
for arg in "$@"; do
    case "$arg" in
        --require-v4) REQUIRE_V4=1 ;;
    esac
done

fail() {
    echo "MIRROR_RELEASE_VERIFY=FAIL: $*" >&2
    exit 1
}

pass() {
    echo "MIRROR_RELEASE_VERIFY=PASS"
    echo "mirror_sha256=$1"
    echo "hook_sha256=$2"
    echo "build_id=$3"
    echo "HOOK_UNCHANGED=YES"
}

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        fail "sha256sum or shasum is required"
    fi
}

binary_strings() {
    if command -v strings >/dev/null 2>&1; then
        strings "$1"
    else
        grep -a -o '[[:print:]][[:print:]]*' "$1"
    fi
}

require_executable() {
    path=$1
    if [ -x "$path" ]; then
        return
    fi
    rel=${path#"$ROOT/"}
    if command -v git >/dev/null 2>&1 &&
       [ "$(git -C "$ROOT" ls-files -s -- "$rel" 2>/dev/null | awk '{print $1}')" = 100755 ]; then
        return
    fi
    case $(uname -s 2>/dev/null || echo unknown) in
        MINGW*|MSYS*|CYGWIN*)
            echo "NOTE: executable bit is not exposed by this Windows filesystem"
            return
            ;;
    esac
    fail "release binary is not executable"
}

[ -f "$BIN" ] || fail "release binary missing: $BIN"
require_executable "$BIN"
[ -f "$HOOK" ] || fail "validated hook missing: $HOOK"
[ -f "$RELEASE_SUMS" ] || fail "release SHA256SUMS missing"
[ -f "$TOP_SUMS" ] || fail "top-level SHA256SUMS.txt missing"
[ -f "$SOURCE_MAP" ] || fail "PACKAGE_SOURCE_MAP.json missing"

hook_sha=$(sha256_file "$HOOK")
[ "$hook_sha" = "$HOOK_BASELINE" ] ||
    fail "validated hook changed: $hook_sha (expected $HOOK_BASELINE)"

for marker in \
    'window58-wm-event-v4' \
    'GATE PASS trigger=PHONE_REQUEST_111' \
    'WINDOW_MANAGER_CONTEXT event observer ready' \
    'target CREATE' \
    'target FIRST_POST' \
    'screen_read_window'
do
    binary_strings "$BIN" | grep -Fq "$marker" ||
        fail "release binary marker missing: $marker"
done

for marker in 'window census' 'SCREEN_PROPERTY_WINDOW_COUNT' 'SCREEN_PROPERTY_WINDOWS'; do
    binary_strings "$BIN" | grep -Fq "$marker" &&
        fail "release binary contains removed V3 census marker: $marker" || true
done

build_id=$(binary_strings "$BIN" | grep -m1 'window58-wm-event-v[0-9]' || echo "unknown")

if [ "$REQUIRE_V4" = 1 ]; then
    echo "$build_id" | grep -q 'window58-wm-event-v4' ||
        fail "build id is not V4: $build_id"
fi

mirror_sha=$(sha256_file "$BIN")

release_mirror_sha=$(awk '$2 == "carplay-alt111-mirror-display" {print $1}' "$RELEASE_SUMS")
release_hook_sha=$(awk '$2 == "libcarplay_altscreen.so" {print $1}' "$RELEASE_SUMS")
top_mirror_sha=$(awk '$2 == "Toolbox/carplay_alt_screen/mirror_display/release/carplay-alt111-mirror-display" {print $1}' "$TOP_SUMS")
top_hook_sha=$(awk '$2 == "Toolbox/carplay_alt_screen/universal/libcarplay_altscreen.so" {print $1}' "$TOP_SUMS")
map_mirror_sha=$(sed -n 's/.*"Toolbox\/carplay_alt_screen\/mirror_display\/release\/carplay-alt111-mirror-display": "\([0-9a-fA-F]*\)".*/\1/p' "$SOURCE_MAP")
map_hook_sha=$(sed -n 's/.*"Toolbox\/carplay_alt_screen\/universal\/libcarplay_altscreen.so": "\([0-9a-fA-F]*\)".*/\1/p' "$SOURCE_MAP")

for recorded in "$release_mirror_sha" "$top_mirror_sha" "$map_mirror_sha"; do
    [ "$recorded" = "$mirror_sha" ] ||
        fail "mirror SHA256 manifest mismatch: recorded=$recorded actual=$mirror_sha"
done
for recorded in "$release_hook_sha" "$top_hook_sha" "$map_hook_sha"; do
    [ "$recorded" = "$hook_sha" ] ||
        fail "hook SHA256 manifest mismatch: recorded=$recorded actual=$hook_sha"
done

pass "$mirror_sha" "$hook_sha" "$build_id"
