#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
echo "NOTE: current branch uses the promoted direct-display sidecar; Window58 readback is retired."
exec /bin/sh "$ROOT/VERIFY-NATIVE-DIRECT-RELEASE.sh" "$@"
