# OEM Layout Second Screen V3 — True Cluster Wheel Zoom

Branch: `experiment/oem-layout-second-screen_v3`

Base branch: `experiment/oem-layout-second-screen_v2`

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

V3 adds a separate control plane:

```text
Audi steering-wheel roller
  -> ClusterService.onMagnificationChanged(int)
  -> WheelZoomBridge
  -> discrete ZOOM_IN / ZOOM_OUT events
  -> native CarPlay control backend
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

## Candidate CarPlay wire command — MUST be locally verified before enabling

A public reverse-engineered CarPlay receiver implementation currently records the cluster map zoom command as:

```text
type = "changeMapZoomLevel"

params:
  uuid = <cluster / AltScreen stream UUID>
  zoomDirection = 0   # zoom in / '+'
  zoomDirection = 1   # zoom out / '-'
```

It also identifies the SDK entry point:

```text
AirPlayReceiverSessionChangeMapZoomLevel(...)
```

Some reverse-engineering notes mention a `zoomFactor` key, while the working sender implementation emits only `uuid + zoomDirection`. Therefore V3 must **not** guess whether `zoomFactor` is required or what value/type it uses.

Before enabling this command on the vehicle, verify the exact command dictionary using the local Xcode / CarPlay Simulator environment and preferably capture the actual argument passed to `AirPlayReceiverSessionSendCommand`.

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

## Event semantics — do not collapse wheel steps

True CarPlay zoom is an event API, unlike the old absolute local zoom level.

If one callback reports:

```text
delta = -3
```

V3 must preserve three logical zoom-in steps:

```text
ZOOM_IN
ZOOM_IN
ZOOM_IN
```

Do not publish only a final absolute level and do not let a low-rate "latest state" poll collapse intermediate wheel events.

Every logical event needs a monotonic sequence number and at-most-once consumption. The Java->native transport may use an IPC path or a bounded queue/ring, but it must preserve event ordering and multiplicity.

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

## Implementation gate

The branch is intentionally created before the zoom command is enabled.

Next gate:

```text
LOCAL_XCODE_PROTOCOL_CAPTURE == PASS
```

Only after the local capture proves command type, parameter keys, value types, direction mapping, target UUID semantics, and callback/response behavior should V3 add the vehicle sender.
