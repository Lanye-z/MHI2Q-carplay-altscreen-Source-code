# CarPlay private111 Direct Display V2 — READ FIRST

Branch: `carplay-private111-direct-display-v2`

## Vehicle use is approved — V2 QNX sidecar rebuilt and promoted

The V2 QNX 6.5 ARMv7 sidecar has been rebuilt from the V2 source and promoted
into the release directory. The release ELF now carries the V2 SHM size guards,
session identity and same-session recovery logic.

Current expected metadata:

```text
release_binary_status=PRIVATE111_DIRECT_DISPLAY_V2
vehicle_zip_status=READY_FOR_VEHICLE_TEST
```

## What is fixed in V2 source

### 1. Decoded SHM SIGBUS hardening

Both consumer map functions now:

```text
shm_open
 -> fstat
 -> require st_size >= sizeof(expected SHM ABI)
 -> mmap
 -> validate magic/version/writer_pid
 -> retry if not ready
```

The V2 crash location was in `map_frame()` at the
`/carplay111_decoded` magic read, so decoded SHM is explicitly covered.

### 2. Producer reconnect/session reset

A new private stream always resets the named SHM publication state, even if a
new producer process again starts with numeric generation 1.

Session identity is no longer treated as generation alone:

```text
writer_pid + generation + stream_cookie
```

`writer_pid=0` is used during header transition and is published last after
the new session header is ready.

### 3. Same-session sidecar recovery

The launcher monitors abnormal sidecar exit before and after first present,
with a bounded restart count.

On an abnormal restart the sidecar may bypass an already-consumed phone gate
**only after** validating an active, matching H264+decoded SHM session.
Otherwise it waits for the next genuine `PHONE_REQUEST_111`.

### 4. Raw vendor fallback removed

A Screen readback failure never sends the original vendor OMX CPU pointer into
`/carplay111_decoded`.

Before first success it drops the auxiliary frame; after success it freezes the
last good frame.

### 5. Pixel and timing evidence

The hook now logs separate readback and SHM-publish counts plus readback
p50/p95/max latency.

Optional diagnostic samples are off by default:

```text
ALT111_LINEARIZER_SAMPLE_NV12=1
ALT111_CONSUMER_SAMPLE_NV12=1
```

Each writes at most three tight-NV12 frames under `/tmp`.

## Architecture retained

```text
type111
 -> stock OMX
 -> stock renderer
 -> Screen linearizer
 -> /carplay111_decoded
 -> sidecar
 -> GLES / displayable3
 -> Java Context80
 -> VC
```

The MMI-proven displayable3/Java Context80 exit remains unchanged. The sidecar
does not enumerate Window58 and does not call `screen_read_window`; readback
remains in the private renderer hook.

## Build after these source changes

On a machine with the QNX 6.5 ARMv7 SDK:

```sh
./BUILD-MIRROR-QNX.sh
```

Then promote the resulting
`Toolbox/carplay_alt_screen/mirror_display/build/carplay-alt111-mirror-display`
to the release directory, change release status to
`PRIVATE111_DIRECT_DISPLAY_V2`, refresh both SHA256 manifests, and rerun
`VERIFY-NATIVE-DIRECT-RELEASE.sh`.

Do not change the release status to vehicle-ready unless the rebuilt ELF
contains the V2 markers checked by `build_qnx.sh`.
