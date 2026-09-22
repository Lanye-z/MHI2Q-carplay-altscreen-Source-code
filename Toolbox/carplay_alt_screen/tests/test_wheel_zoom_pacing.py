#!/usr/bin/env python3
"""Reference contract for V3.1 OEM-style frame-health wheel pacing."""

PENDING_LIMIT = 4
MIN_PACE_MS = 120
FALLBACK_PACE_MS = 200
FRESH_FRAME_AGE_MS = 100
STALL_AGE_MS = 150
FRESH_FRAMES = 3
INPUT_QUIET_MS = 350
PENDING_HARD_EXPIRE_MS = 600


def clamp_pending(value):
    if value > PENDING_LIMIT:
        return PENDING_LIMIT
    if value < -PENDING_LIMIT:
        return -PENDING_LIMIT
    return value


class Model:
    def __init__(self):
        self.pending = 0
        self.last_input_ms = None
        self.last_send_ms = None
        self.sent = []
        self.frame_count = 0
        self.last_frame_ms = None
        self.telemetry = True
        self.baseline = None
        self.recovery_base = None
        self.saw_stall = False
        self.clears = []

    def frame(self, now_ms, count=1):
        self.frame_count += count
        self.last_frame_ms = now_ms

    def add(self, now_ms, delta):
        self.pending = clamp_pending(self.pending + delta)
        self.last_input_ms = now_ms
        self.drain(now_ms)

    def tick(self, now_ms):
        self.drain(now_ms)

    def _capture_baseline(self):
        if self.telemetry and self.last_frame_ms is not None:
            self.baseline = self.frame_count
            self.recovery_base = self.frame_count
        else:
            self.baseline = None
            self.recovery_base = None
        self.saw_stall = False

    def _clear_pending(self, now_ms, reason):
        self.clears.append((now_ms, reason, self.pending))
        self.pending = 0
        self.last_input_ms = None
        self.baseline = None
        self.recovery_base = None
        self.saw_stall = False

    def drain(self, now_ms):
        if self.pending == 0:
            return

        input_quiet = (
            None
            if self.last_input_ms is None
            else now_ms - self.last_input_ms
        )

        if (
            input_quiet is not None
            and input_quiet >= PENDING_HARD_EXPIRE_MS
        ):
            self._clear_pending(now_ms, "hard_expire")
            return

        if self.last_send_ms is None:
            ready = True
        else:
            elapsed = now_ms - self.last_send_ms
            if self.telemetry and self.last_frame_ms is not None:
                frame_age = now_ms - self.last_frame_ms

                if self.baseline is None:
                    self.baseline = self.frame_count
                    self.recovery_base = self.frame_count
                    self.saw_stall = False

                if (
                    not self.saw_stall
                    and elapsed >= MIN_PACE_MS
                    and frame_age >= STALL_AGE_MS
                ):
                    self.saw_stall = True
                    self.recovery_base = self.frame_count

                if (
                    input_quiet is not None
                    and input_quiet >= INPUT_QUIET_MS
                    and frame_age >= STALL_AGE_MS
                ):
                    self._clear_pending(now_ms, "quiet_stall")
                    return

                base = (
                    self.recovery_base
                    if self.saw_stall
                    else self.baseline
                )
                fresh = self.frame_count - base
                ready = (
                    elapsed >= MIN_PACE_MS
                    and frame_age <= FRESH_FRAME_AGE_MS
                    and fresh >= FRESH_FRAMES
                )
            else:
                ready = elapsed >= FALLBACK_PACE_MS

        if not ready:
            return

        if self.pending < 0:
            direction = "IN"
            self.pending += 1
        else:
            direction = "OUT"
            self.pending -= 1

        self.sent.append((now_ms, direction))
        self.last_send_ms = now_ms
        self._capture_baseline()


def test_first_step_immediate():
    m = Model()
    m.frame(0, 1)
    m.add(0, 1)
    assert m.sent == [(0, "OUT")]


