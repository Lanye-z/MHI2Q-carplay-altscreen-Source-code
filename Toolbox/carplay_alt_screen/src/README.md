# MMI-Cockpit-Carplay AltScreen - private111 native cockpit source

The direct overlay is exact to `MHI2Q_CN_AUG22_K1004`: INSTALL restores and
verifies firmware-original JSON and `/eso/lib/libairplay.so`, while START checks
the published proxy/renamed-stock pair and loader smoke before mutation. FORCE
START is diagnostic only: it may bypass runtime process-name and transaction
run-id authorization, but never overlay identity, stock forwarding, the 16-slot
internal GOT redirect, required symbols, backend, geometry, or restore gates.
P1404 names remain where the original reverse-engineering baseline is shared;
the deployed addresses and bytes are proved against K1004.

Current release goal: preserve stock CarPlay MainScreen `110`, advertise an independent display `111`, complete the private type-111 SETUP/accept/start/bind path, and render that private stream through stock OMX/CScreenRender to displayable 58/context 76. Bounded H264/NAL/post evidence remains diagnostic only.

There is one K1004 overlay START contract, locked by `Toolbox/carplay_alt_screen/K1004_OVERLAY_READY`. It binds the private stream's stock OMX/CScreenRender directly to a DisplayManager-managed displayable 58 window and deliberately does not produce BGRA or copy Main110/MMI pixels. Context 76 activation requires matching dynamic display-1 geometry plus an accepted Alt-UUID `showUI`; teardown and failure restore context 74. Human-visible content remains an in-vehicle verdict, and `FULL_CHAIN_READY` is never produced offline.

## Native private111 chain

```text
wired iPhone
  -> iAP2 USBHost ThemeAssets param16/sub5
  -> phone CarPlayAvailability 0x4300
  -> AirPlay /info feature bit26 + independent display type111
  -> phone SETUP / streams request
  -> exact 111 descriptor captured
  -> preserve stock 110/audio behavior
  -> accept enabledFeatures altScreen + viewAreas
  -> private second ScreenSession / ScreenStream (side table; Main110 untouched)
  -> valid private 111 setup response merged into final SETUP response
  -> private 111 connection accepted, StartSession completes, real stream binds
  -> private CScreenRender window bypasses the stock static window group
  -> DisplayManager manages that native displayable 58 window before buffers
  -> stock ProcessFrames owns transport and stock OMX owns NV12 buffers/posts
  -> Alt-UUID showUI(Maps cluster URL) then Alt-UUID forceKeyFrame
  -> compressed H264 ingress and SPS/PPS/IDR observations
  -> bounded failure, Alt-targeted stopUI, teardown, reconnect and stock restore evidence
```

Display evidence policy:

```text
private native config        -> required, dynamic display-1 geometry
decoded stock OMX posts      -> diagnostic log only
decoded BGRA producer        -> not used by the direct-surface design
cockpit context visibility   -> displayable58/context76, vehicle confirmation required
```

## Logging contract

Every hook event uses an ordered prefix:

```text
[ALTSCREEN] seq=<n> epoch_us=<wall-clock-us> pid=<pid> tid=<thread> run_id=<session> ...
```

Important transitions use fixed `PHASE=` markers. Control-plane dictionaries are recorded generically when the P1404 CF enumeration API is available; otherwise the code falls back to a large known-key probe. Dictionary/array recursion is bounded and CFData is capped at 64 bytes. Video hot paths never hex-dump every packet.

The native writer keeps its bounded asynchronous plaintext log directly at
`/tmp/altscreen_hook.log`; no nested `/tmp` directory is required. A separate observer appends new bytes to SD
append, so the CarPlay control/video threads never perform encryption or SD I/O.
Persistent diagnostic artifacts are:

```text
boots/boot_<id>/*.aslg
boots/boot_<id>/streams/*.aslg
operations/operation_*.log.aslg
<run_id>/collection_report.txt.aslg
```

