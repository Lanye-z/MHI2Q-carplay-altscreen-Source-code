#!/usr/bin/env python3
"""Reference contract for the V3.1 OEM-style CarPlay wheel pacing policy."""

PACE_MS = 200
PENDING_LIMIT = 4


def clamp_pending(value):
    if value > PENDING_LIMIT:
        return PENDING_LIMIT
    if value < -PENDING_LIMIT:
        return -PENDING_LIMIT
    return value


class Model:
    def __init__(self):
        self.pending = 0
        self.last_send_ms = None
        self.sent = []

    def add(self, now_ms, delta):
        self.pending = clamp_pending(self.pending + delta)
        self.drain(now_ms)

    def tick(self, now_ms):
        self.drain(now_ms)

    def drain(self, now_ms):
        if self.pending == 0:
            return
        if (
            self.last_send_ms is not None
            and now_ms - self.last_send_ms < PACE_MS
        ):
            return

        if self.pending < 0:
            direction = "IN"
            self.pending += 1
        else:
            direction = "OUT"
            self.pending -= 1

        self.sent.append((now_ms, direction))
        self.last_send_ms = now_ms


def run_until(model, end_ms, step_ms=100):
    now = 0
    while now <= end_ms:
        model.tick(now)
        now += step_ms


def test_first_step_immediate():
    m = Model()
    m.add(0, 1)
    assert m.sent == [(0, "OUT")]
    assert m.pending == 0


def test_opposite_steps_cancel_pending():
    m = Model()
    m.add(0, 1)       # first OUT is immediate
    m.add(20, 1)
    m.add(30, 1)
    m.add(40, -1)
    m.add(50, -1)     # pending returns to zero before the next pace slot
    run_until(m, 800)
    assert m.sent == [(0, "OUT")]
    assert m.pending == 0


def test_backlog_is_bounded_and_paced():
    m = Model()
    m.add(0, 10)      # saturates to +4, then sends one immediately
    for t in (100, 200, 300, 400, 500, 600, 700, 800):
        m.tick(t)
    assert m.sent == [
        (0, "OUT"),
        (200, "OUT"),
        (400, "OUT"),
        (600, "OUT"),
    ]
    assert m.pending == 0


def test_reverse_intent_cancels_unsent_tail():
    m = Model()
    m.add(0, -3)      # first IN is immediate, pending becomes -2
    m.add(50, 2)      # cancels the unsent -2
    run_until(m, 800)
    assert m.sent == [(0, "IN")]
    assert m.pending == 0


def test_slow_detents_stay_responsive():
    m = Model()
    m.add(0, 1)
    m.add(250, 1)
    m.add(500, -1)
    assert m.sent == [
        (0, "OUT"),
        (250, "OUT"),
        (500, "IN"),
    ]


if __name__ == "__main__":
    test_first_step_immediate()
    test_opposite_steps_cancel_pending()
    test_backlog_is_bounded_and_paced()
    test_reverse_intent_cancels_unsent_tail()
    test_slow_detents_stay_responsive()
    print(
        "WHEEL_ZOOM_PACING_TEST=PASS "
        "model=OEM_STEPS_V1 pace_ms=200 pending_limit=4 "
        "first_step=immediate opposite=cancel response_gate=no"
    )
