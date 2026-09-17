#!/bin/sh
# Build entry points for the pinned development source snapshot.
# This script never replaces the checked-in vehicle runtime automatically.
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
UP="$ROOT/source_upstream/Toolbox/carplay_alt_screen"
PIN=9fa2cb5541586158f6cc1e93b8391396950189a0
OUTROOT="${ALTSCREEN_SOURCE_BUILD_ROOT:-$ROOT/dev-build}"

fail(){ echo "FAIL: $*" >&2; exit 1; }
[ -d "$UP/src" ] || fail "source submodule is not initialized; run: git submodule update --init Toolbox/carplay_alt_screen/source_upstream"

if command -v git >/dev/null 2>&1 && [ -d "$ROOT/source_upstream/.git" -o -f "$ROOT/source_upstream/.git" ]; then
    HEAD=$(git -C "$ROOT/source_upstream" rev-parse HEAD 2>/dev/null || true)
    [ "$HEAD" = "$PIN" ] || fail "source_upstream is not at pinned commit $PIN (found ${HEAD:-unknown})"
fi

case "${1:-}" in
  hook|universal)
    OUT="${2:-$OUTROOT/universal}"
    mkdir -p "$OUT"
    exec /bin/sh "$UP/src/build_qnx_arm.sh" "$OUT"
    ;;
  mirror)
    OUT="${2:-$OUTROOT/mirror}"
    mkdir -p "$OUT"
    if [ -x "$UP/mirror_display/build_qnx.sh" ]; then
        ALT111_MIRROR_BUILD_DIR="$OUT" exec /bin/sh "$UP/mirror_display/build_qnx.sh"
    else
        fail "upstream mirror build_qnx.sh is missing"
    fi
    ;;
  *)
    echo "usage: $0 {hook|universal|mirror} [output-dir]" >&2
    echo "note: build outputs are development artifacts only; they are not installed or copied into release/ automatically" >&2
    exit 2
    ;;
esac