Each ASLG/v1 record is encrypted with ChaCha20-IETF and authenticated by
HMAC-SHA256. Runtime markers under `current/` stay plaintext because the shell
and native hook must parse them; they are state rather than diagnostic logs.
See `docs/altscreen/28-encrypted-runtime-logs-20260915.md` for the format,
local-only key/decryptor and exact boundary.

The START-side `slog2info -W` is explicitly best-effort and pre-reboot only. Because the mandatory MMI reboot kills it, COLLECT takes a fresh non-blocking QNX slog ring snapshot after the iPhone run.

## iAP2 / ThemeAssets

Process default remains fail-closed `observe`, but an armed RX or FULL transaction explicitly selects:

```text
WirelessCarPlay transport component parameter 21 (compatible existing parent 20)
TransportSupportsThemeAssets void subparameter 17
profile = theme_21_17
```

The old `usbhost_16_5` interpretation is rejected: LIVI/CatPlay identify subparameter 5 as legacy transport iAP2 support, not ThemeAssets. The mutator requires stock transport sub0/sub1 identity. If parent 21 is absent, it may clone only that identity from a verified stock transport parent and append sub17; otherwise it fails unchanged. Incoming `0x4300 CarPlayAvailability` remains raw-logged and parsed as `YES / NO / UNKNOWN / MALFORMED`. The K1004 Nme overlay accepts only exact fingerprinted `NmeFile::CreatePosix/Write/Read/Delete` callers and an FD opened for `/dev/otg-cinemo`; every mismatch uses stock I/O unchanged.

## `/info` type111 declaration

The second display follows the structure used by working dual-screen CarPlay implementations:

```text
type = 111
features = 0x0A              # LIVI: knobs + high-fidelity touch capability
primaryInputDevice = 3
viewAreas = [ view ]
view.safeArea = safe
initialViewArea = 0
maxFPS = 60
widthPhysical = 200          # fallback when the panel size is unknown
heightPhysical = round(200 * heightPixels / widthPixels)
Alt UUID = b7e6c5a0-2222-4000-8000-000000000002
```

The stock Main110 display entry remains first and untouched; the private Alt UUID is fixed across geometry changes.

Main display element0 is never replaced.

## SETUP control plane

`p1404_airplay.c` currently provides the one-shot observation/mutation framework:

- records `setup-request`, `setup-response-stock`, `setup-response-final`;
- finds the **actual dictionary** carrying `type == 111` in the top-level `streams[]`, matching LIVI and the captured AUG22 iPhone request;
- dispatches by numeric `type` only; the descriptor UUID is carried through unchanged and is not an extra acceptance gate;
- logs `PHASE=SETUP_111_DESCRIPTOR ... descriptor=<ptr>`;
- records ports, connection id, VideoConfig and generic unknown fields where possible;
- preserves stock enabledFeatures and adds unique `altScreen` + `viewAreas`;
- records stock return code and final negotiated proof.

The P1404 private backend removes type111 from the request passed to the stock dispatcher, preserving stock 110 behavior, creates a private listener/session, and merges the private `dataPort` response only after the stock call succeeds. Policy-blocked requests allocate no pending generation. Every permitted preparation is finished after the stock call, including stock errors and null responses, so a retry cannot inherit stale transaction state.

## Private 111 ownership framework

`altscreen_state.c` owns a side table keyed by stock `AirPlayReceiverSession *`:

```text
stock receiver -> stock screenSession -> Main110       # never overwrite
alt_state[receiver] -> private screenSession -> 111    # our path
```

The important APIs are:

```c
alt_state_register(receiver_session);
alt_state_bind_private(receiver_session, alt_screen_session, alt_screen_stream);
alt_state_lookup_stream(stream);
alt_state_feed_private_video(stream, data, len);
alt_state_mark_video_config(ctx, proof);
alt_state_mark_ui_active(ctx, proof);
alt_state_mark_decoder_ready(ctx, proof);
alt_state_mark_cockpit_visible(ctx, proof);
```

A real private ScreenSession and ScreenStream bind establishes ownership, but **G5B is not committed at bind time**. `alt_state_mark_private_processing()` commits G5B only after accept, StartSession, real stream bind, and immediately before the private worker enters the proven stock `AirPlayReceiverSessionScreen_ProcessFrames` transport loop. Descriptor capture, listener creation, or bind alone are insufficient.

