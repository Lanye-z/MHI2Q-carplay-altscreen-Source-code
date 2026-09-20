#!/bin/sh
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
out=$(mktemp "${TMPDIR:-/tmp}/frame-telemetry.XXXXXX")
trap 'rm -f "$out"' EXIT HUP INT TERM
${CXX:-c++} -std=gnu++98 -Wall -Wextra -Werror \
    "$root/test_frame_telemetry.cpp" -o "$out"
"$out"
