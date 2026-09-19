# CarPlay private111 Direct Display V2

Branch: `carplay-private111-direct-display-v2`

Baseline: `carplay-private111-direct-display-v1` vehicle-tested on 2026-09-19.

## Why V2 exists

V1 proved the complete physical route:

```text
CarPlay private type111
  -> H264 + SPS/PPS/IDR
  -> stock OMX decoder
  -> decoded frame bridge
  -> GLES
  -> displayable3
  -> Java/HMI Context80
  -> Audi Virtual Cockpit
```

The VC displayed a continuously moving image synchronized with the phone map,
but the picture was tiled/garbled.

Vehicle evidence for the decoded stock buffer was:

```text
visible=1440x542
Screen format=65548 (0x0001000c)
source stride=1536
UV offset=0x000cc000
stock OMX output buffers=15
```

V1 correctly measured the padded stride/plane offset but then treated the raw
CPU pointer as ordinary row-linear NV12. That assumption is removed in V2.

## V2 scope

V2 deliberately keeps all layers already proven by the vehicle test:

- private111 SETUP / accept / H264 transport;
- stock AirPlay framing and stock OMX decoder;
- Main110 behavior;
- the existing `/carplay111_decoded` SHM ABI;
- the existing QNX ARMv7 display sidecar;
- CPU BT.601 NV12 -> RGBA in the sidecar;
- displayable3;
- Java/HMI as the sole Context80 owner.

Only the **vendor decoded-buffer -> linear NV12** boundary changes.

## V2 pixel path

```text
type111 H264
  -> stock OMX
  -> vendor Screen buffer 0x0001000c
  -> stock CScreenRender::render()
  -> stock screen_post_window()
  -> exact stock screen_window_t captured during screen_create_window_buffers()
  -> screen_read_window()
       -> preferred: standard Screen NV12 pixmap (format 12)
       -> fallback: RGBA8888 pixmap -> CPU BT.601 -> NV12
  -> padded scratch NV12
  -> existing 3-slot /carplay111_decoded publisher
  -> existing sidecar
  -> GLES / displayable3
  -> Context80
  -> VC
```

Screen, rather than V2, owns the vendor-layout conversion. No hand-written
target MHI2Q platform tile-address formula is guessed.

## Automatic fallback order

One build exercises all useful cases:

1. Request an off-screen Screen pixmap with standard `SCREEN_FORMAT_NV12=12`.
2. Require an authoritative buffer format and `SCREEN_PROPERTY_PLANAR_OFFSETS`.
3. Call `screen_read_window()` against the exact stock private renderer window.
4. If NV12 pixmap creation/readback is unsupported, recreate the target as
   `SCREEN_FORMAT_RGBA8888=8`.
5. Convert the CPU-visible MHI2Q BGRA byte order to limited-range BT.601 NV12.
6. A successful Screen readback is accepted even for a uniform/black frame.
   Pixel-detail probing is diagnostic only.
7. Before the first successful linearized frame, a genuine Screen failure may
   use the V1 raw-pointer tap as a diagnostic fail-open path. After one good
   linearized frame, transient failures freeze the last good frame instead of
   reintroducing tiled garbage.

The source is normally ~60 fps while the cockpit sink targets ~30 fps, so the
blocking Screen readback is performed on every other stock render callback.

## Expected V2 evidence

A successful linearization should add these markers before the existing
display markers:

```text
PHASE=FRAME_NATIVE_WINDOW_METADATA
PHASE=FRAME_LINEARIZER_API ... result=READY
PHASE=FRAME_LINEARIZER_PIXMAP backend=screen-nv12 ... result=READY
# or:
PHASE=FRAME_LINEARIZER_FALLBACK ... to=screen-rgba
PHASE=FRAME_LINEARIZER_PIXMAP backend=screen-rgba ... result=READY

PHASE=FRAME_LINEARIZER_FIRST_FRAME
PHASE=DECODER_FIRST_FRAME backend=stock-omx-tap
renderer: PHASE=NV12_CSC_READY
PHASE=DISPLAYABLE3_FIRST_PRESENT
CTX80_OBSERVED actual=80
PHASE=DIRECT111_ACTIVE
```

If the log contains:

```text
PHASE=FRAME_LINEARIZER_RAW_FALLBACK
```

and the VC still shows the V1-style moving garble, the transport/route remains
healthy but Screen readback did not linearize the stock window on that run.

## Safety contract

- The stock renderer is called first and remains fail-open.
- No extra socket receive consumes private111 bytes.
- Main110 is not routed through the V2 frame linearizer.
- The sidecar still does not observe Window58 through a WindowManager census.
- The hook uses only the exact `screen_window_t` captured from the private renderer's real Screen buffer-creation call.
- Context80 remains Java/HMI-owned.
- No `screen_blit`, standalone FFmpeg decoder, zero-copy experiment, or
  displayable/context redesign is mixed into V2.

## Performance note

The preferred NV12 screenshot path avoids a colorspace round-trip. The RGBA
fallback intentionally favors correctness over efficiency and performs
RGBA/BGRA -> NV12 in the hook, followed by the already-proven NV12 -> RGBA
sidecar path. Once the picture is correct, this round-trip can be removed in a
separate optimization branch.
