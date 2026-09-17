#!/bin/sh
# Build entry point for source files intentionally vendored into this repository.
# GitHub Download ZIP users do not need git submodules.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
OUTROOT="${ALTSCREEN_SOURCE_BUILD_ROOT:-$ROOT/dev-build}"
fail(){ echo "FAIL: $*" >&2; exit 1; }
case "${1:-}" in
  mirror)
    ME="$ROOT/mirror_display"
    [ -f "$ME/src/main.cpp" ] || fail "vendored Mirror source is missing"
    OUT="${2:-$OUTROOT/mirror}"
    mkdir -p "$OUT"
    /bin/sh "$ME/build_qnx.sh"
    BIN="$ME/build/carplay-alt111-mirror-display"
    [ -x "$BIN" ] || fail "Mirror build completed without expected binary: $BIN"
    cp "$BIN" "$OUT/carplay-alt111-mirror-display"
    echo "MIRROR_BUILD=PASS output=$OUT/carplay-alt111-mirror-display"
    ;;
  hook|universal)
    fail "this ZIP self-contained source bundle currently covers the Mirror sidecar; the installed universal hook remains the checked-in reviewed runtime artifact"
    ;;
  *)
    echo "usage: $0 mirror [output-dir]" >&2
    echo "or simply run: ./BUILD-MIRROR-QNX.sh from repository root" >&2
    exit 2
    ;;
esac
