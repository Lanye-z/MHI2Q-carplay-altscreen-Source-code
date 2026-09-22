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

Native keeps a signed pending target:

```text
pending += signed_steps
pending is clamped to [-4, +4]

positive -> ZOOM_OUT
negative -> ZOOM_IN
```

Opposite directions cancel before transmission:

```text
pending = +3
new input = -2
-> pending = +1
```

CarPlay exposes only a one-step directional `changeMapZoomLevel` command, so the pending target is drained one command at a time:

```text
first eligible intent after idle -> send immediately
remaining pending intent          -> at most one command per 200 ms
```

The 200 ms interval is an initial vehicle-test pacing value, not a claim about the exact Audi OEM timeout. It is deliberately kept in one constant (`WHEEL_ZOOM_PACE_US`) so the next vehicle log can tune it without touching any video/display path.

The CarPlay completion callback remains observational. A `status=0` response means the command was accepted; it does **not** prove that Apple Maps/Amap has finished its zoom animation, so the callback never unlocks an immediate next send.


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
  -> native accumulator
  -> +/- cancellation
  -> clamp pending to four steps
  -> first eligible command immediately
  -> remaining commands at >=200 ms spacing
```

The queue still carries an epoch and monotonic source sequence, and stale pre-attach records are discarded. Native still gates zoom on the current private111 generation, route readiness and verified Java80 ownership. If any gate closes, unsent pending zoom intent is cleared instead of leaking into a later session.

Vehicle-test logging must include:

```text
WHEEL_ZOOM_INPUT
WHEEL_ZOOM_QUEUE
WHEEL_ZOOM_ACCUMULATE
WHEEL_ZOOM_PACED_SEND
CLUSTER_ZOOM_SUBMIT
CLUSTER_ZOOM_RESPONSE
```

The key acceptance checks are now:

1. slow single detents still feel immediate;
2. a multi-step magnification jump produces one signed intent, not an immediate command burst;
3. opposite direction input cancels unsent pending intent;
4. no two CarPlay zoom submits are intentionally emitted inside the 200 ms pacing window;
5. Apple Maps remains responsive;
6. Amap no longer shows the previous severe burst-induced stall/catch-up behavior;
7. the incoming type111 content itself changes scale; no local pixel zoom is introduced.

The display chain, V3.1 1440x542-to-1440x455 1:1 viewport clipping, Context80, OMX/SHM path, CPU CSC and lifecycle remain outside this wheel change.