Once processing ownership is committed, the existing 9-argument `ScreenStreamProcessData` assembly trampoline distinguishes the private stream from stock streams. Private compressed-video accounting records first payload, first SPS/PPS/IDR and cumulative bytes/packets, with logging throttled after the first packet. This is ingress/classification evidence only, not decoded-output evidence.

## Native private-111 output candidate

The final path no longer depends on the BGRA provider or a second renderer process. The private worker thread pre-claims `StartSession`. For only that thread, interposed `ScreenCopyMain` returns a fresh runtime Alt display dictionary without mutating stock Main110. Interposed `ScreenStreamStart` stages the exact private stream, and its first synchronous `CScreenRender::config` binds the newly initialized renderer before forwarding the rewritten config. A missing, cross-thread, or mismatched handoff fails closed, so type111 cannot fall through to displayable 59. `p1404_cockpit_native.c` rewrites only that renderer's exact 44-byte config:

```text
advertised size = runtime SCREEN_PROPERTY_SIZE of display id 1
window/source  = negotiated type-111 decoder size, identical (no scaling)
route-ready    = source must equal runtime advertised display-1 pixel size
origin         = 0,0
window id      = displayable 58
window owner   = DisplayManager handshake before stock buffer creation
stock OMX      = retains NV12 buffer allocation, posting and teardown
Main110        = untouched on the stock static-group path
```

After private binding, the control monitor submits `showUI` with the exact Alt UUID and `maps:/car/instrumentcluster/map`; only a status-0 response can mark G4. It then submits Alt-targeted `forceKeyFrame`, retries explicit submission/response failures, and fails closed on a callback timeout. Teardown submits Alt-targeted `stopUI` rather than a global command.

Incoming `suggestUI` follows pinned LIVI semantics. The command still reaches stock dio first. If and only if the armed AltScreen path receives stock `kNotHandledErr` (`-6714`), the wrapper acknowledges it as a no-op so AirPlay returns success instead of HTTP 422. A stock success, any other stock error, every other command, and the disarmed path retain stock behavior. The phone-provided URL list is not displayed or interpreted.


This is not yet a vehicle verdict. The user judges success from actual cluster output; logs preserve the path and lifecycle without separately deciding whether video payload/NAL/post evidence is usable.

## Permanent Gate model

| Gate | Required proof |
|---|---|
| G1A | HU actually sends ThemeAssets declaration |
| G1B | iPhone availability reply for ThemeAssets |
| G2 | final `/info` contains independent display111 |
| G3A | iPhone asks for AltScreen |
| G3B | final SETUP response proves AltScreen negotiated |
| G4 | actual AltScreen UI/focus/activation proof |
| G5A | iPhone SETUP contains stream111 request |
| G5B | accept + StartSession + real private bind + ProcessFrames ownership |
| G6A | successful native private111 CScreenRender config matching display-1 geometry |
| G8 | successful displayable58/context76 activation after G6A and accepted G4 |

`Toolbox/scripts/altscreen_gates.sh` is runtime truth for display/control reachability. Payload, SPS/PPS/IDR and decoded-post values remain in raw diagnostics but are not ordered gates or activation conditions. G6A/G8 are source-integrated and require in-vehicle confirmation. Marker helper functions alone do not change Gate status.

## Owner-authorized compatibility bypass and retained runtime prerequisites

Stored P1404/K1004 files and static proofs remain regression/development evidence
only. They are not vehicle eligibility gates and their CRC/layout/profile values
are not selected at START or runtime. See
`Research/AltScreen/AUG22_COMPATIBILITY_MATRIX.md`.

Before any `/mnt/system` or `/mnt/app` mutation, START runs the exact SD hook in a
short-lived target process. This proves only that the target loader can resolve
its NEEDED libraries/relocations and that the constructor returns without
crashing in that minimal process. The loaded dio_manager hook must still bind
all six available stock exports, match the app probe-marker run id to the SD
transaction run id, and resolve every required libairplay/prerequisite function
by name. Missing requirements keep AltScreen inert and preserve stock fail-open;
a same-name function with an incompatible ABI may still crash dio_manager.
Never call a measured offset through a guessed C prototype.