def test_healthy_burst_finishes_only_inside_short_tail():
    m = Model()
    m.frame(0, 1)
    m.add(0, 4)
    for t in (100, 200, 300, 400, 500, 600):
        m.frame(t, 3)
        m.tick(t)
    assert m.sent == [
        (0, "OUT"),
        (200, "OUT"),
        (400, "OUT"),
    ]
    assert m.pending == 0
    assert m.clears == [(600, "hard_expire", 1)]


def test_stall_plus_quiet_clears_without_recovery_replay():
    m = Model()
    m.frame(0, 1)
    m.add(0, 4)
    m.tick(200)       # stale decoded frame => stall latch
    m.tick(400)       # >350 ms quiet while still stale => clear tail
    m.frame(500, 3)
    m.tick(500)       # recovery must not replay old zoom steps
    assert m.sent == [(0, "OUT")]
    assert m.pending == 0
    assert m.clears == [(400, "quiet_stall", 3)]


def test_recovery_before_quiet_timeout_can_continue():
    m = Model()
    m.frame(0, 1)
    m.add(0, 3)
    m.add(100, 1)     # extend active burst; pending remains bounded
    m.tick(200)       # no frame progress, stall latch
    m.frame(300, 3)   # recovered before 350 ms quiet from last input
    m.tick(300)
    assert m.sent == [(0, "OUT"), (300, "OUT")]
    assert m.pending == 2


def test_opposite_steps_cancel_unsent_pending():
    m = Model()
    m.frame(0, 1)
    m.add(0, 1)       # immediate
    m.add(20, 2)
    m.add(40, -2)     # unsent tail cancels before next adaptive slot
    m.frame(200, 3)
    m.tick(200)
    assert m.sent == [(0, "OUT")]
    assert m.pending == 0


def test_telemetry_unavailable_uses_200ms_fallback_but_no_long_tail():
    m = Model()
    m.telemetry = False
    m.add(0, 4)
    m.tick(100)
    m.tick(200)
    m.tick(400)
    m.tick(600)
    assert m.sent == [
        (0, "OUT"),
        (200, "OUT"),
        (400, "OUT"),
    ]
    assert m.pending == 0
    assert m.clears == [(600, "hard_expire", 1)]


def test_hard_expiry_is_never_later_than_600ms():
    m = Model()
    m.frame(0, 1)
    m.add(0, 4)
    m.frame(200, 3)
    m.tick(200)
    m.frame(400, 3)
    m.tick(400)
    m.frame(600, 3)
    m.tick(600)
    assert m.sent[-1] == (400, "OUT")
    assert m.pending == 0
    assert m.clears[-1][0:2] == (600, "hard_expire")


def test_pending_limit_stays_bounded():
    m = Model()
    m.frame(0, 1)
    m.add(0, 20)
    assert m.sent == [(0, "OUT")]
    assert m.pending == 3


if __name__ == "__main__":
    test_first_step_immediate()
    test_healthy_burst_finishes_only_inside_short_tail()
    test_stall_plus_quiet_clears_without_recovery_replay()
    test_recovery_before_quiet_timeout_can_continue()
    test_opposite_steps_cancel_unsent_pending()
    test_telemetry_unavailable_uses_200ms_fallback_but_no_long_tail()
    test_hard_expiry_is_never_later_than_600ms()
    test_pending_limit_stays_bounded()
    print(
        "WHEEL_ZOOM_PACING_TEST=PASS "
        "model=OEM_STEPS_V1 pacing=FRAME_HEALTH_ADAPTIVE "
        "min_pace_ms=120 fallback_ms=200 fresh_frames=3 "
        "fresh_age_ms=100 stall_age_ms=150 input_quiet_ms=350 "
        "pending_hard_expire_ms=600 pending_limit=4 "
        "opposite=cancel response_gate=no late_replay=blocked"
    )
