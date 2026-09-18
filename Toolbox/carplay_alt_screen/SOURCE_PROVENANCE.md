# AltScreen source provenance

This repository is now intentionally **ZIP self-contained for the Mirror sidecar build**. GitHub `Download ZIP` includes the actual C/C++ source files, `Makefile`, and `build_qnx.sh`; no Git submodule initialization is required.

## Vendored Mirror source

- Source repository: `yuedizhibo/mib2q-MMI-Cockpit-Carplay`
- Source commit: `f79908afda4a6658f41a46e3a96c81246c6a2fc4`
- Original path: `Toolbox/carplay_alt_screen/mirror_display`
- Vendored path here: `Toolbox/carplay_alt_screen/mirror_display`
- Local sidecar source build ID: `window58-wm-event-v4`

The V4 source is a local follow-up to the 2026-09-18 vehicle result. It deliberately keeps the validated Stream111 hook unchanged. The sidecar may start at boot, but it does not create any Screen context until the current hook session logs `PHASE=PHONE_REQUEST_111`. After that gate it creates a `SCREEN_WINDOW_MANAGER_CONTEXT` and tracks Window58 through `SCREEN_EVENT_CREATE`, `SCREEN_EVENT_POST`, `SCREEN_EVENT_PROPERTY`, and `SCREEN_EVENT_CLOSE`. The old `SCREEN_PROPERTY_WINDOW_COUNT/WINDOWS` context census has been removed from the acquisition path.

This V4 branch is **source-only until a real QNX 6.5 ARMv7 rebuild is completed**. The checked-in `mirror_display/release/carplay-alt111-mirror-display` remains the previously promoted V3 ELF until that rebuild/promotion step. Do not use this branch ZIP for vehicle testing before the release binary and manifests are updated.

## Download ZIP and build

1. Download the `main` branch ZIP from `Lanye-z/altscreen-test` and extract it.
2. Ensure the QNX 6.5 ARMv7 SDK/toolchain is installed. The default expected paths are:

```text
/usr/qnx650/host/qnx6/x86
/usr/qnx650/target/qnx6
```

3. From the extracted repository root run:

```sh
./BUILD-MIRROR-QNX.sh
```

or:

```sh
cd Toolbox/carplay_alt_screen/mirror_display
sh build_qnx.sh
```

The output is:

```text
Toolbox/carplay_alt_screen/mirror_display/build/carplay-alt111-mirror-display
```

A successful V4 build verifies that the ELF contains `window58-wm-event-v4` and the PHONE_REQUEST/event-observer markers. If your SDK is installed elsewhere, provide `QNX_HOST` and `QNX_TARGET` before running the script.

## Vendored universal-hook source

The universal hook source is now also vendored directly in this repository at `Toolbox/carplay_alt_screen/src/`. It was copied from the authoritative development tree as a source snapshot, then the helper-process isolation fix was applied **here in `Lanye-z/altscreen-test`**. No Git submodule or write access to the development repository is required for future edits.

Build locally with:

```sh
./BUILD-UNIVERSAL-QNX.sh
```

or:

```sh
Toolbox/carplay_alt_screen/build_source_snapshot.sh universal
```

The generated binary is written under `Toolbox/carplay_alt_screen/dev-build/universal/` unless another output directory is supplied. Checked-in vehicle runtime promotion remains a separate reviewed step.

## Universal hook runtime: 2026-09-18 helper isolation fix

The universal-hook source was copied read-only from the development repository into `Toolbox/carplay_alt_screen/src/`, and the helper-process isolation repair was then applied and built in **this repository**. Future changes should follow the same rule: read upstream when necessary, vendor missing source here, and perform all edits/builds in `Lanye-z/altscreen-test`.

- Read-only source snapshot repository: `yuedizhibo/mib2q-MMI-Cockpit-Carplay`
- Source snapshot commit: `36b0cf681871c2e2a7b4753a45cfdd56d588f058`
- Local vendoring/fix commit: `cdb5271a64a2ef4af500b96e99958194324ea617`
- Local build-dependency commit: `fc6712ca6b08108ec7e841aaef1a96c0d6775a52`
- Local successful QNX workflow run: `35293814437`

The successful `AltScreen Universal QNX Build` artifact produced by this repository was verified byte-for-byte against the checked-in runtime. Both are `227836` bytes with SHA-256 `0dea2efef91b842cdaae6973a9b8ec3fd95c06cb48e9f3118fc545a78ee288de`; `SHA256SUMS.txt` and `PACKAGE_SOURCE_MAP.json` already record that same digest, so no redundant binary/hash rewrite is required.

The repair has three runtime safety changes:

1. The constructor removes only this AltScreen library from the current process' inherited `LD_PRELOAD` value after the library is already mapped. This prevents later `sh` / `pfctl` firewall helpers from loading the hook again while preserving unrelated preload entries.
2. Process identity is now the first hook safety gate. Non-CarPlay helper processes return before stock AirPlay binding, Native111 binding, CF setup, internal GOT redirects, or the asynchronous runtime worker.
3. `FORCE_START` can no longer override process identity. It remains limited to the existing transaction-authorization bypass inside an already validated CarPlay host.

GitHub Actions' `AltScreen Universal QNX Build` completed successfully in this repository and verified the QNX ELF surface. The binary remains `ELF32 ARM EABI5`, depends only on `libc.so.3` and `libm.so.2`, and contains the `identity_override=DISABLED` runtime marker.

## Runtime boundary

Compiling does **not** automatically overwrite the checked-in vehicle runtime under `mirror_display/release/`. This remains deliberate: the release ELF and its hashes should only be replaced after a reviewed QNX build. The current checked-in release binary may therefore remain older than the vendored source until promotion is performed.

## Source update policy

There is no `.gitmodules` dependency anymore. When the authoritative development source changes, copy the reviewed Mirror build files into this directory and update `VENDORED_SOURCE.txt` plus this provenance document to the new upstream commit. This keeps GitHub ZIP downloads reproducible and avoids an invisible submodule pointer.


## private111 direct-display V1

- Branch: `carplay-private111-direct-display-v1`
- Baseline: `test/carplay-basevideo3-context80-readback-v1` @ `979b9cd573d9ebe4201979ebb286ed54c468d547`
- Compressed source: private `ScreenStreamProcessData` -> `/carplay111_h264`
- V1 decoded fallback: private stock OMX buffer tap -> `/carplay111_decoded`
- Display sink reused from MMI Mirror: `ClusterVideoDisplay` + `gl_renderer` + `mhi2q_backend`
- Destination: displayable3 under Java-owned Context80 `{98,101,102,3}`
- Window58 sidecar readback: disabled
- Sidecar QNX binary: rebuild/promotion required before vehicle ZIP
