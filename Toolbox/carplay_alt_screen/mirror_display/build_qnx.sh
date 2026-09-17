#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
QNX_HOST="${QNX_HOST:-/usr/qnx650/host/qnx6/x86}"
QNX_TARGET="${QNX_TARGET:-/usr/qnx650/target/qnx6}"
export QNX_HOST QNX_TARGET
CC="${CC:-$QNX_HOST/usr/bin/ntoarmv7-gcc}"
export CC
[ -x "$CC" ] || { echo "ERROR: QNX ARMv7 gcc driver not found: $CC" >&2; exit 1; }
cd "$ROOT"
make clean
make
BIN="build/carplay-alt111-mirror-display"
file "$BIN" 2>/dev/null || true
ls -lh "$BIN"
READELF="$QNX_HOST/usr/bin/ntoarmv7-readelf"
if [ -x "$READELF" ]; then
  if "$READELF" -d "$BIN" | grep -q 'libstdc++'; then echo "ERROR: unexpected dynamic libstdc++ dependency" >&2; exit 1; fi
fi
if command -v strings >/dev/null 2>&1; then
  strings "$BIN" | grep -Fq 'window58-wm-context-v3' || { echo 'ERROR: built sidecar is missing build id window58-wm-context-v3' >&2; exit 1; }
else
  grep -a -Fq 'window58-wm-context-v3' "$BIN" || { echo 'ERROR: built sidecar is missing build id window58-wm-context-v3' >&2; exit 1; }
fi
echo "MIRROR_BUILD_ID=window58-wm-context-v3"
echo "MIRROR_BUILD=PASS output=$ROOT/$BIN"
