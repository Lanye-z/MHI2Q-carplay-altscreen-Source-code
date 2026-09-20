# OEM Layout Second Screen V2

Branch: `experiment/oem-layout-second-screen_v2`

This branch is an experimental derivative of
`experiment/oem-layout-second-screen`.

It keeps the proven:

```
Private111 -> stock OMX -> decoded SHM -> displayable3 -> Java Context80
```

chain and changes only:

1. sidecar presentation pacing;
2. the CarPlay AltScreen `viewAreas/safeArea` advertised for the cluster.

## 1. Source-driven sink pacing

Vehicle logs from the previous branch showed:

```
decoded producer ~31-32 fps
presented output ~15-17 fps
```

while the sidecar independently added a relative 33.3 ms sleep after every
successful present.

V2 removes that post-success delay.

The sidecar now:

- presents every fresh decoded sequence immediately;
- sleeps only when no new sequence is available;
- uses a 5 ms no-new-frame poll;
- treats those short polls as normal idle time;
- reports a real decoded stall only after >=120 ms without sequence progress.

Expected markers:

```
present_policy=source-driven
no_success_sleep=1
no_new_frame_poll_us=5000
stall_report_after_ms=120
```

The producer remains uncapped and the Private111 / OMX / SHM ABI is unchanged.

## 2. Layout adaptation belongs in CarPlay safeArea, not GLES scaling

The first implementation attempt used the observed:

```
visible_active_x/y/w/h
```

as a GLES destination rectangle.

That was intentionally retired before compilation.

The captured OEM values describe the region safe from cluster occlusion. They
must not be interpreted as "shrink the full 1440x455 video into this box",
because that would distort the map aspect ratio.

The renderer therefore remains full 1440x455:

```
renderer_scale=0
displayable3=1440x455
```

Layout adaptation is instead applied when the type111 CarPlay display
dictionary is built:

```
viewAreas[0] = full 1440x455
viewAreas[0].safeArea = current OEM safe region
initialViewArea = 0
```

This lets the phone keep navigation UI/hints inside the unobscured region while
the map itself can still fill the complete cluster stream.

## 3. Safe-area resolver

The hook resolves the current layout in this order.

### A. Exact ListModel176 geometry

If present and consistent with the current HMI state:

```
/tmp/carplay-oem-geometry.state
```

is used directly.

Required properties include:

```
observer=OEM_LAYOUT_OBSERVER_V1
valid=1
map_width_effective=1440
map_height_effective=455
visible_active_x/y/w/h
```

The geometry snapshot is accepted only if its `view` and `layout_class`
still match the current early HMI state, preventing a stale reconnect snapshot
from overriding a changed layout.

### B. Measured K1004 fallback

The Java controller publishes the early state:

```
/tmp/mmi-mirror-hmi.state
```

before the second-screen first-present path.

For the vehicle-tested layout classes containing:

```
LayoutMIB2HighB9
```

the measured fallback is:

```
FULL  safeArea = 370,49,700x300
SMALL safeArea = 490,49,460x300
```

The four classified states are:

- CLASSIC_FULL
- CLASSIC_SMALL
- SPORT_FULL
- SPORT_SMALL

The captured K1004 vehicle currently reports the same safe geometry for
CLASSIC and SPORT at a given FULL/SMALL mode, so the branch does not invent
different SPORT coordinates.

### C. Unknown layout fallback

If the display size, HMI layout class, or state is not recognized:

```
safeArea = full display
```

The type111 display is therefore never withheld because layout adaptation
failed.

## 4. Runtime switching scope

This version changes the CarPlay `safeArea` when the display dictionary is
built for the session.

It does **not** claim an unproven same-session CarPlay command for dynamically
switching the active view-area index.

Therefore:

- the current layout is applied correctly on a new CarPlay session/reconnect;
- Java continues observing FULL/SMALL and CLASSIC/SPORT changes live;
- same-session live layout switching remains observation-only until a verified
  CarPlay control command for view-area transition is identified.

This is deliberate: the branch must not force a reconnect or distort the
renderer merely to simulate dynamic safe-area switching.

## 5. Startup safety

The proven display path is unchanged:

```
Private111 setup
 -> stock OMX
 -> decoded SHM
 -> displayable3 first present
 -> Java Context80
```

The safe-area resolver only affects the type111 display dictionary and has a
full-screen fallback.

It does not change:

- Main110;
- Private111 listener/session lifecycle;
- H264 tap;
- stock OMX;
- decoded SHM ABI;
- displayable3 creation;
- Java Context80 ownership;
- Window58 policy;
- LD_PRELOAD isolation.

## 6. Build status

Both native artifacts must be rebuilt because this branch changes:

- sidecar `main.cpp` (source-driven pacing);
- universal hook source `p1404_airplay.c` (CarPlay safeArea).

Until both are rebuilt and promoted:

```
release_binary_status=V2_BINARY_STALE_LAYOUT_PROTOCOL_REBUILDS_REQUIRED
vehicle_zip_status=NOT_READY_NATIVE_REBUILDS_REQUIRED
```

Do not vehicle-test the ZIP until the release metadata, hashes and verifier all
report `READY_FOR_VEHICLE_TEST`.
