#!/bin/sh
set -u

VOLUME=""
for candidate in /net/mmx/fs/sda0 /net/mmx/fs/sda1 /net/mmx/fs/sdb0 /net/mmx/fs/sdb1 /fs/sda0 /fs/sda1 /fs/sdb0 /fs/sdb1; do
    if [ -d "$candidate/Toolbox" ]; then
        VOLUME=$candidate
        break
    fi
done
[ -n "$VOLUME" ] || { echo "FAIL: Toolbox SD card not found"; exit 1; }

SRC="$VOLUME/Toolbox/carplay_alt_screen/plane_census/release/oem-plane-census"
INFO="$VOLUME/Toolbox/carplay_alt_screen/plane_census/release/BUILD_INFO.txt"
DST_DIR="/mnt/app/root/oem-plane-census/bin"
DST="$DST_DIR/oem-plane-census"

[ -s "$SRC" ] || {
    echo "FAIL: QNX observer binary missing from release/"
    echo "ACTION=BUILD Toolbox/carplay_alt_screen/plane_census/build_qnx.sh"
    exit 2
}
[ -f "$INFO" ] && grep -Fq 'build_id=OEM_PLANE33_58_CENSUS_V1_1' "$INFO" || {
    echo "FAIL: observer BUILD_INFO mismatch"
    exit 3
}
grep -Fq 'mode=READ_ONLY' "$INFO" || { echo "FAIL: release is not marked read-only"; exit 3; }
grep -Fq 'screen_context=WINDOW_MANAGER_CONTEXT' "$INFO" || {
    echo "FAIL: release does not use the window-manager event observer"
    exit 3
}

echo "OBSERVER_ONLY=YES"
echo "CARPLAY_PROTOCOL_CHANGES=NONE"
echo "CARPLAY_START=NOT_REQUESTED"
echo "CONTEXT_SWITCH=NONE"
echo "SCREEN_PROPERTY_WRITES=NONE"

mount -uw /mnt/app || { echo "FAIL: cannot mount /mnt/app rw"; exit 4; }
mkdir -p "$DST_DIR" || {
    mount -ur /mnt/app >/dev/null 2>&1 || true
    exit 5
}
cp "$SRC" "$DST.new" || {
    mount -ur /mnt/app >/dev/null 2>&1 || true
    exit 6
}
chmod 755 "$DST.new" || {
    rm -f "$DST.new"
    mount -ur /mnt/app >/dev/null 2>&1 || true
    exit 7
}
mv "$DST.new" "$DST" || {
    mount -ur /mnt/app >/dev/null 2>&1 || true
    exit 8
}
sync
mount -ur /mnt/app || true

echo "OEM_PLANE_CENSUS_INSTALL=PASS target=$DST"
echo "reboot_required=NO"
echo "NEXT_ACTION=START_OBSERVER"
