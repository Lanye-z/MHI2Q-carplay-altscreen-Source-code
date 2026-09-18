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
hook remains pinned to the known-good SHA-256
`07a96cad6121cfc9fae259d47e6c95142b5e09b7ef3e8cd7a180de009579cb39`.


Window58 identity is fail-closed: a QNX-generated numeric ID of 58 is never
accepted as the CarPlay source unless the owner-defined
`SCREEN_PROPERTY_ID_STRING` also reads exactly `"58"`.


## 2026-09-18 post-accept containment fix

Vehicle logs proved that type111 SETUP, dataPort advertisement and TCP accept succeeded,
then the worker stalled before `STREAM_111_NETSOCKET_CREATE_RETURN`. The accepted
dio_manager process had inherited this hook into `sh` / `pfctl` while removing the
temporary exact-port PF rule.

This branch therefore ports only the already-validated mainline containment:
- remove only `libcarplay_altscreen.so` from dio_manager's inherited `LD_PRELOAD`;
- reject non-CarPlay helper processes in the constructor before libc/GOT/runtime setup;
- `FORCE_START` remains an authorization marker and cannot override process identity.

Deliberately unchanged in this fix:
- Main110 / stock Window59 handling;
- type111 split/merge, listener, security and accept sequencing;
- the stock-equivalent post-accept PF close ordering;
- Window58 producer identity and readback sidecar;
- displayable3 GLES sink and Java-only Context80 ownership;
- global send/write/recv/close interception surface.

The next vehicle proof must first show:
`ACCEPT_RETURN -> FIREWALL_REMOVE result=OK -> NETSOCKET_CREATE_RETURN ->
START_CALL -> START_RETURN -> PROCESSFRAMES_BEGIN`.
Only after that sequence is proven should Window58/readback/Context80 be evaluated.
