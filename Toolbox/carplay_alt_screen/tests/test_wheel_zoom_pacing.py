#!/usr/bin/env python3
"""Reference contract for V3.1 OEM-style frame-health wheel pacing."""

PENDING_LIMIT = 4
MIN_PACE_MS = 120
FALLBACK_PACE_MS = 200
FRESH_FRAME_AGE_MS = 100
STALL_AGE_MS = 150
FRESH_FRAMES = 3
PENDING_EXPIRE_MS = 1500


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

    def drain(self, now_ms):
        if self.pending == 0:
            return

        if (
            self.last_input_ms is not None
            and now_ms - self.last_input_ms > PENDING_EXPIRE_MS
        ):
            self.pending = 0
            self.baseline = None
            self.recovery_base = None
            self.saw_stall = False
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


def test_stable_frames_allow_adaptive_drain_without_burst():
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
        (600, "OUT"),
    ]
    assert m.pending == 0


def test_stall_blocks_until_three_recovery_frames():
    m = Model()
    m.frame(0, 1)
    m.add(0, 2)
    m.tick(100)       # not enough frame progress
    m.tick(200)       # stale frame => stall latch, recovery base reset
    m.frame(400, 1)
    m.tick(400)       # only one recovery frame
    m.frame(500, 2)
    m.tick(500)       # total three recovery frames => allow next
    assert m.sent == [(0, "OUT"), (500, "OUT")]
    assert m.pending == 0


def test_opposite_steps_cancel_unsent_pending():
    m = Model()
    m.frame(0, 1)
    m.add(0, 1)       # immediate
    m.add(20, 2)
    m.add(40, -2)     # unsent tail cancels before next adaptive slot
    m.frame(100, 3)
    m.tick(100)
    assert m.sent == [(0, "OUT")]
    assert m.pending == 0


def test_telemetry_unavailable_uses_200ms_fallback():
    m = Model()
    m.telemetry = False
    m.add(0, 2)
    m.tick(100)
    m.tick(200)
    assert m.sent == [(0, "OUT"), (200, "OUT")]
    assert m.pending == 0


def test_pending_expires_instead_of_late_replay():
    m = Model()
    m.frame(0, 1)
    m.add(0, 4)
    m.tick(200)       # source remains stalled
    m.tick(1600)      # stale driver intent is discarded
    assert m.sent == [(0, "OUT")]
    assert m.pending == 0


def test_pending_limit_stays_bounded():
    m = Model()
    m.frame(0, 1)
    m.add(0, 20)
    assert m.sent == [(0, "OUT")]
    assert m.pending == 3


if __name__ == "__main__":
    test_first_step_immediate()
    test_stable_frames_allow_adaptive_drain_without_burst()
    test_stall_blocks_until_three_recovery_frames()
    test_opposite_steps_cancel_unsent_pending()
    test_telemetry_unavailable_uses_200ms_fallback()
    test_pending_expires_instead_of_late_replay()
    test_pending_limit_stays_bounded()
    print(
        "WHEEL_ZOOM_PACING_TEST=PASS "
        "model=OEM_STEPS_V1 pacing=FRAME_HEALTH_ADAPTIVE "
        "min_pace_ms=120 fallback_ms=200 fresh_frames=3 "
        "fresh_age_ms=100 stall_age_ms=150 pending_expire_ms=1500 "
        "pending_limit=4 opposite=cancel response_gate=no"
    )
