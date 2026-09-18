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
