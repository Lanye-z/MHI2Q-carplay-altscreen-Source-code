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
