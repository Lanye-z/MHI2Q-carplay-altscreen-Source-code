# CarPlay private111 Direct Display V2 — vehicle test

Branch: `carplay-private111-direct-display-v2`

V1 has now answered the large architectural question: the CarPlay private
type111 stream can reach the Audi Virtual Cockpit through stock OMX,
displayable3 and Java-owned Context80. The V1 vehicle showed a continuously
moving but garbled map, so V2 changes **only the decoded pixel-layout boundary**.

## Actual V2 pipeline

```text
iPhone CarPlay private type111
  -> stock AirPlay control / framing
  -> ScreenStreamProcessData
  -> /carplay111_h264
  -> stock Qualcomm/i.MX6 OMX decoder
  -> vendor Screen format 0x0001000c
  -> stock CScreenRender post
  -> exact stock screen_window_t
  -> QNX screen_read_window linearizer
       -> standard NV12 pixmap when supported
       -> otherwise RGBA8888 -> CPU BT.601 -> NV12
  -> /carplay111_decoded (unchanged V1 ABI)
  -> existing V1 QNX sidecar
  -> CPU BT.601 NV12 -> RGBA
  -> GLES / libdisplayinit
  -> displayable3
  -> Java/HMI Context80 = {98,101,102,3}
  -> Virtual Cockpit
```

The sidecar itself still does not enumerate/read Window58. V2 obtains the exact
stock private renderer window inside the hook after the stock render call; this
avoids the old WindowManager identity/visibility guessing path.

Main110 remains stock. Java/HMI remains the sole Context80 owner.

## What changed from V1

V1 used the correct measured metadata:

```text
1440x542
Screen format 65548 / 0x0001000c
stride 1536
UV offset 0xCC000
```

but copied rows directly from the vendor pointer as if it were ordinary linear
NV12. The moving garble proved that the pointer contains live decoded data but
not in the assumed row-linear memory layout.

V2 no longer implements a guessed i.MX6 detile formula. QNX Screen performs the
vendor-layout conversion by screenshotting the exact stock window into a normal
off-screen pixmap.

## Expected V2 evidence

The new markers to watch are:

```text
PHASE=FRAME_NATIVE_WINDOW_METADATA
PHASE=FRAME_LINEARIZER_API ... result=READY
PHASE=FRAME_LINEARIZER_PIXMAP backend=screen-nv12 ... result=READY
# OR automatic fallback:
PHASE=FRAME_LINEARIZER_FALLBACK ... to=screen-rgba
PHASE=FRAME_LINEARIZER_PIXMAP backend=screen-rgba ... result=READY

PHASE=FRAME_LINEARIZER_FIRST_FRAME
PHASE=DECODER_FIRST_FRAME backend=stock-omx-tap
renderer: PHASE=NV12_CSC_READY
PHASE=DISPLAYABLE3_FIRST_PRESENT
CTX80_OBSERVED actual=80
PHASE=DIRECT111_ACTIVE
```

If `PHASE=FRAME_LINEARIZER_RAW_FALLBACK` appears before the first successful
linearized frame, Screen linearization was unavailable and V2 preserved the V1
raw-pointer path as diagnostic fail-open evidence. After
`PHASE=FRAME_LINEARIZER_FIRST_FRAME`, later transient read failures use
`FREEZE_LAST_GOOD` semantics instead of feeding tiled raw pixels again.
Uniform/black frames are accepted as valid screenshots.

## Vehicle-test procedure

Use the same clean install/start sequence as V1:

1. Keep the iPhone disconnected during install.
2. Install the branch package and complete a real MMI reboot.
3. Run START and complete the requested second real MMI reboot.
4. Connect the iPhone, open a CarPlay navigation route, and leave the session
   connected long enough to collect STATUS/logs.
5. Record whether the VC is correct, black, frozen, or still moving/garbled.
6. Save the full log bundle before restoring or changing branches.

## Deliberately not mixed into V2

Do not add these until the pixel result is known:

- FFmpeg stream-player;
- standalone H.264 decoder;
- `screen_blit`;
- zero-copy/native-image import;
- a new displayable;
- a new Context;
- a different CarPlay type111 state machine.

The checked-in display sidecar is intentionally the V1-proven binary. V2 CI
rebuilds/promotes the universal hook that contains the new Screen linearizer.
