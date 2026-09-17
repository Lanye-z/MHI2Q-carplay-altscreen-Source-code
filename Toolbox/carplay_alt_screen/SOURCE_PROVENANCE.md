# AltScreen source snapshot provenance

This repository keeps the vehicle runtime package and its development source intentionally separate.

## Pinned upstream source

- Repository: `yuedizhibo/mib2q-MMI-Cockpit-Carplay`
- Commit: `9fa2cb5541586158f6cc1e93b8391396950189a0`
- Git submodule path: `Toolbox/carplay_alt_screen/source_upstream`

The pin contains the complete development tree used for the AltScreen hook and Mirror sidecar, including `Toolbox/carplay_alt_screen/src/`, QNX compatibility shims, linker maps, `build_qnx_arm.sh`, and `mirror_display/src/` with its Makefile/build scripts.

## Runtime boundary

Adding this source pin does **not** change the installed vehicle runtime. The target repository continues to use its existing checked-in runtime artifacts under `Toolbox/carplay_alt_screen/universal/` and `Toolbox/carplay_alt_screen/mirror_display/release/` until a deliberate reviewed rebuild replaces them.

In particular, the source sync does not restore the historical K1004/P1404 profile route. The target repository's UNIVERSAL-only INSTALL/START policy remains authoritative.

The pinned upstream source still contains historical names and build comments describing older K1004/P1404/direct-overlay workflows. Treat those as source history, not as the target repository's current installation policy.

## Getting the source

After cloning this repository with credentials that can read the private upstream repository:

```sh
git submodule update --init Toolbox/carplay_alt_screen/source_upstream
```

Then use `Toolbox/carplay_alt_screen/build_source_snapshot.sh` for the baseline hook or Mirror build entry points.
