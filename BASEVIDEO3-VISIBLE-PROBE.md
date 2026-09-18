# CarPlay BaseVideo3 Native Visible-Probe

Branch: `test/carplay-basevideo3-native-v1-visible-probe`

## Purpose

This branch tests one narrow hypothesis after the K1004 Main110 reverse:

```text
private111
  -> stock ScreenStream / H.264
  -> stock Qualcomm AVC OMX
  -> stock CScreenRender
  -> private config identity 59 -> 3
  -> stock-created Screen window
  -> screen_manage_window(...)
  -> PRIVATE-ONLY VISIBLE=1
  -> stock decoder-owned buffers
  -> stock screen_post_window
  -> /tmp/mmi-mirror-basevideo.ready
  -> existing Java ctx80
  -> VC
```

It does **not** pre-create a `libdisplayinit display_create_window(...,3)` window and
does not transfer external buffer ownership into `CScreenRender`.

## Why this experiment exists

Static reverse shows that Main110 does not use `libdisplayinit!display_create_window`.
It creates its own `CScreenRender` window and converts
`st_screen_config.window_id=59` into `ID_STRING="59"`.

The previous native 58 experiment proved that the private111 stock decoder/render
pipeline can post real frames, but physical Cluster visibility was not proven.
The remaining producer-side difference worth isolating is visibility/lifecycle.

This branch therefore keeps the BaseVideo3 V1 ownership model and changes only one
producer property beyond the identity rewrite:

```text
after screen_manage_window(private111_window)
before stock screen_create_window_buffers(...)

SCREEN_PROPERTY_VISIBLE = 1
```

Main110 never enters this private config scope.

## Context ownership

Native is pixels-only.

- displayable identity: `3`
- Java composition: `ctx80={98,101,102,3}`
- context writer: Java/HMI only
- native dmdt: disabled
- `spawnl` route backend: deliberately left NULL
- old native route predicate: hard returns false

The V2.5 Java/ctx80 control plane is an external prerequisite for vehicle testing.

## Mirror policy

The old diagnostic bridge is not part of this test:

```text
Window58 -> screen_read_window -> BGRA -> GLES -> displayable3
```

START removes stale Mirror enable/autostart state before arming the experiment.

## Runtime probes

For the exact private window, the hook logs:

- `pre_manage`
- `post_manage`
- `post_force_visible`
- `post_buffers`

Each probe records:

```text
QNX numeric ID
VISIBLE
FORMAT
USAGE
SIZE
BUFFER_SIZE
return codes
```

Additional truth markers:

```text
[MAIN110] ... window_id=59 rewrite=0 ownership=stock
[ALT111]  ... displayable=3 ...
PHASE=BASEVIDEO3_FORCE_VISIBLE ... rc=0
[BASEVIDEO3] PHASE=BASEVIDEO3_READY ... ready=1 ...
```

`/tmp/mmi-mirror-basevideo.ready` is written only after the first successful stock
`CScreenRender::render -> screen_post_window` of the private stream and removed on
matching detach.

## Vehicle interpretation

The decisive sequence is:

```text
Main110 healthy
-> private111 config rewrite to 3
-> manage_rc=0
-> force-visible rc=0
-> buffers_rc=0
-> first stock post succeeds
-> BASEVIDEO3 ready
-> Java enters ctx80
-> human-visible VC image
```

Only the final observation is physical visibility.

If every software stage passes but VC remains black, compare this stock
CScreenRender-backed producer against the already-working MMI displayable3 producer,
especially window creation context, FORMAT/USAGE, buffer type/count and manager
lifecycle. Do not return to Window58 readback as the default production path.

## Safety / isolation

- Main110 remains stock `window_id=59`.
- Only the exact private renderer/thread/generation can rewrite to 3.
- No external `display_create_window(...,3)` ownership handoff is attempted.
- No readback/BGRA/GLES path is started.
- No native context restore/write is performed.
