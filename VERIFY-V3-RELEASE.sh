#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
RELEASE="$ROOT/Toolbox/carplay_alt_screen/mirror_display/release"
BIN="$RELEASE/carplay-alt111-mirror-display"
HOOK="$ROOT/Toolbox/carplay_alt_screen/universal/libcarplay_altscreen.so"
RELEASE_SUMS="$RELEASE/SHA256SUMS"
TOP_SUMS="$ROOT/SHA256SUMS.txt"
SOURCE_MAP="$ROOT/PACKAGE_SOURCE_MAP.json"
HOOK_BASELINE=0dea2efef91b842cdaae6973a9b8ec3fd95c06cb48e9f3118fc545a78ee288de

fail() {
    echo "V3_RELEASE_VERIFY=FAIL: $*" >&2
    exit 1
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

[ -f "$BIN" ] || fail "release binary missing"
require_executable "$BIN"
[ -f "$HOOK" ] || fail "validated hook missing"

for marker in window58-wm-context-v3 WINDOW_MANAGER_CONTEXT \
    "window census" "bound CarPlay window" "capture buffer ready" \
    screen_read_window
do
    binary_strings "$BIN" | grep -Fq "$marker" ||
        fail "release binary marker missing: $marker"
done

mirror_sha=$(sha256_file "$BIN")
hook_sha=$(sha256_file "$HOOK")
[ "$hook_sha" = "$HOOK_BASELINE" ] ||
    fail "validated hook changed: $hook_sha"

release_mirror_sha=$(awk '$2 == "carplay-alt111-mirror-display" {print $1}' "$RELEASE_SUMS")
release_hook_sha=$(awk '$2 == "libcarplay_altscreen.so" {print $1}' "$RELEASE_SUMS")
top_mirror_sha=$(awk '$2 == "Toolbox/carplay_alt_screen/mirror_display/release/carplay-alt111-mirror-display" {print $1}' "$TOP_SUMS")
top_hook_sha=$(awk '$2 == "Toolbox/carplay_alt_screen/universal/libcarplay_altscreen.so" {print $1}' "$TOP_SUMS")
map_mirror_sha=$(sed -n 's/.*"Toolbox\/carplay_alt_screen\/mirror_display\/release\/carplay-alt111-mirror-display": "\([0-9a-fA-F]*\)".*/\1/p' "$SOURCE_MAP")
map_hook_sha=$(sed -n 's/.*"Toolbox\/carplay_alt_screen\/universal\/libcarplay_altscreen.so": "\([0-9a-fA-F]*\)".*/\1/p' "$SOURCE_MAP")

for recorded in "$release_mirror_sha" "$top_mirror_sha" "$map_mirror_sha"; do
    [ "$recorded" = "$mirror_sha" ] ||
        fail "mirror SHA256 manifest mismatch"
done
for recorded in "$release_hook_sha" "$top_hook_sha" "$map_hook_sha"; do
    [ "$recorded" = "$hook_sha" ] ||
        fail "hook SHA256 manifest mismatch"
done

echo "V3_RELEASE_VERIFY=PASS"
echo "mirror_sha256=$mirror_sha"
echo "hook_sha256=$hook_sha"
