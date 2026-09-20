#!/bin/sh
BASE="$0"
RESOLVED=$(command -v -- "$BASE" 2>/dev/null)
[ -n "$RESOLVED" ] || RESOLVED="$BASE"
DIR=$(cd -P -- "$(dirname -- "$RESOLVED")" 2>/dev/null && pwd -P)
[ -n "$DIR" ] || { echo "FAIL: cannot resolve script directory"; exit 126; }
exec /bin/sh "$DIR/oem_plane_census_capture.sh" Classic_Full
