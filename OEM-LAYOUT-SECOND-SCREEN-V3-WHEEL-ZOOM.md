# OEM Layout Second Screen V3.1 — OEM-Paced True Cluster Wheel Zoom

Branch: `experiment/oem-layout-second-screen_v3.1`

Base branch: `experiment/oem-layout-second-screen_v3`

Base commit: `9d672245aac32a2bd7333a7b78d1ba3f09b93d4c`

## Goal

V3 keeps the vehicle-proven V2 video/display path unchanged:

```text
iPhone
  -> private type111
  -> stock AirPlay / OMX
  -> Screen linearizer
  -> decoded SHM
  -> source-driven sidecar
  -> displayable3
  -> Java Context80
  -> Virtual Cockpit
```

V3.1 keeps the wheel control plane separate from the video/display path:

```text
Audi steering-wheel roller
  -> ClusterService.onMagnificationChanged(int)
  -> WheelZoomBridge
  -> one signed OEM-style step intent per callback
  -> native signed-step accumulator
  -> opposite-direction cancellation + bounded pending target
  -> paced one-step CarPlay changeMapZoomLevel drain
  -> AirPlayReceiverSessionSendCommand
  -> iPhone map engine
  -> newly rendered type111 map frames
```

The release goal is **true map viewport zoom on the iPhone**, not local framebuffer / UV / destination scaling.

## Proven input source to reuse

Reuse only the input observer logic from:

- repository: `Lanye-z/mmi-test`
- branch: `v2.5-wheel-zoom-recovery`
- head observed during V3 creation: `efd9dc43ceb25bf3d0f2a9c0b3cca0b7bd2697f9`
- source: `Cluster-HMI/java_overlay/com/luka/carplay/cluster/WheelZoomBridge.java`

Vehicle-proven semantics:

```text
first magnification callback -> seed only

delta = magnification - lastMagnification

delta < 0 -> ZOOM_IN
delta > 0 -> ZOOM_OUT
```

Do **not** port the old local zoom levels, UV transform, destination scaling, or 0.50x..1.50x mapping.

## Confirmed CarPlay wire command

The 2026-09-21 local CarPlay Simulator static-binary audit confirmed the real command construction path. This is no longer a guessed/public-reference-only candidate.

The command is:

```text
type = "changeMapZoomLevel"

params:
  uuid = <cluster / AltScreen stream UUID>
  zoomDirection = 0   # zoom in / '+'
  zoomDirection = 1   # zoom out / '-'
```

Static disassembly also confirms the SDK-facing signature `AirPlayReceiverSessionChangeMapZoomLevel(...)`, but that symbol is not exported by the target AirPlayReceiver runtime. The real transport path remains the already-used `AirPlayReceiverSessionSendCommand` dictionary sender.

Confirmed facts:

- `type = "changeMapZoomLevel"`
- params contain exactly `uuid` and `zoomDirection`
- `zoomDirection` is an integer / CFNumber
- `0 = Zoom In`
- `1 = Zoom Out`
- `zoomFactor` is not present in the command-construction path
- transport is AirPlay RTSP `POST /command` with binary-plist payload

Runtime completion semantics and app-specific behavior remain vehicle-test items; they are logged without assuming that a non-null response is required for success.

## Current native integration point

V2 already resolves and calls:

```text
AirPlayReceiverSessionSendCommand
```

inside:

```text
Toolbox/carplay_alt_screen/src/p1404_airplay.c
```

The existing `alt_send_cluster_event_impl()` already constructs CF dictionaries for cluster events such as:

```text
showUI
forceKeyFrame
stopUI
```

V3 should extend this control layer only after the exact zoom wire contract is proven.

## Event semantics — OEM delayed-step model adapted to CarPlay

The original Audi navigation path carries a signed step count into a delayed zoom handler rather than treating every wheel detent as an immediate renderer call. V3.1 follows that model as closely as the CarPlay API allows.

One HMI magnification callback publishes **one** committed intent record:

```text
delta = -3
-> one OEM_STEPS_V1 record with signed_steps=-3
```

It is no longer expanded into three adjacent queue records.

Native now keeps **two relative levels**, not a short historical command queue:

```text
desired_target += signed_steps
submitted_level changes only after a CarPlay zoom command is submitted successfully
error = desired_target - submitted_level
```

