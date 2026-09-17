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

## Runtime boundary

Compiling does **not** automatically overwrite the checked-in vehicle runtime under `mirror_display/release/`. This remains deliberate: the release ELF and its hashes should only be replaced after a reviewed QNX build. The current checked-in release binary may therefore remain older than the vendored source until promotion is performed.

## Source update policy

There is no `.gitmodules` dependency anymore. When the authoritative development source changes, copy the reviewed Mirror build files into this directory and update `VENDORED_SOURCE.txt` plus this provenance document to the new upstream commit. This keeps GitHub ZIP downloads reproducible and avoids an invisible submodule pointer.
