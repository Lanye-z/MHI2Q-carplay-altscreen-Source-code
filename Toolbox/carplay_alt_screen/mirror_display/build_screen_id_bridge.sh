#!/bin/sh
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
SRC="$ROOT/src/screen_id_bridge.c"
OUT="${1:-$ROOT/build/id-bridge}"
TARGET=armv7-linux-gnueabi
CC="${CC:-clang}"
RE="${READELF:-arm-linux-gnueabihf-readelf}"
mkdir -p "$OUT/stubs"

CF="-target $TARGET -march=armv7-a -marm -mfloat-abi=softfp -fPIC -O2 -ffreestanding"
CF="$CF -fno-stack-protector -fno-builtin -nostdinc -Wall -Wextra -Werror"
CF="$CF -isystem $($CC -print-file-name=include)"
LF="-fuse-ld=lld -nostdlib -shared -Wl,--build-id=none,--no-rosegment,-z,norelro,-z,max-page-size=4096"
LF="$LF -Wl,--hash-style=sysv -Wl,--allow-shlib-undefined"

echo 'int __screen_id_bridge_stub(void){return 0;}' > "$OUT/stub.c"
$CC $CF -c "$OUT/stub.c" -o "$OUT/stub.o"
$CC --target=$TARGET -fuse-ld=lld -nostdlib -shared   -Wl,--build-id=none,-soname,libc.so.3,-z,max-page-size=4096   "$OUT/stub.o" -o "$OUT/stubs/libc.so.3"

cat > "$OUT/exports.map" <<'MAP'
{
  global:
    screen_get_window_property_iv;
  local:
    *;
};
MAP

$CC $CF -c "$SRC" -o "$OUT/screen_id_bridge.o"
$CC --target=$TARGET $LF -Wl,-soname,libscreen_id_bridge.so   -Wl,--version-script,"$OUT/exports.map"   -L"$OUT/stubs" -Wl,-l:libc.so.3   "$OUT/screen_id_bridge.o" -o "$OUT/libscreen_id_bridge.so"

printf "\002\000\000\005" | dd of="$OUT/libscreen_id_bridge.so"   bs=1 seek=36 conv=notrunc status=none

if command -v "$RE" >/dev/null 2>&1; then
  "$RE" -h "$OUT/libscreen_id_bridge.so" | grep -Eq 'Flags:.*0x5000002'
  needed=$("$RE" -d "$OUT/libscreen_id_bridge.so" |
    sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p' |
    tr '\n' ' ' | sed 's/ $//')
  [ "$needed" = "libc.so.3" ] || {
    echo "ERROR: unexpected DT_NEEDED: $needed" >&2
    exit 1
  }
fi

strings "$OUT/libscreen_id_bridge.so" | grep -Fq 'WINDOW58_ID_BRIDGE'
strings "$OUT/libscreen_id_bridge.so" | grep -Fq 'screen_get_window_property_cv'
echo "SCREEN_ID_BRIDGE_BUILD=PASS output=$OUT/libscreen_id_bridge.so"