The **outstanding error** `desired_target - submitted_level` is safety-clamped to `[-12, +12]` steps. The completed session movement itself is not capped: whenever desired and submitted levels meet, both relative counters are rebased to zero while the send/input timestamps are preserved. This keeps the safety bound on unsent backlog without creating a cumulative 12-step ceiling during long sessions.

Opposite input retargets the desired level immediately. Example:

```text
desired=+4, submitted=+1
driver turns back by -3
-> desired=+1, submitted=+1
-> target is settled and both relative counters rebase to 0
-> no old ZOOM_OUT commands remain to replay
```

CarPlay still exposes only a one-step directional `changeMapZoomLevel` command, so native follows the latest target one command at a time. Explicit input/send validity flags and the existing stall latch are used instead of treating timestamp value zero as an initialization sentinel, so the modular 32-bit **microsecond** clock remains correct across its ~71.6-minute wrap. The legacy `obs_now_us()` function is intentionally left unchanged because it is actually second-based and is used by existing lifecycle timeouts.

Healthy scheduling is deliberately regular:

```text
wheel scheduler quantum = 50 ms
first detent of a new burst = immediate
consecutive healthy step = >=100 ms after previous submit
normal healthy path = at least one decoded frame progressed after previous submit
```

The decoded-frame signal is now a **stall guard, not the throttle**. Normal zooming no longer waits for three fresh frames. If a submitted command produces no decoded progress and the frame is stale for >=150 ms, the scheduler latches STALL and stops sending. Only recovery from STALL requires three fresh decoded frames with latest-frame age <=100 ms.

If decoded-frame telemetry is temporarily unavailable, the target follower uses a conservative 150 ms timer. If a stall persists for >=1.2 s and the roller has been quiet for >=350 ms, the unresolved target is rebased to the already submitted level. This prevents a recovered phone session from replaying old zoom movement long after the driver stopped.

A >=300 ms gap starts a new interaction burst. Its first detent may wake a static map immediately instead of being blocked merely because the last navigation frame is old.

## Safety / lifecycle gates

A zoom event may be sent only when all required conditions are true:

1. the V3 CarPlay runtime is ready;
2. a valid active receiver/session is available;
3. the cluster / type111 stream generation is current;
4. the cluster display UUID is known;
5. the cluster is currently owned by the CarPlay Context80 path;
6. the event has not already been consumed.

Reconnect/teardown must invalidate stale session/generation references.

The zoom control failure path must fail closed: a failed zoom command must never disturb Main110, type111 decode, displayable3, Context80, or the V2 display lifecycle.

## Logging required for the first vehicle test

Add explicit markers that make one wheel detent traceable end-to-end:

```text
WHEEL_ZOOM_INPUT
  magnification=<n>
  delta=<signed>
  action=ZOOM_IN|ZOOM_OUT
  seq=<n>

WHEEL_ZOOM_QUEUE
  seq=<n>
  action=<...>
  result=queued|dropped
  reason=<...>

CLUSTER_ZOOM_SUBMIT
  seq=<n>
  type=<verified command type>
  uuid=<cluster uuid>
  direction=<verified value>
  rc=<send result>

CLUSTER_ZOOM_RESPONSE
  seq=<n>
  status=<callback status>
```

Keep the existing type111 frame/progress telemetry so the vehicle test can correlate the command with newly rendered frames.

## Success criterion

A successful V3 vehicle test requires all three:

1. the steering-wheel event is captured with the expected sign;
2. the verified CarPlay zoom command is submitted successfully;
3. the **incoming type111 content itself** changes map scale.

Local pixel magnification, cropping, black borders, or destination-rectangle scaling do not count as success.

Test Apple Maps and Amap separately.

## Explicit non-goals

Do not modify for this feature unless evidence proves it is necessary:

- private111 negotiation;
- OMX decode;
- decoded SHM ABI;
- sidecar pacing;
- displayable3 dimensions;
- Context80 lifecycle;
- V2 FULL/SMALL viewAreas;
- Sport Small `-476` translation;
- Main110.

## Implementation / vehicle-test gate

The protocol gate remains the verified CarPlay command:

```text
changeMapZoomLevel(uuid, zoomDirection)
0 = ZOOM_IN
1 = ZOOM_OUT
```

V3.1 changes only the wheel scheduling layer:

