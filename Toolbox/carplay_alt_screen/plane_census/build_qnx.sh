#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
QNX_HOST="${QNX_HOST:-/usr/qnx650/host/qnx6/x86}"
QNX_TARGET="${QNX_TARGET:-/usr/qnx650/target/qnx6}"
export QNX_HOST QNX_TARGET
CC="${CC:-$QNX_HOST/usr/bin/ntoarmv7-gcc}"
[ -x "$CC" ] || { echo "ERROR: QNX ARMv7 compiler missing: $CC" >&2; exit 1; }

mkdir -p "$ROOT/build" "$ROOT/release"
"$CC" -O2 -Wall -Wextra -o "$ROOT/build/oem-plane-census" "$ROOT/src/plane_census.c" -ldl

BIN="$ROOT/build/oem-plane-census"
STRINGS="${STRINGS:-}"
if [ -z "$STRINGS" ]; then
    if [ -x "$QNX_HOST/usr/bin/ntoarmv7-strings" ]; then STRINGS="$QNX_HOST/usr/bin/ntoarmv7-strings";
    elif command -v strings >/dev/null 2>&1; then STRINGS="$(command -v strings)";
    fi
fi
[ -n "$STRINGS" ] || { echo "ERROR: strings tool missing" >&2; exit 1; }

for marker in \
  'OEM_PLANE33_58_CENSUS_V1_1' \
  'SCREEN_PROPERTY_SIZE' \
  'SCREEN_PROPERTY_BUFFER_SIZE' \
  'SCREEN_PROPERTY_SOURCE_SIZE' \
  'SCREEN_PROPERTY_SOURCE_POSITION' \
  'SCREEN_PROPERTY_POSITION' \
  'SCREEN_PROPERTY_VISIBLE' \
  'SCREEN_PROPERTY_SOURCE_CLIP_POSITION' \
  'SCREEN_PROPERTY_SOURCE_CLIP_SIZE' \
  'SCREEN_PROPERTY_SCALE_FACTOR' \
  'SCREEN_PROPERTY_MANAGER_STRING' \
  'CENSUS_WATCH_READY' \
  'source=WINDOW_MANAGER_EVENT_QUEUE'
do
    "$STRINGS" "$BIN" | grep -Fq "$marker" || { echo "ERROR: marker missing: $marker" >&2; exit 1; }
done

if "$STRINGS" "$BIN" | grep -Eq 'screen_set_|screen_manage_window|screen_create_window|screen_destroy_window'; then
    echo "ERROR: observer contains a forbidden Screen write/window lifecycle API" >&2
    exit 1
fi

cp "$BIN" "$ROOT/release/oem-plane-census"
chmod 755 "$ROOT/release/oem-plane-census"

SHA=""
if command -v sha256sum >/dev/null 2>&1; then
    SHA="$(sha256sum "$ROOT/release/oem-plane-census" | awk '{print $1}')"
    printf '%s  oem-plane-census\n' "$SHA" > "$ROOT/release/SHA256SUMS"
fi

cat > "$ROOT/release/BUILD_INFO.txt" <<EOF
build_id=OEM_PLANE33_58_CENSUS_V1_1
mode=READ_ONLY
base_branch=experiment/oem-layout-second-screen
carplay_protocol_changes=none
screen_context=WINDOW_MANAGER_CONTEXT
target_id_strings=33,58
screen_property_writes=none
foreign_window_lifecycle_changes=none
event_source=WINDOW_MANAGER_EVENT_QUEUE
context_switches=none
binary_sha256=$SHA
vehicle_binary_status=BUILT_QNX_ARMV7
EOF

echo "OEM_PLANE_CENSUS_BUILD=PASS binary=$ROOT/release/oem-plane-census sha256=$SHA"
