# CarPlay Second Screen / Context80 Readback V1

Branch: `test/carplay-basevideo3-context80-readback-v1`

```text
iPhone Type111
  -> private ScreenSession / ScreenStream
  -> stock Qualcomm OMX + CScreenRender
  -> source Window58
  -> screen_read_window()
  -> BGRA CPU frame
  -> GLES
  -> destination displayable3
  -> Java/HMI ctx80={98,101,102,3}
  -> Virtual Cockpit
```

The previous direct BaseVideo3 test proved Stream111 and stock OMX/CScreenRender, but
`screen_manage_window()` changed its direct displayable3 producer from
`visible=1` to `visible=0`; a later force-visible call returned success while
the property still read back as 0. This branch separates decoder producer, pixel
bridge, display sink and context owner.

## Seven fixes

1. Stock private renderer is restored to Window58; it is no longer the final displayable3.
2. `/tmp/mmi-mirror-basevideo.ready` means destination first-present, not source post.
3. `screen_read_window -> BGRA -> GLES` is installed and launched.
4. Window58 and displayable3 have separate ownership.
5. Final displayable3 is created by the proven libdisplayinit backend instead of assuming QNX numeric ID equals Audi displayable identity.
6. The skipped stock window-group lifecycle is no longer the final VC sink lifecycle; libdisplayinit/EGL owns destination lifecycle.
7. Annex-B SPS/PPS/IDR observer counters are non-authoritative for the stock AVCC decoder; successful stock posts plus successful readback/present are the readiness truth.

Java/HMI is the only terminal1 context writer. The release sidecar's historical
dmdt commands are neutralized and START clears stale FULL_CHAIN_MODE /
NATIVE_DISPLAY_MODE markers.

Expected STATUS progression:
```text
NATIVE_FRAME_READY=YES
WINDOW58_IDENTITY=ID_STRING_MATCH ... id_string='58' ...
DEST_FRAME_READY=YES
READBACK_SIDECAR=RUNNING
JAVA_CTX80_REQUEST=YES
JAVA_CTX80_ACTUAL=80 source=IDisplayManager.getCurrentContextID
PHYSICAL_ROUTE_READY=SOFTWARE_CHAIN_COMPLETE
```

The QNX-generated numeric `SCREEN_PROPERTY_ID` is diagnostic only. Window58
matching is based exclusively on the owner-defined
`SCREEN_PROPERTY_ID_STRING="58"`; numeric-ID fallback is disabled. The ID compatibility helper is loaded only
inside the readback sidecar; it is never added to the CarPlay/dio_manager preload.

The last line still requires visual confirmation on the VC.


## Finalized HMI artifact

The vehicle JAR is rebuilt only at ClusterStateController.class; all other entries stay inherited from the pinned BaseVideo3 JAR.

size    = 143072
cksum   = 486999738
SHA256  = 23784668341ea235e9521fc26ece8dfb265a0391cb1d0b62e8f6aca5bf53de55
ctx80   = {98,101,102,3}
proof   = CTX80_OBSERVED actual=80
