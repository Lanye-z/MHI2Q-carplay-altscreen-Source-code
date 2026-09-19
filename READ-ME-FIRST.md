# CarPlay private111 Direct Display V1 — first vehicle test

Branch: `carplay-private111-direct-display-v1`

This branch is intentionally frozen at the **prove-the-picture-first** stage.
Do not add `screen_blit`, zero-copy or a standalone Qualcomm decoder before the
first vehicle run.

## Actual V1 pipeline

```text
iPhone CarPlay private type111
  -> stock AirPlay control / framing
  -> ScreenStreamProcessData
  -> /carplay111_h264 (independent compressed-stream evidence)
  -> stock Qualcomm OMX decoder
  -> private CScreenRender decoded NV12
  -> /carplay111_decoded (3-slot decoded fallback)
  -> CPU BT.601 NV12 -> RGBA
  -> GLES / libdisplayinit
  -> displayable3 (1440x455)
  -> Java/HMI Context80 = {98,101,102,3}
  -> Virtual Cockpit
```

The sidecar does **not** call `screen_read_window()`, does not consume Window58
pixels, and does not write terminal/context state. Java/HMI is the sole Context80
owner. Main110 remains on the stock path.

The current iAP2 policy is deliberately `observe` with `ARMED_IAP2` absent.
Do not re-enable the retired ThemeAssets 21/17 mutation for this test. The
private type111 path is armed through the info/feature/create111 controls.

## Release identity

The checked-in QNX ARMv7 sidecar is the promoted direct-display V1 candidate:

```text
release_binary_status=PRIVATE111_DIRECT_DISPLAY_V1
vehicle_zip_status=READY_FOR_VEHICLE_TEST
window58_readback=disabled
mirror_sink=displayable3_gles
context=80_java_only
```

The universal hook is rebuilt/promoted by the branch CI. Source changes to the
sidecar itself require a real QNX 6.5 ARMv7 rebuild before they may be treated as
vehicle-ready.

## Recommended first-car sequence

1. If an older AltScreen/MMI-Cockpit-Carplay experiment is still installed,
   restore that package to stock first and perform a complete MMI reboot.
2. Use a clean ZIP of **this branch**. Keep this vehicle's own backup/log
   directories; do not import backups from another vehicle.
3. Keep the iPhone disconnected while installing.
4. Run **INSTALL**, confirm it reports PASS, then perform a complete MMI reboot.
5. Run **START**, confirm it reports PASS, then perform a second complete MMI
   reboot. This ensures the preload, Java80 controller and boot sidecar all start
   from the same armed state.
6. Connect the iPhone only after the second reboot. Open a navigation route that
   normally supplies the instrument-cluster second screen.
7. Leave the session connected while collecting **STATUS / logs**.

If the sidecar has already consumed a `PHONE_REQUEST_111` gate and is manually
restarted during the same phone session, reconnect CarPlay before judging the
retry. A new session produces a new gate token.

## Expected evidence order

The useful progression for one run is:

```text
PHASE=PHONE_REQUEST_111 ... PHONE_REQUESTED_ALTSCREEN=YES
PHASE=STREAM_111_ACCEPT_RETURN
PHASE=VIDEO_111_FIRST_PAYLOAD

PHASE=H264_TAP_SHM_READY
PHASE=H264_TAP_FIRST_DATA
PHASE=H264_AVCC_PROPERTY / PHASE=H264_AVCC_CONFIG
PHASE=H264_TAP_FIRST_IDR

PHASE=FRAME_TAP_SHM_READY
PHASE=FRAME_TAP_LAYOUT ... qnx_nv12_128x32
PHASE=DECODER_FIRST_FRAME backend=stock-omx-tap

direct111: PHASE=GATE_PASS
direct111: PHASE=DECODED_SHM_ATTACHED
direct111: PHASE=DECODER_FIRST_FRAME
renderer: PHASE=NV12_CSC_READY backend=cpu-bt601
direct111: PHASE=DISPLAYABLE3_FIRST_PRESENT result=OK
CTX80_OBSERVED actual=80
direct111: PHASE=DIRECT111_ACTIVE
```

STATUS should then converge to:

```text
PHYSICAL_ROUTE_READY=SOFTWARE_CHAIN_COMPLETE
```

That line means the observable software chain is complete. The final success
criterion is still **a visible CarPlay second-screen image on the VC**.

## First-run interpretation

If H264 evidence is present but there is no decoded frame, stay on the
stock-OMX/tap boundary. If decoded NV12 exists but displayable3 fails, stay on
the sidecar/GLES boundary. If displayable3 first-present succeeds but Context80
is not observed, stay on Java/HMI ownership. Do not change multiple layers at
once.

The current sidecar intentionally keeps the proven CPU NV12-to-RGBA path for
this first run. Hardware CSC / `screen_blit`, direct NV12 composition and
standalone Qualcomm decoding are follow-up optimizations after physical
visibility is confirmed.
