# CarPlay private111 Direct Display V1

Branch: `carplay-private111-direct-display-v1`

Baseline: `test/carplay-basevideo3-context80-readback-v1` at `979b9cd573d9ebe4201979ebb286ed54c468d547`.

## Goal

Replace the Window58 readback display dependency with an explicit staged data path:

```text
iPhone private type111
  -> stock AirPlay decrypt/framing + ScreenStreamProcessData
  -> H264 TAP (/carplay111_h264)
  -> decoder
  -> decoded frame (/carplay111_decoded in V1 fallback)
  -> existing MMI ClusterVideoDisplay / GLES backend
  -> displayable3
  -> Java/HMI Context80 {98,101,102,3}
  -> VC
```

The display sidecar never calls `screen_read_window()` and never creates a
WindowManager observer for Window58.

## V1 decoder boundary

The repository does not yet contain a vehicle-proven standalone MHI2Q H.264
hardware decoder API. The Qualcomm/QNX hardware backend must not be invented
from the MH2P NvMedia implementation.

Therefore V1 carries both boundaries in one build:

1. **Independent compressed ingress:** the exact private stream is copied at
   the already-proven `ScreenStreamProcessData` interception point into
   `/carplay111_h264`. SPS/PPS/IDR and progress are logged independently of
   any Window58/readback result.
2. **Vehicle-testable decoded fallback:** for the exact private renderer only,
   the stock OMX decoded NV12 pointer is copied before stock
   `CScreenRender::render` forwards it. The sidecar consumes this NV12 SHM and
   sends it directly to displayable3. This fallback is explicitly identified
   as `decoder_backend=stock-omx-tap-v1`.

The stock renderer call remains fail-open in V1. That deliberately prioritizes
Main110/private111 session stability while the direct path is proven. Window58
may still be created internally by stock OMX during this compatibility stage,
but **the direct sidecar neither observes nor reads Window58 and Context80 does
not depend on it**.

After a standalone Qualcomm/QNX decoder backend is proven against
`/carplay111_h264`, the stock-render fallback can be removed without changing
the displayable3/Context80 half of the pipeline.

## Runtime phase markers

Hook / private stream:

```text
PHASE=STREAM_111_ACCEPT_RETURN
PHASE=VIDEO_111_FIRST_PAYLOAD
PHASE=H264_TAP_SHM_READY
PHASE=H264_TAP_FIRST_DATA
PHASE=H264_TAP_FIRST_SPS
PHASE=H264_TAP_FIRST_PPS
PHASE=H264_TAP_FIRST_IDR
PHASE=H264_TAP_PROGRESS
PHASE=FRAME_TAP_SHM_READY
PHASE=DECODER_FIRST_FRAME backend=stock-omx-tap
PHASE=DECODER_PROGRESS
```

Direct display sidecar:

```text
PHASE=GATE_PASS
PHASE=H264_SHM_ATTACHED
PHASE=H264_STREAM_VALID
PHASE=DECODED_SHM_ATTACHED
PHASE=DECODER_FIRST_FRAME
PHASE=NV12_CSC_READY
PHASE=DISPLAYABLE3_FIRST_PRESENT
PHASE=CONTEXT80_REQUEST
PHASE=DIRECT111_ACTIVE
PHASE=RUN
```

This means one vehicle run can distinguish:

- private111 transport failure;
- H.264 tap/framing failure;
- missing SPS/PPS/IDR;
- decoder/decoded-buffer failure;
- displayable3 presentation failure;
- Context80 ownership failure.

## Safety rules

- Main110 is never classified as the private H.264 tap source.
- No extra `recv()` consumes bytes from the private socket.
- The tap copies data only after stock AirPlay has already produced
  `ScreenStreamProcessData` payloads.
- A tap failure never changes the stock stream function result.
- The sidecar is isolated from the dio_manager `LD_PRELOAD`.
- The sidecar does not use Window58, `screen_manage_window()`, or
  `screen_read_window()`.
- Java/HMI remains the sole owner of terminal1 Context80.

## Release status

Source and diagnostics are kept separate from binary promotion.

Until the QNX 6.5 ARMv7 sidecar is rebuilt and promoted, the checked-in
`mirror_display/release/carplay-alt111-mirror-display` is an older binary and
must **not** be treated as this direct-display V1. The release
`BUILD_INFO.txt` intentionally says:

```text
release_binary_status=STALE_REBUILD_REQUIRED
vehicle_zip_status=NOT_READY_UNTIL_QNX_REBUILD_AND_PROMOTION
```

A successful universal hook CI build does not override that sidecar boundary.
