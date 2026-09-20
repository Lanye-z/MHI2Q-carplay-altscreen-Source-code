# CarPlay private111 Direct Display V2 — BACKUP BASELINE

Branch: `carplay-private111-direct-display-v2`

## Status

This branch is retained as the **known-good vehicle-tested V2 backup**.

The modified V2 route achieved confirmed physical Virtual Cockpit first-light:
the CarPlay private second-screen image was visible on the VC and followed the
phone navigation image.

Future functional fixes should be developed on `main`. This branch should be
used for recovery, regression comparison, and reference. Documentation-only
updates are acceptable; the working source/binary path should otherwise remain
frozen.

## Proven route

```text
CarPlay private type111
  -> stock OMX
  -> stock private renderer
  -> Screen linearization
  -> /carplay111_decoded
  -> sidecar
  -> CPU NV12 -> RGBA / GLES
  -> displayable3
  -> Java/HMI Context80
  -> Virtual Cockpit
```

Main110 remains outside the auxiliary route.

## Vehicle-test observations

- Physical VC output is confirmed on this V2 architecture.
- The preferred performance refinement is to deliberately process every other
  decoded frame ("skip one, read one") rather than changing the decoder or
  display architecture.
- One disconnect test showed a stock-navigation lifecycle anomaly: after
  CarPlay disconnected and the stock map returned with no active stock route,
  a navigation arrow appeared/remained unexpectedly. This still needs teardown
  / navigation-state cleanup analysis.
- No other mandatory architecture change has been established by the successful
  run.

## Release identity

```text
release_binary_status=PRIVATE111_DIRECT_DISPLAY_V2
vehicle_zip_status=READY_FOR_VEHICLE_TEST
v2_pending_hardening=none
```

The earlier pre-test note that another QNX sidecar rebuild was required is
obsolete for the promoted V2 baseline.

## Backup policy

Do not use this branch as the normal development head. Apply new fixes to
`main`, test there, and compare behavior against this branch when needed.
