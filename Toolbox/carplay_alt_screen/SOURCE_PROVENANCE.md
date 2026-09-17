# AltScreen source snapshot provenance

This repository keeps the vehicle runtime package and its development source intentionally separate.

## Pinned upstream source

- Repository: `yuedizhibo/mib2q-MMI-Cockpit-Carplay`
- Commit: `07f821eab733401ccb520305355a0f1eae2eac73`
- Git submodule path: `Toolbox/carplay_alt_screen/source_upstream`

The pin contains the complete development tree used for the AltScreen hook and Mirror sidecar, including `Toolbox/carplay_alt_screen/src/`, QNX compatibility shims, linker maps, `build_qnx_arm.sh`, and `mirror_display/src/` with its Makefile/build scripts.

The pinned Mirror source includes the 2026-09-17 Window58 capture correction: `CarPlayWindowSource` now creates a `SCREEN_WINDOW_MANAGER_CONTEXT` first and falls back to `SCREEN_DISPLAY_MANAGER_CONTEXT` only when the Window Manager context is rejected. It also emits the first window census and first `screen_read_window` failure unconditionally, and the sidecar source carries the embedded build ID `window58-wm-context-v3`.

## Runtime boundary

Adding or updating this source pin does **not** by itself change the installed vehicle runtime. The target repository continues to use the checked-in runtime artifacts under `Toolbox/carplay_alt_screen/universal/` and `Toolbox/carplay_alt_screen/mirror_display/release/` until a deliberate reviewed QNX rebuild replaces them.

For the Window58 capture correction, a vehicle-testable package is considered rebuilt only when `carplay-alt111-mirror-display` is produced from this pin and its startup log contains:

```text
carplay-mirror: BUILD id=window58-wm-context-v3 source_context=window_manager_first diagnostics=first_scan_unconditional
```

The upstream release builder now fails closed if the built ELF does not contain that build ID, preventing an old sidecar binary from being published with new source metadata.

In particular, the source sync does not restore the historical K1004/P1404 profile route. The target repository's UNIVERSAL-only INSTALL/START policy remains authoritative.

The pinned upstream source still contains historical names and build comments describing older K1004/P1404/direct-overlay workflows. Treat those as source history, not as the target repository's current installation policy.

## Getting the source

After cloning this repository with credentials that can read the private upstream repository:

```sh
git submodule update --init Toolbox/carplay_alt_screen/source_upstream
```

Then use `Toolbox/carplay_alt_screen/build_source_snapshot.sh` for the baseline hook or Mirror build entry points. The Mirror vehicle binary itself still requires the configured QNX 6.5 ARMv7 toolchain used by `mirror_display/build_qnx.sh`.
