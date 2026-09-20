# CarPlay private111 Direct Display V1 — HISTORICAL BRANCH

Branch: `carplay-private111-direct-display-v1`

## Status

This branch is retained for historical reference only.

V1 helped establish the private111 transport, H.264/stock-OMX boundary,
displayable3/GLES sink, and Java-owned Context80 architecture, but it did **not**
produce the confirmed usable physical VC first-light later achieved by the
modified V2 branch.

Do not use V1 as the starting point for new vehicle tests.

## Historical V1 route

```text
CarPlay private type111
  -> stock AirPlay framing / ScreenStreamProcessData
  -> /carplay111_h264
  -> stock Qualcomm OMX
  -> decoded NV12 tap
  -> /carplay111_decoded
  -> CPU NV12 -> RGBA
  -> GLES / displayable3
  -> Java/HMI Context80
  -> Virtual Cockpit
```

The important value of this branch is diagnostic history and comparison with
the later V2 Screen-linearized path.

## Branch guidance

- Current development branch: `main`
- Known-good vehicle first-light backup:
  `carplay-private111-direct-display-v2`
- This V1 branch: archive / regression reference only

The old `READY_FOR_VEHICLE_TEST` wording in V1-era release notes should be
read as historical pre-test state, not as the current recommended package.
