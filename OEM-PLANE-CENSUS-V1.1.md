# OEM Plane 33/58 Census V1.1

Branch: `experiment/oem-layout-second-screen-v1.1`

Baseline: `experiment/oem-layout-second-screen`.

## Purpose

This branch is a **stock-map, observation-only** follow-up to the OEM layout experiment.
It does not test a new CarPlay protocol/viewArea/safeArea path and does not require an iPhone connection.

The single goal is to collect the native QNX Screen geometry of stock map windows whose
`SCREEN_PROPERTY_ID_STRING` is `33` or `58` in four OEM Virtual Cockpit states:

```text
Classic Full
Classic Small
Sport Full
Sport Small
```

The resulting evidence should answer:

1. Are stock windows 33/58 actually `1440x542`?
2. Does Sport Small change only `POSITION.x` by approximately `-476`?
3. Does Full/Small change `SIZE`, `SOURCE_SIZE`, or `BUFFER_SIZE`?
4. Does any native Screen property become `1440x455`?

## Safety contract

The native census process:

- creates a privileged `SCREEN_WINDOW_MANAGER_CONTEXT` owned by the observer;
- discovers stock windows from the global window-manager event queue (`CREATE / PROPERTY / POST / CLOSE`);
- does **not** use `SCREEN_PROPERTY_WINDOW_COUNT/WINDOWS` as a global census, because QNX scopes those lists to the calling context;
- matches only ID strings `33` and `58` by default;
- calls only `screen_get_*` APIs for existing windows/buffers;
- does **not** call `screen_set_*`;
- does **not** create, manage, reparent, destroy, resize, move, show or hide any existing window;
- does **not** switch DisplayManager/HMI contexts;
- does **not** start CarPlay, type111, the private111 hook, decoded SHM, displayable3, or Context80.

The INSTALL action only copies the standalone observer binary to:

```text
/mnt/app/root/oem-plane-census/bin/oem-plane-census
```

and UNINSTALL only removes `/mnt/app/root/oem-plane-census`.

## Properties collected

For each matching window, V1.1 attempts to read:

```text
SCREEN_PROPERTY_SIZE
SCREEN_PROPERTY_BUFFER_SIZE
SCREEN_PROPERTY_SOURCE_SIZE
SCREEN_PROPERTY_SOURCE_POSITION
SCREEN_PROPERTY_POSITION
SCREEN_PROPERTY_VISIBLE
SCREEN_PROPERTY_FORMAT
SCREEN_PROPERTY_OWNER_PID
SCREEN_PROPERTY_USAGE
SCREEN_PROPERTY_SOURCE_CLIP_POSITION
SCREEN_PROPERTY_SOURCE_CLIP_SIZE
SCREEN_PROPERTY_VIEWPORT_POSITION
SCREEN_PROPERTY_VIEWPORT_SIZE
SCREEN_PROPERTY_CLIP_POSITION
SCREEN_PROPERTY_CLIP_SIZE
SCREEN_PROPERTY_SCALE_FACTOR
SCREEN_PROPERTY_SCALE_QUALITY
SCREEN_PROPERTY_TRANSFORM
SCREEN_PROPERTY_MANAGER_STRING
```

It also attempts group handle/name, display handle/ID string, render-buffer count, and per-buffer
`BUFFER_SIZE`, `FORMAT`, `STRIDE`, and planar offsets.

QNX 6.5 exposes window viewport, clip and transformation-matrix getters, so V1.1 records all of them.
`SCREEN_PROPERTY_SCALE_FACTOR` is the transform matrix's fixed-point precision, not by itself a resize
ratio; the actual matrix is therefore recorded as `SCREEN_PROPERTY_TRANSFORM`. QNX 6.5 does not expose
a generic standard window `parent` getter in this API, so parent is reported unavailable rather than
guessed. Unsupported/vendor properties are kept as `NA rc=... errno=...`; failure itself is useful evidence.

## Build state

The repository currently contains the observer **source and build recipe**. Before vehicle use, compile it
with the QNX 6.5 ARMv7 toolchain:

