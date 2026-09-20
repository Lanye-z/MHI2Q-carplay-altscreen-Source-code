# OEM Layout Second Screen V2

Branch: `experiment/oem-layout-second-screen_v2`

This branch is an experimental derivative of `experiment/oem-layout-second-screen`.
It intentionally keeps the proven Private111 -> stock OMX -> decoded SHM ->
displayable3 -> Java Context80 chain and changes only the sidecar presentation
policy and renderer destination geometry.

## 1. Source-driven sink pacing

The previous sidecar used an independent relative 30 fps sleep after each
successful present. Vehicle logs showed decoded producer progress around
31-32 fps but long-run display presentation around 15-17 fps.

V2 removes the post-success 33.3 ms sleep. The sidecar now:

- presents immediately when a fresh decoded SHM sequence is available;
- sleeps only when no new sequence is available;
- uses a bounded 5 ms no-new-frame poll;
- keeps the producer uncapped policy unchanged.

Expected log marker:

```
present_policy=source-driven
no_success_sleep=1
no_new_frame_poll_us=5000
```

## 2. Four-state OEM layout renderer control

The existing Java observer remains the source of truth and continues to publish:

```
/tmp/carplay-oem-geometry.state
```

The sidecar consumes only a valid `OEM_LAYOUT_OBSERVER_V1` state and uses:

```
visible_active_x
visible_active_y
visible_active_w
visible_active_h
```

as the GLES destination rectangle.

The four recognized runtime states are:

- CLASSIC_FULL
- CLASSIC_SMALL
- SPORT_FULL
- SPORT_SMALL

The first vehicle capture showed SPORT and CLASSIC currently share the same
active rectangle for a given FULL/SMALL mode, so this branch deliberately does
not invent separate geometry where the vehicle did not report one.

Observed K1004 geometry:

```
FULL  = 370,49,700x300
SMALL = 490,49,460x300
map   = 1440x455
```

SPORT/CLASSIC is identified from `layout_class`; FULL/SMALL is identified
from `view` / `NAV_VIEW_SIZE_CHOICE`.

## 3. Startup safety

The proven first-present and Context80 acquisition path is preserved.

Startup remains:

```
decoded first frame
 -> displayable3 first present
 -> Java Context80
 -> then consume OEM layout geometry
```

If the OEM geometry file is missing, invalid, stale in schema, or out of bounds,
the sidecar retains the previous destination. The bootstrap destination remains
full-screen 1440x455.

This branch does not change:

- Private111 negotiation;
- H264 tap;
- stock OMX decode;
- decoded SHM ABI;
- Java Context80 ownership;
- displayable3 creation;
- LD_PRELOAD lifecycle;
- Window58 policy.

## 4. Build status

The source is intentionally marked:

```
release_binary_status=V2_BINARY_STALE_LAYOUT_ADAPT_REBUILD_REQUIRED
vehicle_zip_status=NOT_READY_QNX_SIDECAR_REBUILD_REQUIRED
```

until the sidecar is rebuilt and promoted from this branch.

Do not vehicle-test the ZIP before the rebuilt sidecar has been promoted and
the verifier reports `READY_FOR_VEHICLE_TEST`.
