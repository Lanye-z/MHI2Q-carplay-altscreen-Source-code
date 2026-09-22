# OEM Layout Second Screen V3.2

Branch: `experiment/oem-layout-second-screen_v3.2`

Baseline: `experiment/oem-layout-second-screen_v3.1`

## Purpose

V3.2 is a single-variable safe-area experiment. It keeps the V3.1 renderer,
layout observer, FULL/SMALL switching, Sport placement, Context80 ownership and
wheel-zoom behavior unchanged.

Only the CarPlay safe-area vertical contract changes.

## Safe-area policy

V3.1:

- FULL:  `x=370, y=49, w=700, h=300`
- SMALL: `x=490, y=49, w=460, h=300`

V3.2:

- FULL:  `x=370, y=0, w=700, h=455`
- SMALL: `x=490, y=0, w=460, h=455`

Horizontal geometry is intentionally preserved so the OEM-derived FULL/SMALL
and Sport horizontal placement remains intact. The vertical safe region is
opened to the complete physically visible 455-row displayable3 viewport.

## Deliberately unchanged

- two advertised viewAreas and `updateViewArea` runtime switching
- FULL/SMALL detection
- B9/B9 Sport layout observation
- Sport SMALL map-plane translation, including the tested `dx=-476` fallback
- private111 / stock OMX / decoded SHM path
- displayable3 / Java-owned Context80 route
- V3.1 renderer policy: 1440x542 source at 1:1 into 1440x455 viewport, bottom
  87 rows naturally clipped
- wheel-zoom capture, target-follow pacing and stall guards

## Test objective

Check whether Apple Maps restores the V2/OEM-like vertical composition:

- vehicle-position marker returns lower in the map
- ETA returns lower
- compass returns lower
- horizontal placement remains unchanged in FULL/SMALL and Sport layouts

If those elements move together while horizontal geometry stays correct, it is
strong evidence that V3.1's `y=49,h=300` CarPlay safeArea was the source of the
vertical layout regression.

## Build state

Source change affects `libcarplay_altscreen.so`. The inherited V3.1 binary is
stale until the native overlay is rebuilt and promoted. Therefore this branch
is intentionally marked NOT READY for vehicle ZIP testing until rebuild and
package/hash synchronization are complete.
