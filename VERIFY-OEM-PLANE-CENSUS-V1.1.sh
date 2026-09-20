#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
SRC="$ROOT/Toolbox/carplay_alt_screen/plane_census/src/plane_census.c"
BUILD="$ROOT/Toolbox/carplay_alt_screen/plane_census/build_qnx.sh"
GEM="$ROOT/Toolbox/GEM/mqb-carplayAltScreen.esd"

fail(){ echo "OEM_PLANE_CENSUS_VERIFY=FAIL $*" >&2; exit 1; }

for f in \
  "$SRC" "$BUILD" "$GEM" \
  "$ROOT/Toolbox/scripts/install_oem_plane_census.sh" \
  "$ROOT/Toolbox/scripts/start_oem_plane_census.sh" \
  "$ROOT/Toolbox/scripts/stop_oem_plane_census.sh" \
  "$ROOT/Toolbox/scripts/oem_plane_census_capture.sh" \
  "$ROOT/Toolbox/scripts/oem_plane_census_classic_full.sh" \
  "$ROOT/Toolbox/scripts/oem_plane_census_classic_small.sh" \
  "$ROOT/Toolbox/scripts/oem_plane_census_sport_full.sh" \
  "$ROOT/Toolbox/scripts/oem_plane_census_sport_small.sh" \
  "$ROOT/Toolbox/scripts/status_oem_plane_census.sh" \
  "$ROOT/Toolbox/scripts/uninstall_oem_plane_census.sh" \
  "$ROOT/OEM-PLANE-CENSUS-V1.1.md"
do
    [ -s "$f" ] || fail "missing_or_empty=$f"
done

for marker in \
  'OEM_PLANE33_58_CENSUS_V1_1' \
  'SCR_WINDOW_MANAGER_CONTEXT         1' \
  'SCR_EVENT_CREATE                   1' \
  'SCR_EVENT_PROPERTY                 2' \
  'SCR_EVENT_CLOSE                    3' \
  'SCR_EVENT_POST                     9' \
  'SCR_PROP_TYPE                     47' \
  'SCR_PROP_WINDOW                   52' \
  'SCR_PROP_ID_STRING                20' \
  'SCR_PROP_BUFFER_SIZE               5' \
  'SCR_PROP_POSITION                 35' \
  'SCR_PROP_SIZE                     40' \
  'SCR_PROP_SOURCE_POSITION          41' \
  'SCR_PROP_SOURCE_SIZE              42' \
  'SCR_PROP_STRIDE                   44' \
  'SCR_PROP_VISIBLE                  51' \
  'SCR_PROP_SOURCE_CLIP_POSITION     68' \
  'SCR_PROP_SOURCE_CLIP_SIZE         72' \
  'SCR_PROP_VIEWPORT_POSITION        74' \
  'SCR_PROP_VIEWPORT_SIZE            75' \
  'SCR_PROP_CLIP_POSITION            91' \
  'SCR_PROP_CLIP_SIZE                92' \
  'SCR_PROP_SCALE_FACTOR            114' \
  'SCR_PROP_TRANSFORM               127' \
  'SCR_PROP_MANAGER_STRING          152'
do
    grep -Fq "$marker" "$SRC" || fail "source_marker_missing=$marker"
done

grep -Fq '!strcmp(id, "33")' "$SRC" || fail "target_33_missing"
grep -Fq '!strcmp(id, "58")' "$SRC" || fail "target_58_missing"
grep -Fq 'source=WINDOW_MANAGER_EVENT_QUEUE' "$SRC" || fail "event_source_marker_missing"
grep -Fq 'SCREEN_PROPERTY_WINDOW_COUNT/WINDOWS are scoped' "$SRC" ||
    fail "global_census_regression_guard_missing"

if grep -Eq 'screen_set_|screen_manage_window|screen_create_window|screen_destroy_window' "$SRC"; then
    fail "forbidden_screen_write_or_window_lifecycle_api"
fi

if grep -Eq 'updateViewArea|safeArea|ScreenStreamProcessData|carplay111_decoded|displayable3|Context80' "$SRC"; then
    fail "carplay_or_renderer_logic_in_observer"
fi

for f in \
  "$BUILD" \
  "$ROOT/Toolbox/scripts/install_oem_plane_census.sh" \
  "$ROOT/Toolbox/scripts/start_oem_plane_census.sh" \
  "$ROOT/Toolbox/scripts/stop_oem_plane_census.sh" \
  "$ROOT/Toolbox/scripts/oem_plane_census_capture.sh" \
  "$ROOT/Toolbox/scripts/oem_plane_census_classic_full.sh" \
  "$ROOT/Toolbox/scripts/oem_plane_census_classic_small.sh" \
  "$ROOT/Toolbox/scripts/oem_plane_census_sport_full.sh" \
  "$ROOT/Toolbox/scripts/oem_plane_census_sport_small.sh" \
  "$ROOT/Toolbox/scripts/status_oem_plane_census.sh" \
  "$ROOT/Toolbox/scripts/uninstall_oem_plane_census.sh"
do
    sh -n "$f" || fail "shell_syntax=$f"
done

for label in \
 'CAPTURE CLASSIC FULL' \
 'CAPTURE CLASSIC SMALL' \
 'CAPTURE SPORT FULL' \
 'CAPTURE SPORT SMALL' \
 'INSTALL OBSERVER' \
 'START OBSERVER' \
 'STATUS / SUMMARY' \
 'STOP OBSERVER' \
 'UNINSTALL OBSERVER'
do
    grep -Fq "$label" "$GEM" || fail "gem_action_missing=$label"
done

if grep -Fq '/start_mmi_cockpit_carplay' "$GEM" || grep -Fq '/install_mmi_cockpit_carplay' "$GEM"; then
    fail "gem_still_exposes_carplay_test_actions"
fi

REL="$ROOT/Toolbox/carplay_alt_screen/plane_census/release"
if [ -s "$REL/oem-plane-census" ]; then
    STRINGS="${STRINGS:-strings}"
    command -v "$STRINGS" >/dev/null 2>&1 || fail "strings_tool_missing"
    "$STRINGS" "$REL/oem-plane-census" | grep -Fq 'OEM_PLANE33_58_CENSUS_V1_1' || fail "release_binary_marker_missing"
    if "$STRINGS" "$REL/oem-plane-census" | grep -Eq 'screen_set_|screen_manage_window|screen_create_window|screen_destroy_window'; then
        fail "release_binary_contains_forbidden_screen_write"
    fi
    [ -s "$REL/BUILD_INFO.txt" ] || fail "built_binary_without_BUILD_INFO"
    grep -Fq 'mode=READ_ONLY' "$REL/BUILD_INFO.txt" || fail "release_mode_not_read_only"
    grep -Fq 'screen_context=WINDOW_MANAGER_CONTEXT' "$REL/BUILD_INFO.txt" ||
        fail "release_context_not_window_manager"
    echo "release_binary=present_and_read_only_markers_verified"
else
    echo "release_binary=NOT_BUILT source_only=1"
fi

echo "OEM_PLANE_CENSUS_VERIFY=PASS"
echo "mode=stock_map_read_only"
echo "targets=33,58"
echo "states=Classic_Full,Classic_Small,Sport_Full,Sport_Small"
