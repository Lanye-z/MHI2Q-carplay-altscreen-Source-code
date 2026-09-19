# CarPlay private111 Direct Display V2

Branch: `carplay-private111-direct-display-v2`

Baseline: `carplay-private111-direct-display-v1`, vehicle-tested 2026-09-19.

## Current status

V1 proved that private type111 can reach the Audi Virtual Cockpit through the
stock decoder, the MMI-derived GLES/displayable3 sink and Java-owned Context80.
Its picture moved with the phone map but was garbled.

The first V2 vehicle run then proved that QNX Screen can read the exact stock
private renderer window into a standard NV12 pixmap:

```text
source Screen format = 0x0001000c
visible              = 1440x542
readback format       = NV12 / 12
readback stride       = 1440
UV offset             = 780480 = 1440*542
linearizer failures   = 0 during the observed first session
```

That run did **not** prove the final pixels were correct on the VC because the
sidecar crashed before its first frame. Binary review located the SIGBUS in
`Private111DirectSource::map_frame()` while reading
`/carplay111_decoded` header memory. The same logs also exposed a separate
persistent-SHM reconnect bug: a restarted producer could reuse numeric
generation 1 and leave the old SHM inactive.

V2 source is therefore now hardened in three independent areas:

1. Screen linearization and publication accounting.
2. SHM lifetime / producer-session identity.
3. Sidecar crash recovery within the same still-active private session.

## Current pipeline

```text
CarPlay private type111 H264
  -> stock OMX
  -> stock CScreenRender post
  -> exact screen_window_t captured during real buffer creation
  -> screen_read_window()
       -> preferred standard NV12 pixmap
       -> RGBA8888 fallback -> BT.601 NV12
  -> safe linear NV12 publisher
  -> /carplay111_decoded
       writer identity = PID + generation + stream cookie
  -> sidecar fstat/ready/session checks
  -> CPU NV12 -> RGBA
  -> GLES / displayable3
  -> Java Context80
  -> VC
```

Main110 remains outside this auxiliary display route.

## V2 SHM contract hardening

The ABI structure size remains unchanged in this revision. The existing
`writer_pid` field is used as the ready publication marker:

```text
producer session reset:
writer_pid = 0
active = 0
memory barrier
reset generation/cookie/counters
memory barrier
active = 1
memory barrier
writer_pid = current PID    # published last
```

Every new private stream forces a reset even if a restarted process happens to
reuse the same numeric generation value.

The producer grows a named SHM only when it is smaller than the expected ABI
size; it does not intentionally shrink an object that a reader may still map.

The consumer now performs:

```text
shm_open
  -> fstat
  -> wait while st_size < expected
  -> mmap only after full size exists
  -> validate magic/version/writer_pid
  -> track writer_pid + generation + stream_cookie
  -> copy frame
  -> re-check writer/session/sequence/slot after copy
```

Startup-not-ready conditions are retryable, not fatal.

## Same-session sidecar recovery

The launcher now supervises the sidecar before **and** after first physical
present. An abnormal exit can be restarted a bounded number of times.

An abnormal restart sets `ALT111_RECOVER_CURRENT_SESSION=1`. The new sidecar
does not blindly replay an already-consumed `PHONE_REQUEST_111` line. It first
validates that both H264 and decoded SHM are active and have matching
writer/session identity. Only then does it bypass the consumed gate. If the
current session is not valid, it falls back to waiting for the next real phone
request.

## Final pre-car session hardening

The final static audit found three additional reconnect/race edges:

- `PHONE_REQUESTED_ALTSCREEN=YES` is process-level and may only be logged once.
  The sidecar gate now also accepts the repeated
  `PHASE=PHONE_REQUEST_111 STREAM_111_REQUESTED=YES` event, which is emitted
  for each observed type111 SETUP request. This prevents a normal second
  connection in the same `dio_manager` process from waiting forever.
- Initial display creation now requires two fresh decoded frames from one
  writer/generation/cookie identity. A single stale frame left in persistent
  SHM cannot trigger displayable3/Context80.
- Producer stream ownership is monotonic until explicit teardown. A late H264
  or render callback from another stream is dropped and cannot switch
  `g_stream` back to an old session. Late stale render callbacks are rejected
  before synchronous Screen readback.

The lifecycle watcher also counts only the exact current-session marker
`PHASE=DIRECT111_TAP_STOP stream=`; the diagnostic
`DIRECT111_TAP_STOP_STALE` marker cannot terminate the active sidecar.

## Pixel safety

The V1 raw vendor-pointer fallback has been removed.

If Screen readback cannot provide a safe frame:

- before the first valid auxiliary frame: drop the auxiliary frame and remain
  not-ready;
- after a valid frame has been published: freeze the last good auxiliary frame.

Stock CarPlay rendering still executes first and is not replaced.

## Observability

The V2 hook now distinguishes:

- Screen readback success;
- decoded SHM publish success;
- publish drops;
- consumer-copy success;
- final GLES presented-frame count.

Readback progress reports p50/p95/max latency. Optional explicit diagnostics:

```text
ALT111_LINEARIZER_SAMPLE_NV12=1
  -> /tmp/carplay111_linear_*.nv12

ALT111_CONSUMER_SAMPLE_NV12=1
  -> /tmp/carplay111_consumer_*.nv12
```

Each opt-in path writes at most three 1440x542 tight-NV12 samples. File I/O is
disabled by default.

## Important release state

The prior V2 ELF was rebuilt successfully, but the final pre-car static audit
found two additional sidecar-source hardening items:

- abnormal same-session recovery must observe **fresh decoded-frame progress**
  before bypassing a consumed phone gate, so stale `active=1` SHM cannot cause
  a false recovery;
- decoded SHM metadata must satisfy the packed-tight NV12 ABI before the GLES
  CSC can access it.

Because these change sidecar source after the previous QNX build, the repository
is intentionally **not** vehicle-ready until one more QNX 6.5 ARMv7 rebuild is
promoted.

```text
release_binary_status=V2_BINARY_STALE_HARDENING_REBUILD_REQUIRED
vehicle_zip_status=NOT_READY_QNX_SIDECAR_REBUILD_REQUIRED
```

The hook-side Screen linearizer remains independently buildable/promoted by CI.

## Required markers after the QNX sidecar rebuild

Producer/hook:

```text
PHASE=H264_TAP_SESSION_RESET
PHASE=FRAME_TAP_SESSION_RESET
PHASE=FRAME_LINEARIZER_FIRST_FRAME ... shm_publish_success=1
PHASE=FRAME_LINEARIZER_PROGRESS ... readbacks=... published=...
                                    readback_p50_ms=...
                                    readback_p95_ms=...
```

Consumer:

```text
PHASE=DECODED_SHM_WAIT_SIZE        # only if startup races the producer
PHASE=DECODED_SHM_ATTACHED
PHASE=SOURCE_SESSION
PHASE=DECODER_FIRST_FRAME
PHASE=DECODED_CONSUMER_PROGRESS
```

Recovery, only after an abnormal sidecar restart while the same private stream
is still active:

```text
PHASE=GATE_RECOVER_CURRENT_SESSION validated=1
```

Display:

```text
PHASE=DISPLAYABLE3_FIRST_PRESENT result=OK
CTX80_OBSERVED actual=80
PHASE=DIRECT111_ACTIVE
```

## Deliberately unchanged

This revision does not introduce an independent FFmpeg/NvMedia decoder,
`screen_blit`, a new displayable, a new Context, or a replacement type111
protocol implementation. Those are separate experiments after the current
stock-OMX + Screen-linearized path is verified with actual pixels.
