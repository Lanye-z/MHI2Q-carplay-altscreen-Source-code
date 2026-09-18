# Context80 Readback V1 - failure-driven design

Direct BaseVideo3 failed at the DisplayManager handoff:

```text
pre_manage          visible=1
post_manage         visible=0
force_visible rc=0
post_force_visible  visible=0
post_buffers        visible=0
```

Stream111, 1440x542 negotiation, stock OMX creation, CScreenRender configuration
and real-frame posts had already succeeded.

New ownership:
```text
Window58       = decoder producer only
readback/GLES  = pixel bridge
displayable3   = VC consumer only
Context80      = Java/HMI only
```

Readiness is split into source post, destination present, Java Context80 request,
and final human VC confirmation. The old source-post BASEVIDEO3_READY false
positive is no longer used.


## Final pre-vehicle proof gates

The final vehicle candidate adds two explicit observations before software-route
completion is reported:

```text
Window58 event
  -> numeric QNX ID (diagnostic only)
  -> SCREEN_PROPERTY_ID_STRING == "58" (authoritative owner identity)
  -> screen_read_window
  -> GLES first present
  -> Java ctx80 request
  -> IDisplayManager.getCurrentContextID(1)
  -> CTX80_OBSERVED actual=80
```

The promoted V4 sidecar ELF remains unchanged. A small sidecar-only
`libscreen_id_bridge.so` adapts its legacy integer-ID query to the owner-defined
SCREEN_PROPERTY_ID_STRING identity without loading into dio_manager. The CarPlay-facing universal
hook is rebuilt only for the narrowly scoped Private111 post-accept/runtime containment fix below;
the Window58/readback/displayable3/Java Context80 path remains frozen.


Window58 identity is fail-closed: a QNX-generated numeric ID of 58 is never
accepted as the CarPlay source unless the owner-defined
`SCREEN_PROPERTY_ID_STRING` also reads exactly `"58"`.


## 2026-09-18 post-accept containment fix

Vehicle logs proved that type111 SETUP, dataPort advertisement and TCP accept succeeded,
then the worker stalled before `STREAM_111_NETSOCKET_CREATE_RETURN`. The accepted
dio_manager process had inherited this hook into `sh` / `pfctl` while removing the
temporary exact-port PF rule.

The branch now keeps the already-validated child-process containment and fixes the
actual post-accept blocking hazard:
- remove only `libcarplay_altscreen.so` from dio_manager's inherited `LD_PRELOAD`;
- reject non-CarPlay helper processes in the constructor before libc/GOT/runtime setup;
- `FORCE_START` remains an authorization marker and cannot override process identity;
- after `ACCEPT_RETURN`, close only the listener and immediately continue to
  `NetSocket_CreateWithNative`; do **not** run `popen/system/pfctl` on that worker path;
- retain the exact-port PF rule until Private111 teardown;
- stop/delete the private ScreenSession before PF cleanup, and treat PF cleanup failure
  as non-fatal to the CarPlay session teardown.

Deliberately unchanged in this fix:
- Main110 / stock Window59 handling;
- type111 split/merge, listener creation, security derivation and accept semantics;
- Window58 producer identity and readback sidecar;
- displayable3 GLES sink and Java-only Context80 ownership;
- global send/write/recv/close interception surface.

The next vehicle proof must first show:
`ACCEPT_RETURN -> FIREWALL_DEFERRED -> NETSOCKET_CREATE_RETURN ->
START_CALL -> START_RETURN -> PROCESSFRAMES_BEGIN`.
The accepted 65500 socket should be actively consumed rather than accumulating a
fixed Recv-Q. Only after that sequence is proven should Window58/readback/Context80
be evaluated.


## 2026-09-18 display-truth diagnostics

The next source revision deliberately leaves the Private111 transport, Main110 /
Window59, stock OMX, Java Context80 policy and the default
`screen_manage_window` behavior unchanged. It adds observability before the
DisplayManager ownership experiment:

```text
NATIVE_111_FIRST_REAL_FRAME result=POSTED
  -> SOURCE_READBACK_RC=OK
  -> SOURCE_PIXEL_PROBE hash/min/max/nonblack/changed
  -> SOURCE_PIXEL_VALID=YES
  -> GLES_PRESENT=YES
  -> CTX80_OBSERVED actual=80
```

`SOURCE_PIXEL_VALID` samples the BGRA frame sparsely (16-pixel steps on the
normal 1440x542 source), ignores alpha for black detection, and requires at
least 0.5% sampled RGB pixels above the black threshold. Invalid frames are not
allowed to create the BaseVideo ready marker; after activation, an invalid
readback freezes the last valid frame instead of replacing it with black.

An explicit opt-in sink test is also available:

```sh
ALT111_SINK_TEST_GRID=1 ./start_vehicle.sh
```

This mode does not create the Window58 Screen observer and does not consume
Stream111 pixels. It creates displayable3, presents the existing diagnostic
grid, publishes BaseVideo ready, and lets the unchanged Java controller enter
Context80 only when the normal CarPlay base-active marker is present. Therefore
a visible grid proves the displayable3 -> GLES -> Context80 -> VC half
independently from Window58/readback.

The checked-in QNX ARMv7 Mirror ELF must contain
`SOURCE_PIXEL_VALID`, `SINK_TEST_GRID_PRESENT` and `GLES_PRESENT` before
this source revision is treated as a vehicle release. Until that ELF is rebuilt
with `BUILD-MIRROR-QNX.sh` and promoted with synchronized hashes, the branch is
source-complete but intentionally **not** ZIP-ready for the new diagnostics.

The DisplayManager A/B experiment (producer-only Window58 with
`screen_manage_window` skipped) remains deferred until the pixel-truth result
is known. This prevents another display-ownership change from being mixed with
the current transport fix.
