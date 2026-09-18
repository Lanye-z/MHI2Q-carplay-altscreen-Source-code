# AltScreen source provenance

This repository is now intentionally **ZIP self-contained for the Mirror sidecar build**. GitHub `Download ZIP` includes the actual C/C++ source files, `Makefile`, and `build_qnx.sh`; no Git submodule initialization is required.

## Vendored Mirror source

- Source repository: `yuedizhibo/mib2q-MMI-Cockpit-Carplay`
- Source commit: `f79908afda4a6658f41a46e3a96c81246c6a2fc4`
- Original path: `Toolbox/carplay_alt_screen/mirror_display`
- Vendored path here: `Toolbox/carplay_alt_screen/mirror_display`
- Embedded sidecar build ID: `window58-wm-context-v3`

The vendored source contains the 2026-09-17 Window58 correction: `CarPlayWindowSource` creates `SCREEN_WINDOW_MANAGER_CONTEXT` first, falls back to `SCREEN_DISPLAY_MANAGER_CONTEXT` only when necessary, emits the first Window census unconditionally, and reports the first `screen_read_window` failure even without verbose logging.

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

A successful build verifies that the ELF contains `window58-wm-context-v3`. If your SDK is installed elsewhere, provide `QNX_HOST` and `QNX_TARGET` before running the script.

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

The checked-in universal runtime `Toolbox/carplay_alt_screen/universal/libcarplay_altscreen.so` was rebuilt from the reviewed AltScreen development source after the in-car Stream 111 regression where firewall helper processes inherited the preload and re-entered hook initialization.

- Development repository: `yuedizhibo/mib2q-MMI-Cockpit-Carplay`
- Source/build trigger commit: `06e61fc90f256adefbcb685e9d14823848f1f3d2`
- Published build-branch commit: `42763e5126b6bee93bf294b5a411c3cf5330d572`
- Built binary Git blob: `646943d2fe8fd2f3be2968d9bd1368d66fe1e7e1`
- Runtime SHA-256: `0dea2efef91b842cdaae6973a9b8ec3fd95c06cb48e9f3118fc545a78ee288de`
- Runtime size: `227836` bytes

The repair has three runtime safety changes:

1. The constructor removes only this AltScreen library from the current process' inherited `LD_PRELOAD` value after the library is already mapped. This prevents later `sh` / `pfctl` firewall helpers from loading the hook again while preserving unrelated preload entries.
2. Process identity is now the first hook safety gate. Non-CarPlay helper processes return before stock AirPlay binding, Native111 binding, CF setup, internal GOT redirects, or the asynchronous runtime worker.
3. `FORCE_START` can no longer override process identity. It remains limited to the existing transaction-authorization bypass inside an already validated CarPlay host.

GitHub Actions' `universal-qnx-build` job completed successfully for this source and verified the QNX ELF surface. The binary remains `ELF32 ARM EABI5`, depends only on `libc.so.3` and `libm.so.2`, and contains the `identity_override=DISABLED` runtime marker. The unrelated full host certification job still reports the pre-existing `cfl_proof_invocation_drift` scope failure; that failure occurs before these helper-isolation checks and is not the QNX build result.

## Runtime boundary

Compiling does **not** automatically overwrite the checked-in vehicle runtime under `mirror_display/release/`. This remains deliberate: the release ELF and its hashes should only be replaced after a reviewed QNX build. The current checked-in release binary may therefore remain older than the vendored source until promotion is performed.

## Source update policy

There is no `.gitmodules` dependency anymore. When the authoritative development source changes, copy the reviewed Mirror build files into this directory and update `VENDORED_SOURCE.txt` plus this provenance document to the new upstream commit. This keeps GitHub ZIP downloads reproducible and avoids an invisible submodule pointer.
