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
2. the CarPlay AltScreen `viewAreas/safeArea` advertised for the cluster;
3. the stock Sport + SMALL map-plane translation, without changing render scale.

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

## 2. Layout adaptation: safeArea plus stock map-plane translation

The captured OEM `visible_active_x/y/w/h` values describe the physical region
that is safe from cluster occlusion. They must **not** be interpreted as
"shrink the full 1440x455 video into this box", because that would distort the
map aspect ratio.

The renderer therefore keeps the native stream size:

```
renderer_scale=0
displayable3=1440x455
```

There are two independent geometry layers:

1. **CarPlay safeArea** — tells the phone where important navigation UI should
   land;
2. **map-plane translation** — reproduces the OEM position of the full-size map
   plane.

For Classic and Sport FULL, and for Classic SMALL, the renderer offset is
`(0,0)`.

For **Sport SMALL**, the OEM layout reports:

```
small_stage_dx=-476
small_stage_dy=0
```

matching the stock `CombiMapController.positionMap()` behavior for map planes
33/58. V2 now applies that translation to the full 1440x455 displayable3
content. The texture is not scaled. The left edge moves outside the viewport
and GLES performs natural clipping.

## 3. Safe-area resolver and coordinate compensation

The runtime consumes:

```
/tmp/mmi-mirror-hmi.state
```

from the already vehicle-tested Java controller. The file supplies:

```
view=FULL|SMALL
layout_name=<OEM layout class>
small_stage_dx=<layout 80>
small_stage_dy=<layout 81>
```

For the tested B9 layout family, the measured **physical** unobscured regions
remain:

```
FULL  physical safe region = 370,49,700x300
SMALL physical safe region = 490,49,460x300
```

However, CarPlay `safeArea` is expressed in the phone's source canvas, before
the renderer translation. Therefore Sport SMALL must compensate the -476 px
map shift:

```
physical = source + renderer_offset

Sport SMALL:
physical safe x = 490
renderer dx     = -476
source safe x   = 490 - (-476) = 966
```

The four session setups are therefore:

| State | Renderer offset | CarPlay source safeArea | Physical safe region after translation |
| --- | ---: | ---: | ---: |
| CLASSIC_FULL | `(0,0)` | `370,49,700x300` | `370,49,700x300` |
| CLASSIC_SMALL | `(0,0)` | `490,49,460x300` | `490,49,460x300` |
| SPORT_FULL | `(0,0)` | `370,49,700x300` | `370,49,700x300` |
| **SPORT_SMALL** | **`(-476,0)`** | **`966,49,460x300`** | **`490,49,460x300`** |

This distinction is important: Classic/Sport can share the same **physical**
safe region while still requiring different CarPlay source coordinates because
Sport SMALL moves the full map plane.

The hook logs the resolved contract as:

```
ALTAREA_LAYOUT_SAFE_V2
safe_source=...
safe_physical=...
renderer_offset=...
renderer_scale=0
```

The sidecar independently logs:

```
PHASE=OEM_MAP_PLACEMENT
renderer_offset=...
size=1440x455
renderer_scale=0
natural_clip=1
session_latched=1
```

The separate file:

```
/tmp/carplay-oem-geometry.state
```

remains **observation-only evidence** from `OEM_LAYOUT_OBSERVER_V1`. It is not
used as a runtime control input.

If the display size, HMI state, or layout class is not recognized, both sides
fail safe:

- the hook uses full-screen safeArea;
- the sidecar keeps fullscreen destination `(0,0)`;
- type111 is not withheld solely because layout adaptation failed.

For the AltScreen/cluster display, `drawUIOutsideSafeArea` remains undefined.

## 4. Runtime switching scope

Both safeArea and map-plane translation are **latched at session setup**.

This version does not claim an unproven same-session CarPlay command for
changing the active view-area while the current type111 session is already
running.

Therefore:

- if CarPlay connects while the VC is Sport SMALL, the session starts with
  `renderer_offset=(-476,0)` and source `safeArea=(966,49,460x300)`;
- if it connects in the other three states, the corresponding table entry is
  applied;
- Java continues observing FULL/SMALL and CLASSIC/SPORT changes live;
- changing the VC layout during an already-running session remains
  observation-only until a verified same-session CarPlay view-area transition
  command is identified.

This avoids a dangerous half-switch where the renderer moves but the phone
still uses the previous safeArea.

## 5. Startup safety

The proven display path is unchanged:

```
Private111 setup
 -> stock OMX
 -> decoded SHM
 -> displayable3 first present
 -> Java Context80
```

The layout resolver affects the type111 display dictionary and the sidecar's
session-latched full-size map translation. Both paths have fullscreen fallbacks,
and neither path changes the 1440x455 render scale.

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

- sidecar `main.cpp` (source-driven pacing + session map translation);
- sidecar `gl_renderer.cpp` (negative destination coordinates with natural clipping);
- universal hook source `p1404_airplay.c` (CarPlay safeArea + translation compensation).

Until both are rebuilt and promoted:

```
release_binary_status=V2_BINARY_STALE_LAYOUT_PROTOCOL_REBUILDS_REQUIRED
vehicle_zip_status=NOT_READY_NATIVE_REBUILDS_REQUIRED
```

Do not vehicle-test the ZIP until the release metadata, hashes and verifier all
report `READY_FOR_VEHICLE_TEST`.
