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

## 2. Layout adaptation: map-local safeArea + OEM map translation

The ListModel176-derived rectangles are treated as **map/source-local safe
areas**, not as post-layout physical VC rectangles and not as GLES scale boxes.

The two sizes must be kept distinct:

```
private111 / CarPlay coded canvas = runtime display geometry
                                  = 1440x542 in the vehicle logs
displayable3 sink/map plane       = 1440x455
renderer_scale                    = 0 for OEM X-placement
```

The measured ListModel geometry also reports the related 1440x540 cluster
screen model. The hook therefore recognizes only the observed B9-family
vertical extents 542 / 540 / 455 instead of silently requiring 455 at the
CarPlay `/info` stage.

The two independent geometry layers are:

1. **CarPlay safeArea in the 1440x455 map canvas**
2. **Audi map-plane translation in the VC compositor**

The CarPlay source safe areas are fixed by FULL/SMALL:

```
FULL  source safeArea = 370,49,700x300
SMALL source safeArea = 490,49,460x300
```

The Audi map-plane translation is independently derived from layout constants
80/81:

```
Classic FULL  -> (0,0)
Classic SMALL -> (0,0)
Sport   FULL  -> (0,0)
Sport   SMALL -> (-476,0)
```

Therefore Sport SMALL is intentionally **not compensated back to the centre**:

```
physical = source + renderer_offset
Sport SMALL physical safe x = 490 + (-476) = 14
```

This matches the stock B9Sport behavior in
`CombiMapController.positionMap()`: the `-476,0` offset belongs to map planes
33/58. It is not applied to the KDK maneuver panel/backings.

The resulting four-state geometry is:

| State | Renderer offset | CarPlay source safeArea | Resulting physical safe region |
| --- | ---: | ---: | ---: |
| CLASSIC_FULL | `(0,0)` | `370,49,700x300` | `370,49,700x300` |
| CLASSIC_SMALL | `(0,0)` | `490,49,460x300` | `490,49,460x300` |
| SPORT_FULL | `(0,0)` | `370,49,700x300` | `370,49,700x300` |
| **SPORT_SMALL** | **`(-476,0)`** | **`490,49,460x300`** | **`14,49,460x300`** |

## 3. Two declared type111 viewAreas

A CarPlay session cannot switch to a view-area index that was never declared.
The type111 display therefore advertises both Audi candidates at session setup:

```
viewAreas[0]:
  viewArea = full runtime type111 canvas   # observed 1440x542
  safeArea = 370,49,700x300                # FULL

viewAreas[1]:
  viewArea = full runtime type111 canvas   # observed 1440x542
  safeArea = 490,49,460x300                # SMALL
```

The coded type111 frame keeps the runtime-negotiated dimensions in both states;
the second viewArea does not change stream resolution or shrink the video. It
only gives iOS a second safe-area layout. The independent displayable3 sink
continues to use its proven 1440x455 map plane.

`initialViewArea` follows the VC state present when `/info` is built:

```
FULL  -> initialViewArea=0, adjacentViewAreas=[1]
SMALL -> initialViewArea=1, adjacentViewAreas=[0]
```

For type111 the implementation deliberately does **not** add the
type110-only `viewAreaTransitionControl`, `viewAreaStatusBarEdge` or
`viewAreaSupportsFocusTransfer` keys. Apple's screen-dictionary builder
type-gates those fields to type110, while ALT/cluster viewArea entries carry the
rect plus nested safeArea.

The separate observer file:

```
/tmp/carplay-oem-geometry.state
```

remains evidence only. Runtime control continues to consume the already
vehicle-tested:

```
/tmp/mmi-mirror-hmi.state
```

which publishes `view`, `layout_name`, `small_stage_dx` and
`small_stage_dy`.

## 4. Same-session live switching

FULL/SMALL no longer requires a CarPlay reconnect.

Both view areas are predeclared even if Java's first HMI state file arrives
slightly after `/info`; otherwise a cold start could accidentally advertise
only one index and make later live switching impossible.

The runtime path is:

```
Audi View button
 -> NAV_VIEW_SIZE_CHOICE changes
 -> Java updates /tmp/mmi-mirror-hmi.state
 -> hook watcher detects FULL/SMALL
 -> AirPlay /command updateViewArea(index 0/1)
 -> iPhone switches to the already-declared type111 viewArea

in parallel:

 -> sidecar watcher detects layout/view
 -> Classic/Sport renderer offset is re-applied
 -> current texture is immediately re-rendered
```

The AirPlay command follows the CarPlay SDK wire shape:

```
type = updateViewArea
params.uuid = <type111 display UUID>
params.viewAreaIndex = 0 | 1
params.animationDurationMillis = 0
params.adjacentViewAreas = [other index]
```

The native watcher polls the HMI state at 100 ms and retries a failed/timed-out
view-area transition. The sidecar polls placement at 50 ms. If the geometry
changes while decoded video is momentarily stalled, the sidecar redraws the
last uploaded texture immediately, so the map moves without waiting for the
next video frame.

This also covers same-session Classic/Sport changes:

- FULL Classic/Sport both remain at renderer offset `(0,0)`;
- SMALL Classic uses `(0,0)`;
- SMALL Sport uses `(-476,0)`;
- switching between Classic SMALL and Sport SMALL therefore moves the current
  map immediately even though both use CarPlay viewArea index 1.

Expected logs include:

```
ALTAREA_LAYOUT_SAFE_V3 ... viewAreaCount=2 ...
PHASE=ALT111_VIEWAREA_TARGET ... old=0 new=1 ...
PHASE=ALT111_VIEWAREA_SUBMIT ... viewAreaIndex=1 ... same_session=1
PHASE=ALT111_VIEWAREA_RESULT ... accepted=1
PHASE=OEM_MAP_PLACEMENT ... renderer_offset=-476,0 ... live_switch=1
PHASE=OEM_MAP_RERENDER ... last_frame_redrawn=1
```

If the HMI state is not recognized, the safe fallback is full-screen geometry;
the code does not invent a new layout or withhold Main110.

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
live full-size map translation. Both paths have fullscreen fallbacks, and
neither path changes the 1440x455 render scale.

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

- sidecar `main.cpp` (source-driven pacing + live map translation/rerender);
- sidecar `gl_renderer.cpp` (negative destination coordinates with natural clipping);
- universal hook `p1404_airplay.c` (two type111 viewAreas + `updateViewArea`);
- native monitor `p1404_cockpit_native.c` (100 ms HMI watcher + retry/response tracking).

Until both are rebuilt and promoted:

```
release_binary_status=V2_BINARY_STALE_LAYOUT_PROTOCOL_REBUILDS_REQUIRED
vehicle_zip_status=NOT_READY_NATIVE_REBUILDS_REQUIRED
```

Do not vehicle-test the ZIP until the release metadata, hashes and verifier all
report `READY_FOR_VEHICLE_TEST`.
