#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
echo "NOTE: BaseVideo3 direct-display verifier is superseded by Context80 Readback V1."
exec /bin/sh "$ROOT/VERIFY-CONTEXT80-READBACK-V1.sh"