```text
Java callback
  -> one OEM_STEPS_V1 signed-step record
  -> desired target accumulator
       target safety clamp = +/-12
       reversal retargets latest desired level
  -> 50 ms wheel scheduler
  -> first detent of a new burst may send immediately
  -> healthy follow
       minimum interval = 100 ms
       require >=1 decoded frame of progress since prior submit
       do NOT require three frames
  -> stall guard
       no post-send progress + frame stale >=150 ms -> STALL
       STALL recovery requires >=3 fresh frames
       latest recovery frame age <=100 ms
       persistent stall >=1.2 s + input quiet >=350 ms
           -> rebase desired target to submitted level
  -> telemetry unavailable
       150 ms conservative timer
  -> one CarPlay zoom step toward the latest desired target
```

The event queue still carries an epoch and monotonic source sequence, and stale pre-attach records are discarded. Native still gates zoom on the current private111 generation, route readiness and verified Java80 ownership. If any gate closes, target-follow state is reset instead of leaking into a later session. Process-local frame progress is sampled under the existing tap lock; no SHM layout/version changes are introduced.

Vehicle-test logging must include:

```text
WHEEL_ZOOM_INPUT
WHEEL_ZOOM_QUEUE
WHEEL_ZOOM_TARGET
WHEEL_ZOOM_FRAME_STALL
WHEEL_ZOOM_FRAME_RECOVERED
WHEEL_ZOOM_STALL_ABORT
WHEEL_ZOOM_STALL_CANCELLED
WHEEL_ZOOM_PACED_SEND
CLUSTER_ZOOM_SUBMIT
CLUSTER_ZOOM_RESPONSE
```

The key acceptance checks are now:

1. a slow single detent is submitted on the first scheduler opportunity;
2. healthy continuous rolling follows at a regular ~100 ms command cadence rather than a ~200 ms polling artifact;
3. reversing the roller changes the latest desired target instead of replaying a historical pending queue;
4. healthy zooming does not wait for three decoded frames; one post-submit progress frame is sufficient;
5. no decoded progress plus >=150 ms stale age latches STALL and blocks additional commands;
6. STALL recovery requires at least three fresh decoded frames before target-follow resumes;
7. a persistent stall is abandoned after >=1.2 s once input has been quiet >=350 ms, preventing late replay;
8. continuous same-direction use can exceed 12 completed steps; the 12-step guard limits only outstanding backlog;
9. timestamp value zero after the 32-bit microsecond wrap is treated as a valid time, not an uninitialized sentinel;
10. the incoming type111 content itself changes scale; no local pixel zoom is introduced.

The display chain, V3.1 1440x542-to-1440x455 1:1 viewport clipping, Context80, OMX/SHM path, CPU CSC and lifecycle remain outside this wheel change.


## Install / restore operation journaling

V3.1 persists complete GEM operation stdout/stderr under the active SD card:

```text
MMI-Cockpit-Carplay/logs/operations/
  install_YYYYMMDD_HHMMSS[ _N ].log
  restore_YYYYMMDD_HHMMSS[ _N ].log
  store_restore_YYYYMMDD_HHMMSS[ _N ].log
```

INSTALL is fail-closed if its persistent SD journal cannot be created before any
production mutation. RESTORE ORIGINAL and STORE LOGS + RESTORE prefer the SD
journal, but recovery itself is never blocked by a logging failure: they fall
back to a flat `/tmp` journal and attempt to flush that journal back to SD after
the restore.

When a new SD card has no trusted HMI backup and INSTALL detects an already
managed live system, the log reports all four independent residual checks before
refusing to snapshot anything as OEM:

```text
RUNTIME_OWNER_PRESENT=YES|NO
SMARTPHONE_INTEGRATOR_HOOK=YES|NO
CURRENT_PACKAGE_JAR_PRESENT=YES|NO
KNOWN_MANAGED_JAR_PRESENT=YES|NO
LIVE_MANAGED_SUMMARY=MANAGED|CLEAN reasons=...
```

Previous V3 wheel-enabled JARs are recognized by the project-only
`com/luka/carplay/cluster/WheelZoomBridge.class` archive member, so detection
does not depend on whole-JAR checksums that change across CI rebuilds. Older
pre-wheel project JAR identities remain as a compatibility fallback.
