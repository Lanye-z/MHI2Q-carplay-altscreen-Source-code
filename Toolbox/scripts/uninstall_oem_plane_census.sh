#!/bin/sh
set -u
DST_DIR="/mnt/app/root/oem-plane-census"

echo "OBSERVER_ONLY_UNINSTALL=YES"
echo "CARPLAY_FILES_TOUCHED=NO"

mount -uw /mnt/app || { echo "FAIL: cannot mount /mnt/app rw"; exit 1; }
rm -rf "$DST_DIR"
sync
mount -ur /mnt/app || true

echo "OEM_PLANE_CENSUS_UNINSTALL=PASS"
