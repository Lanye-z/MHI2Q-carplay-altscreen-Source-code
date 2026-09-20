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
  if "$READELF" -d "$BIN" | grep -q 'libstdc++'; then
    echo "ERROR: unexpected dynamic libstdc++ dependency" >&2
    exit 1
  fi
fi

check_marker() {
  marker=$1
  if command -v strings >/dev/null 2>&1; then
    strings "$BIN" | grep -Fq "$marker"
  else
    grep -a -Fq "$marker" "$BIN"
  fi
}

for marker in \
  'carplay-private111-direct-display-v2' \
  'PHASE=H264_SHM_ATTACHED' \
  'PHASE=DECODED_SHM_WAIT_SIZE' \
  'PHASE=SOURCE_SESSION' \
  'PHASE=GATE_RECOVER_CURRENT_SESSION' \
  'matching_identity_plus_frame_progress' \
  'packed_tight_required=1' \
  'stream111_request_or_phone_marker' \
  'STREAM_111_REQUESTED=YES' \
  'PHASE=PIPELINE_SOURCE_PRIMED' \
  'startup_frame_progress_required=2' \
  'PHASE=H264_STREAM_VALID' \
  'PHASE=DECODER_FIRST_FRAME' \
  'PHASE=NV12_CSC_READY' \
  'PHASE=DISPLAYABLE3_FIRST_PRESENT' \
  'PHASE=DIRECT111_ACTIVE' \
  'PHASE=FRAME_PRESENT_TIMING' \
  'PHASE=FRAME_CHAIN_HEALTH' \
  'window58_readback=0'
do
  check_marker "$marker" || {
    echo "ERROR: built sidecar is missing direct111 marker: $marker" >&2
    exit 1
  }
done

if strings "$BIN" | grep -Fq 'screen_read_window'; then
  echo "ERROR: Window58 readback leaked into direct-display binary" >&2
  exit 1
fi
if strings "$BIN" | grep -Fq 'WINDOW_MANAGER_CONTEXT event observer ready'; then
  echo "ERROR: Window58 event observer leaked into direct-display binary" >&2
  exit 1
fi

echo "MIRROR_BUILD_ID=carplay-private111-direct-display-v2"
echo "MIRROR_BUILD=PASS output=$ROOT/$BIN"