## Host tests

`tests/run_host_tests.sh` includes:

```text
unit_iap2
unit_profile
unit_state
unit_stock_failopen
unit_runtime_identity
unit_start_premutation
unit_markers
unit_install_contract
unit_save_restore_flow
fixture_transaction
```

`unit_state` pins private ownership semantics: registration or bind alone cannot claim G5B, unrelated ScreenStream pointers cannot count as 111, ProcessFrames ownership is required, SPS/PPS/IDR are classified only on the private stream, and teardown clears context/census state.

The host suite also covers stock errors/null responses consuming pending generations, repeated policy-blocked requests allocating no generation, timeout/cleanup behavior, bounded asynchronous logging, shell transaction fixtures, marker reachability and static wrapper assertions.

## Formal K1004 overlay readiness

Run `tests/publish_k1004_overlay.sh` from Linux/WSL. In one invocation it reruns
the complete host/sanitizer suite, exact K1004 static proof and QNX stat ABI
gate, rebuilds the exact AirPlay proxy/stock/Nme overlay set, verifies their
identities, publishes the three files atomically, and creates
`K1004_OVERLAY_READY` last. Do not hand-create
that readiness file. Then use `tests/build_aug22_sd_package.sh` and
`tests/verify_aug22_sd_package.sh` to construct and verify the SD tree.

The readiness manifest records both binary hashes plus:

```text
deployment_mode=K1004_EXACT_DIO_DUAL_PATH_OVERLAY
nme_targeted_imports=xpen64,xread,xrite,xlose
nme_device_scope=/dev/otg-cinemo_ONLY
exact_k1004_static=PASS
host_tests=PASS
qnx_stat_abi=PASS
initial_setup_features_array=ALTSCREEN_AND_VIEWAREAS_TRANSACTIONAL
stream_setup_response=EXPLICIT_TYPE111_SUFFICIENT_WITHOUT_REPEATED_ENABLEDFEATURES
all_displays_viewareas=FULL_SCHEMA_BEFORE_TYPE111_PUBLICATION
native_geometry=RUNTIME_DISPLAY_ID1_NO_FIXED_FALLBACK
native_geometry_ready_gate=BACKGROUND_BEFORE_FEATURE_ACCEPTANCE
native_displayable=58
native_context=76_RESTORE_74
main110_fail_open=PASS
vehicle_process_survival_validation=REQUIRED
vehicle_visual_validation=REQUIRED
```

No `FULL_CHAIN_READY` is created by offline validation.

## Transaction safety

The native-chain run remains reversible:

- clean target hook only;
- no stale preload token;
- test-2.2 BaseVideo/context owner and standalone B3/B5 stopped;
- release/install integrity and stale-state checks before the SD evidence boundary;
- target loader/constructor smoke before any system/app mutation;
- transaction authorization files reject symlink components;
- production JSON backed up before mutation;
- `/mnt/app` transaction marker and SD `current/run_id` must be strict, equal run ids at each dio_manager start; the marker remains on read-only `/mnt/app` until DISABLE removes it;
- all protocol/111 gates transaction-scoped;
- DISABLE disarms mutation first, restores JSON by checksum, verifies hook/preload removal, returns mounts read-only, then clears `ACTIVE`;
- START rollback checksum-verifies the backup and retains `ACTIVE + DISABLE_FAILED` if cleanup is incomplete;
- MARK/COLLECT failure never suppresses SAVE+RESTORE; evidence completeness and restore success are reported separately;
- failed restore leaves `ACTIVE + DISABLE_FAILED` so failure cannot masquerade as success;
- successful file/config restoration remains `RESTORE_PENDING_REBOOT` until a full MMI reboot and stock CarPlay check.

Vehicle native testing is permitted only when `RX_CHAIN_READY` matches the exact formal binary and source identity. Static/source integration still cannot prove human-visible cockpit content; that result must be checked on the vehicle.
