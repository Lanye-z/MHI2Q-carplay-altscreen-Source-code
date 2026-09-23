# OEM Layout Second Screen V3.2

Branch: `experiment/oem-layout-second-screen_v3.2`

Baseline: `experiment/oem-layout-second-screen_v3.1`

## Purpose

V3.2 started as a single-variable safe-area experiment. It keeps the V3.1
renderer, layout observer, FULL/SMALL switching, Sport placement, Context80
ownership and wheel-zoom behavior unchanged.

The CarPlay safe-area vertical contract remains the only layout change. A later
low-risk observability hardening pass adds diagnostics-only improvements and a
frame-age sampling-race guard without changing wheel pacing or display routing.

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
- wheel-zoom capture, target-follow pacing and stall guards (100 ms healthy pacing,
  150 ms fallback/retry, target/rebase behavior and command semantics are frozen)

## Test objective

Check whether Apple Maps restores the V2/OEM-like vertical composition:

- vehicle-position marker returns lower in the map
- ETA returns lower
- compass returns lower
- horizontal placement remains unchanged in FULL/SMALL and Sport layouts

If those elements move together while horizontal geometry stays correct, it is
strong evidence that V3.1's `y=49,h=300` CarPlay safeArea was the source of the
vertical layout regression.

## Low-risk observability hardening

The post-V3.2 hardening pass is intentionally constrained:

- decoded-source stall logging: first diagnostic at 500 ms, then approximately
  every 5 s while idle; frame polling and freeze-last-frame behavior are unchanged
- displayable3 state remains observation-only, but the atomic state snapshot is
  published mode 0644 so the HMI process can read it across uid/umask boundaries
- controller logs whether the state file is present/readable plus H.264 and
  decoded-frame counters; those fields do not gate Context80 or trigger recovery
- wheel decoded-frame age keeps the original scheduler timestamp and clamps only
  the impossible "future publication" race to zero; genuine short uint32 wrap
  intervals and all normal pacing thresholds remain unchanged
- no EGL/window auto-rebuild, no authorization change, no safe-area change

## Build state

The safe-area hook/JAR package had already been promoted. This observability
pass changes the QNX sidecar source (`mirror_display/src/main.cpp`), so the
checked-in sidecar binary is now intentionally considered stale until it is
rebuilt with the QNX 6.5 ARMv7 toolchain and promoted.

The branch is therefore marked
`NOT_READY_QNX_SIDECAR_REBUILD_REQUIRED` rather than falsely advertising a
vehicle-ready ZIP. The native hook and HMI JAR can still be rebuilt by the
existing V3 CI; vehicle readiness returns only after the new sidecar binary and
hash manifests are synchronized.
