# Native Direct V1 — aggressive vehicle experiment

Branch: `test/native-direct-route-v1`

This branch intentionally abandons the Window58 readback bridge as the production display path.

## Data plane

```text
iPhone type111
  -> private ScreenSession / ScreenStream
  -> stock H.264 handling
  -> stock OMX
  -> stock CScreenRender
  -> private renderer config: displayable 59 -> 58
  -> screen_manage_window(..., DisplayManager secret)
  -> stock OMX owns NV12 buffers and screen_post_window
  -> dmdt dc 76 58
  -> dmdt sc 1 72
  -> dmdt sc 1 76
  -> VC
```

Teardown restores context 74.

## Explicitly disabled

```text
Window58 -> screen_read_window -> BGRA -> GLES -> displayable3
Mirror autostart
WindowManager-context window census
```

The Mirror files remain packaged only as a dormant rollback/diagnostic artifact; START removes any stale Mirror enable marker and boot block before arming the native route.

## Why context 76 first

Firmware reverse engineering shows context 76 is the smallest existing cluster composition containing displayable 58. Context 77 also contains 58 but adds KDK/RGI layers. V1 deliberately tests 76 only so the first vehicle verdict isolates native displayable58 ownership/routing. A 76/77 A/B should be a later experiment.

## Vehicle acceptance sequence

First verify main CarPlay remains healthy:

```text
AirPlay server
-> Accepted connection
-> SessionCreate
-> Main110
-> PHONE_REQUEST_111
```

Then look for:

```text
PHASE=NATIVE_DIRECT_POLICY
PHASE=NATIVE_111_PRECONFIG_ATTACH
PHASE=NATIVE_111_MANAGED_WINDOW ... manage_rc=0 buffers_rc=0 managed=1
PHASE=NATIVE_111_CONFIG_RETURN ... displayable=58 ... dm_managed=1
PHASE=NATIVE_111_FIRST_REAL_FRAME ... result=POSTED
PHASE=NATIVE_111_ROUTE_ACTIVATE_RESULT dc76_58=0 sc1_72=0 sc1_76=0
PHASE=NATIVE_111_COCKPIT_ACTIVE ... displayable=58 context=76
```

On disconnect/stop:

```text
PHASE=NATIVE_111_ROUTE_RESTORE_RESULT ... sc1_74=0
```

This is intentionally an experimental branch. Do not merge to main until a vehicle test proves both Main110 coexistence and stable cluster restore.
