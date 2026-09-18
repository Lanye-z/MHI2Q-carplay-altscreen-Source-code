#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
echo "NOTE: this experimental branch does not use the Mirror sidecar as the production display path."
exec /bin/sh "$ROOT/VERIFY-NATIVE-DIRECT-RELEASE.sh" "$@"
