# CarPlay private111 Direct Display — READ FIRST

Branch: `main`

## Status

`main` was fast-forwarded from the vehicle-tested V2 line at commit
`23b3d242248716c49d10812abb121f185e58b676` on 2026-09-20.

The modified V2 route has now achieved **confirmed physical Virtual Cockpit
first-light**. The CarPlay private second-screen image was visible on the VC and
followed the phone navigation image.

Use `main` for all further development. The branch
`carplay-private111-direct-display-v2` is retained as the known-good backup
baseline. V1 is historical only.

## Current proven route

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

Main110 remains outside this auxiliary display route.

## Vehicle-test observations

The successful V2 run changes the project status from "software-chain only" to
"physically proven on the vehicle".

The current follow-up items are deliberately narrow:

1. **Frame pacing / performance**
   - Keep the working stock-OMX + Screen-linearizer route.
   - The next optimization is to deliberately process every other decoded frame
     ("skip one, read one") so Screen read/publish work is not attempted for
     every rendered frame.
   - Do not introduce a standalone decoder, `screen_blit`, or another display
     architecture unless later evidence requires it.

2. **Disconnect / stock-navigation cleanup**
   - During one first-session disconnect, CarPlay returned to the stock map.
   - No stock navigation route was active, but a navigation arrow
     appeared/remained unexpectedly.
   - Treat this as a lifecycle/state-cleanup issue around teardown and stock
     navigation hand-back. It does not invalidate the proven private111 display
     path.

No other mandatory architecture change is currently established by the
successful vehicle test.

## Release identity

The promoted V2 release metadata is the current baseline:

```text
release_binary_status=PRIVATE111_DIRECT_DISPLAY_V2
vehicle_zip_status=READY_FOR_VEHICLE_TEST
v2_pending_hardening=none
```

The older wording that the sidecar still required another QNX rebuild is no
longer current for this promoted build.

## Development rule

Make future functional changes on `main` first. Keep changes small and
observable so a regression can be compared directly against the V2 backup
branch.
