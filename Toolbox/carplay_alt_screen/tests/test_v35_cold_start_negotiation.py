#!/usr/bin/env python3
from pathlib import Path

root = Path(__file__).resolve().parents[3]
src = root / "Toolbox/carplay_alt_screen/src"

hook = (src / "altscreen_hook.c").read_text()
air = (src / "p1404_airplay.c").read_text()
full = (src / "p1404_airplay_fullchain.c").read_text()
native = (src / "p1404_cockpit_native.c").read_text()
java = (root / "Toolbox/carplay_alt_screen/hmi/src/com/luka/carplay/cluster/ClusterStateController.java").read_text()

def require(cond, msg):
    if not cond:
        raise SystemExit("V35_COLD_START_VERIFY=FAIL " + msg)

# Protocol readiness must be published before the asynchronous Screen geometry loop.
ready = hook.find('PHASE=NEGOTIATION_READY result=PASS policy=V35_EARLY_PROTOCOL_READY')
loop = hook.find('for (geometry_step = 0; geometry_step < ALTSCREEN_GEOMETRY_WAIT_STEPS;')
require(ready >= 0 and loop >= 0 and ready < loop,
        "NEGOTIATION_READY must precede geometry retry loop")
require('native_geometry_ready ? "PASS" : "DEFERRED"' in hook,
        "geometry miss must be DEFERRED, not fatal")
geometry_tail = hook[loop:hook.find('return NULL;', loop) + len('return NULL;')]
require('__sync_lock_test_and_set(&g_runtime_init_state, 3u)' not in geometry_tail,
        "background geometry timeout must not make runtime inert")
require('int altscreen_runtime_wait_ready(unsigned timeout_ms)' in hook,
        "bounded negotiation-ready wait helper missing")

# First capability transaction gets a bounded conditional wait, never a long fixed sleep.
require('#define ALTSCREEN_NEGOTIATION_WAIT_MS 500u' in air,
        "500 ms bounded capability wait missing")
for phase in ('server-features', 'session-displays', 'screen-displays'):
    require(f'alt_runtime_negotiation_ready("{phase}")' in air,
            f"cold-start guard missing for {phase}")
for phase in ('session-setup', 'private111-setup'):
    require(f'alt_runtime_negotiation_ready("{phase}")' in full,
            f"cold-start guard missing for {phase}")

# Bootstrap geometry is negotiation-only; live Screen geometry still owns renderer safety.
require('#define ALT111_BOOTSTRAP_WIDTH 1440u' in air, "bootstrap width changed")
require('#define ALT111_BOOTSTRAP_HEIGHT 542u' in air, "bootstrap height changed")
require('source=BOOTSTRAP size=%ux%u provisional=1 renderer_verified=0' in air,
        "bootstrap must be explicitly provisional")
require('PHASE=ALT111_GEOMETRY_CONTRACT_MISMATCH' in air,
        "geometry mismatch fence missing")
require('alt_airplay_validate_runtime_geometry(width, height)' in native,
        "native attach does not validate negotiated geometry")
validate_pos = native.find('alt_airplay_validate_runtime_geometry(width, height)')
video_pos = native.find('video_impl = read_ptr_at(stream, SCREEN_STREAM_VIDEO_IMPL_OFF)', validate_pos)
require(validate_pos >= 0 and video_pos > validate_pos,
        "geometry validation must precede renderer ownership")

# V3.5 visual geometry keeps V3.4 horizontal/Context policy with only top=75.
for marker in (
    'safearea_revision=V35_OEM_X_VERTICAL_75_450',
    'full.y = 75u;',
    'full.h = 375u;',
    'small.y = 75u;',
    'small.h = 375u;',
):
    require(marker in air, "visual geometry regression: " + marker)
require('public static final int CTX_COMPOSITE = 80;' in java,
        "Context80 policy changed")
require('private static final long RECONCILE_MS = 250L;' in java,
        "Context80 reconcile cadence changed")

print("V35_COLD_START_VERIFY=PASS negotiation=EARLY geometry=ASYNC bootstrap=1440x542 renderer=LIVE_MATCH")