```sh
sh Toolbox/carplay_alt_screen/plane_census/build_qnx.sh
```

A successful build creates:

```text
Toolbox/carplay_alt_screen/plane_census/release/oem-plane-census
Toolbox/carplay_alt_screen/plane_census/release/BUILD_INFO.txt
Toolbox/carplay_alt_screen/plane_census/release/SHA256SUMS
```

Do not run INSTALL until that release binary has been built and inspected. Creating this branch does
**not** mean the QNX binary has already been compiled.

## Recommended one-car capture sequence

Do not connect/start CarPlay for this experiment.

1. Build/promote the QNX observer binary and prepare the Toolbox SD card.
2. Open `MMI-Cockpit-Carplay` and run **INSTALL OBSERVER**.
3. Run **START OBSERVER**. The watcher now remains resident and listens only for QNX Screen window events.
4. Return the car to its stock Audi map/navigation display.
5. Before the first capture, toggle the stock View once (for example Classic Small → Classic Full). This deliberately causes the already-existing map planes to emit PROPERTY/POST events so the observer can acquire both 33/58 handles without creating or modifying any window.
6. Select **Classic + Full**, wait for the OEM layout to settle, then run **CAPTURE CLASSIC FULL**.
7. Select **Classic + Small**, wait, then run **CAPTURE CLASSIC SMALL**.
8. Select **Sport + Full**, wait, then run **CAPTURE SPORT FULL**.
9. Select **Sport + Small**, wait, then run **CAPTURE SPORT SMALL**.
10. Run **STATUS / SUMMARY** and verify all four labels have at least one sample and that both `window33.state` / `window58.state` have been observed.
11. Run **STOP OBSERVER** or directly **UNINSTALL OBSERVER**.

Each capture writes a timestamped file and appends to:

```text
MMI-Cockpit-Carplay/logs/oem-plane-census/plane33-58-census.log
```

The persistent watcher atomically maintains `/tmp/oem-plane-census/window33.state` and
`window58.state` whenever it sees a target CREATE/PROPERTY/POST event. Each labeled CAPTURE
copies the latest native state for both IDs into the SD log. If the old HMI geometry observer
state happens to exist, the helper also copies it for correlation, but the native census does
not depend on it.

## Expected comparison

| Question | Evidence to compare |
| --- | --- |
| Is the stock plane 1440x542? | `SIZE`, `BUFFER_SIZE`, `SOURCE_SIZE`, per-buffer size |
| Is Sport Small translation-only? | `POSITION` plus all size/source/crop properties |
| Does Full/Small resize the map source/window? | Full vs Small `SIZE/SOURCE_SIZE/BUFFER_SIZE` |
| Is 1440x455 a native Screen extent? | every size, source, clip and buffer field |
| Is there hidden source/destination clipping? | `SOURCE_CLIP_*`, `CLIP_*`, `VIEWPORT_*` |
| Is there a Screen transform/scale? | `TRANSFORM` plus `SCALE_FACTOR/SCALE_QUALITY` |
| Is the object DisplayManager-owned? | `MANAGER_STRING`, group/display metadata |

The experiment should not infer a transform from ListModel numbers. It records native properties and lets
the four snapshots decide whether the stock 542→455 behavior is SCALE, CROP, CLIP, NONE, or remains outside
the observable Screen layer.

## Source layout

```text
Toolbox/carplay_alt_screen/plane_census/
  src/plane_census.c
  build_qnx.sh
  release/                 # generated by build

Toolbox/scripts/
  install_oem_plane_census.sh
  start_oem_plane_census.sh
  stop_oem_plane_census.sh
  oem_plane_census_capture.sh
  oem_plane_census_classic_full.sh
  oem_plane_census_classic_small.sh
  oem_plane_census_sport_full.sh
  oem_plane_census_sport_small.sh
  status_oem_plane_census.sh
  uninstall_oem_plane_census.sh
```

The branch intentionally leaves the baseline CarPlay implementation untouched; the GEM page exposes only
the stock-map census actions so an on-car operator does not accidentally start the CarPlay experimental chain.
