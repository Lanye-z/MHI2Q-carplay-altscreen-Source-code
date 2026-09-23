#!/usr/bin/env python3
"""V3.3 contract for OEM_TARGET_FOLLOW_V1 with the 200 ms camera-settle guard."""

TARGET_LIMIT = 12
MAX_EVENT_STEPS = 16
MIN_PACE_MS = 200
SEND_RETRY_MS = 150
FALLBACK_PACE_MS = 250
FRESH_FRAME_AGE_MS = 100
STALL_AGE_MS = 150
RECOVERY_FRAMES = 3
BURST_GAP_MS = 300
STALL_ABORT_QUIET_MS = 350
STALL_ABORT_MS = 1200
U32 = 1 << 32


def u32(value):
    return value % U32


def elapsed_u32(now, before):
    return u32(now - before)


def short_age_u32(now, before):
    age = elapsed_u32(now, before)
    if age <= 0x7FFFFFFF:
        return age
    future_skew = elapsed_u32(before, now)
    return 0 if future_skew <= STALL_AGE_MS else 0x7FFFFFFF


def accumulate_target(target, sent_level, delta):
    error = target - sent_level
    next_error = max(-TARGET_LIMIT, min(TARGET_LIMIT, error + delta))
    return sent_level + next_error


class Model:
    def __init__(self):
        self.target = 0
        self.sent_level = 0
        self.have_input_time = False
        self.have_send_time = False
        self.have_failed_send_time = False
        self.last_input_ms = 0
        self.last_send_ms = 0
        self.last_failed_send_ms = 0
        self.sent = []
        self.attempts = []
        self.failures_remaining = 0
        self.frame_count = 0
        self.last_frame_ms = None
        self.telemetry = True
        self.send_frame_base = None
        self.stall = False
        self.stall_start_ms = None
        self.recovery_base = None
        self.first_step_pending = False
        self.aborts = []
        self.rebases = 0

    def frame(self, now_ms, count=1):
        self.frame_count += count
        self.last_frame_ms = u32(now_ms)

    def _settle(self):
        if self.target != self.sent_level:
            return
        self.first_step_pending = False
        if self.stall:
            self.stall = False
            self.stall_start_ms = None
            self.recovery_base = None
        self.have_failed_send_time = False
        if self.target != 0:
            self.target = 0
            self.sent_level = 0
            self.rebases += 1

    def add(self, now_ms, delta):
        assert 0 < abs(delta) <= MAX_EVENT_STEPS
        new_burst = (
            not self.have_input_time
            or elapsed_u32(now_ms, self.last_input_ms) >= BURST_GAP_MS
        )
        self.target = accumulate_target(self.target, self.sent_level, delta)
        self.last_input_ms = u32(now_ms)
        self.have_input_time = True
        if new_burst:
            self.first_step_pending = True
        self._settle()
        self.drain(now_ms)

    def tick(self, now_ms):
        self._settle()
        self.drain(now_ms)

    def gate_close(self):
        self.target = 0
        self.sent_level = 0
        self.last_input_ms = 0
        self.last_send_ms = 0
        self.have_input_time = False
        self.have_send_time = False
        self.have_failed_send_time = False
        self.last_failed_send_ms = 0
        self.stall = False
        self.stall_start_ms = None
        self.first_step_pending = False
        self.send_frame_base = None
        self.recovery_base = None

    def _progress(self, now_ms):
        if not self.telemetry or self.last_frame_ms is None:
            return None
        return {
            "age": short_age_u32(now_ms, self.last_frame_ms),
            "fresh": (
                None
                if self.send_frame_base is None
                else self.frame_count - self.send_frame_base
            ),
        }

    def drain(self, now_ms):
        if self.target == self.sent_level:
            return

        first_send = not self.have_send_time
        elapsed = 0 if first_send else elapsed_u32(now_ms, self.last_send_ms)
        input_quiet = (
            0
            if not self.have_input_time
            else elapsed_u32(now_ms, self.last_input_ms)
        )
        progress = self._progress(now_ms)

        if (
            not self.stall
            and not first_send
            and not self.first_step_pending
            and elapsed >= STALL_AGE_MS
            and progress is not None
            and progress["fresh"] == 0
            and progress["age"] >= STALL_AGE_MS
        ):
            self.stall = True
            self.stall_start_ms = u32(now_ms)
            self.recovery_base = self.frame_count

        if self.stall:
            if progress is not None:
                recovered = self.frame_count - self.recovery_base
                if (
                    progress["age"] <= FRESH_FRAME_AGE_MS
                    and recovered >= RECOVERY_FRAMES
                ):
                    self.stall = False
                    self.stall_start_ms = None

            if (
                self.stall
                and elapsed_u32(now_ms, self.stall_start_ms)
                    >= STALL_ABORT_MS
                and input_quiet >= STALL_ABORT_QUIET_MS
            ):
                self.aborts.append((u32(now_ms), self.target, self.sent_level))
                self.target = self.sent_level
                self.stall = False
                self.stall_start_ms = None
                self.recovery_base = None
                self.first_step_pending = False
                return

        if self.stall:
            return

        if first_send:
            ready = True
        elif self.first_step_pending:
            ready = elapsed >= MIN_PACE_MS
        elif progress is not None and progress["fresh"] is not None:
            ready = elapsed >= MIN_PACE_MS and progress["fresh"] > 0
        else:
            ready = elapsed >= FALLBACK_PACE_MS

        if (
            ready
            and self.have_failed_send_time
            and elapsed_u32(now_ms, self.last_failed_send_ms) < SEND_RETRY_MS
        ):
            ready = False

        if not ready:
            return

        direction = "IN" if self.target < self.sent_level else "OUT"
        self.attempts.append((u32(now_ms), direction))
        if self.failures_remaining:
            self.failures_remaining -= 1
            self.last_failed_send_ms = u32(now_ms)
            self.have_failed_send_time = True
            return

        self.sent_level += -1 if direction == "IN" else 1
        self.sent.append((u32(now_ms), direction, self.target, self.sent_level))
        self.last_send_ms = u32(now_ms)
        self.have_send_time = True
        self.have_failed_send_time = False
        self.first_step_pending = False
        self.send_frame_base = self.frame_count if self.telemetry else None
        if self.target == self.sent_level and self.target != 0:
            self.target = 0
            self.sent_level = 0
            self.rebases += 1


def test_first_detent_is_immediate():
    m = Model()
    m.frame(0)
    m.add(0, 1)
    assert m.sent == [(0, "OUT", 1, 1)]


def test_healthy_target_follow_uses_200ms_camera_settle_guard():
    m = Model()
    m.frame(0)
    m.add(0, 4)
    for t in (50, 100, 150):
        m.frame(t)
        m.tick(t)
    assert [x[0] for x in m.sent] == [0]
    for t in (200, 250, 300, 350, 400, 450, 500, 550, 600):
        m.frame(t)
        m.tick(t)
    assert [x[0] for x in m.sent] == [0, 200, 400, 600]
    m.tick(650)
    assert m.target == m.sent_level == 0
    assert m.rebases == 1


def test_reverse_retargets_instead_of_replaying_old_out_steps():
    m = Model()
    m.frame(0)
    m.add(0, 4)
    m.add(50, -3)
    assert m.target == m.sent_level == 0
    assert m.rebases == 1
    m.frame(100)
    m.tick(100)
    assert len(m.sent) == 1


def test_reverse_past_submitted_level_changes_direction():
    m = Model()
    m.frame(0)
    m.add(0, 4)
    m.add(50, -5)
    assert m.target == -1
    m.frame(150)
    m.tick(150)
    assert len(m.sent) == 1
    m.frame(200)
    m.tick(200)
    assert m.sent[-1][1] == "IN"
    m.frame(400)
    m.tick(400)
    assert m.sent[-1][1] == "IN"
    m.tick(450)
    assert m.target == m.sent_level == 0


def test_no_progress_latches_stall_then_three_frames_recover():
    m = Model()
    m.frame(0)
    m.add(0, 3)
    m.tick(100)
    assert len(m.sent) == 1
    m.tick(150)
    assert m.stall
    m.frame(200, 2)
    m.tick(200)
    assert m.stall
    m.frame(250, 1)
    m.tick(250)
    assert not m.stall
    assert len(m.sent) == 2


def test_target_can_change_while_stalled_without_old_replay():
    m = Model()
    m.frame(0)
    m.add(0, 4)
    m.tick(150)
    assert m.stall
    m.add(200, -4)
    assert m.target == 0
    assert m.sent_level == 1
    m.frame(250, 3)
    m.tick(250)
    assert m.sent[-1][1] == "IN"
    assert m.sent_level == 0


def test_new_burst_can_wake_static_map():
    m = Model()
    m.frame(0)
    m.add(0, 1)
    m.tick(50)
    m.frame(50, 2)
    m.tick(100)
    assert m.target == m.sent_level == 0
    m.add(1000, 1)
    assert m.sent[-1][0] == 1000


def test_long_stall_rebases_without_late_replay():
    m = Model()
    m.frame(0)
    m.add(0, 4)
    m.tick(150)
    assert m.stall
    m.tick(1350)
    assert m.target == m.sent_level == 1
    assert m.aborts == [(1350, 4, 1)]
    m.tick(1400)
    assert m.target == m.sent_level == 0


def test_telemetry_fallback_is_250ms():
    m = Model()
    m.telemetry = False
    m.add(0, 3)
    m.tick(200)
    assert len(m.sent) == 1
    m.tick(249)
    assert len(m.sent) == 1
    m.tick(250)
    assert len(m.sent) == 2


def test_limit_applies_to_outstanding_error_not_session_total():
    m = Model()
    m.telemetry = False
    now = 0
    for _ in range(30):
        m.add(now, 1)
        m.tick(now)
        now += 250
        m.tick(now)
    assert len(m.sent) == 30
    assert all(item[1] == "OUT" for item in m.sent)
    assert m.target == m.sent_level == 0
    assert m.rebases >= 29


def test_fast_backlog_is_bounded_without_permanent_ceiling():
    m = Model()
    m.telemetry = False
    for _ in range(20):
        m.add(0, 1)
    assert m.target - m.sent_level == TARGET_LIMIT
    now = 250
    while m.target != m.sent_level:
        m.tick(now)
        now += 250
    m.tick(now)
    assert m.target == m.sent_level == 0
    m.add(now + 500, 1)
    assert m.sent[-1][1] == "OUT"


def test_frame_age_future_sample_race_is_clamped_without_breaking_wrap():
    # Producer publication may land just after the monitor's earlier sample.
    assert short_age_u32(1000, 1010) == 0
    assert short_age_u32(1000, 1000 + STALL_AGE_MS) == 0
    # A larger reverse modular distance is not a plausible snapshot race and
    # must remain stale so the existing stall/abort path can make progress.
    assert short_age_u32(1000, 1000 + STALL_AGE_MS + 1) == 0x7FFFFFFF
    # A genuine short interval crossing uint32 wrap must remain intact.
    assert short_age_u32(0x20, U32 - 0x10) == 0x30


def test_u32_wrap_zero_is_not_a_sentinel():
    m = Model()
    m.telemetry = False
    near_wrap = U32 - 50
    m.add(near_wrap, 2)
    assert m.have_send_time
    assert m.have_input_time
    m.tick(0)
    assert len(m.sent) == 1
    m.tick(150)
    assert len(m.sent) == 1
    m.tick(200)
    assert len(m.sent) == 2


def test_send_failure_does_not_advance_success_state():
    m = Model()
    m.telemetry = False
    m.failures_remaining = 1
    m.add(0, 1)
    assert m.attempts == [(0, "OUT")]
    assert m.sent == []
    assert not m.have_send_time
    assert m.send_frame_base is None
    assert m.target == 1 and m.sent_level == 0
    m.tick(50)
    assert len(m.attempts) == 1
    m.tick(149)
    assert len(m.attempts) == 1
    m.tick(150)
    assert len(m.attempts) == 2
    assert m.sent == [(150, "OUT", 1, 1)]
    assert m.have_send_time
    assert not m.have_failed_send_time
    assert m.target == m.sent_level == 0


def test_successful_catchup_rebases_before_next_event():
    m = Model()
    m.telemetry = False
    m.add(0, 1)
    assert m.target == m.sent_level == 0
    m.add(50, 1)
    assert len(m.sent) == 1
    m.tick(200)
    assert len(m.sent) == 1
    m.tick(249)
    assert len(m.sent) == 1
    m.tick(250)
    assert len(m.sent) == 2
    assert m.target == m.sent_level == 0


def test_gate_close_clears_valid_zero_timestamp_state():
    m = Model()
    m.telemetry = False
    m.add(0, 2)
    assert m.last_send_ms == 0
    assert m.have_send_time
    assert m.have_input_time
    m.gate_close()
    assert not m.have_send_time
    assert not m.have_input_time
    assert m.target == m.sent_level == 0


def main():
    test_first_detent_is_immediate()
    test_healthy_target_follow_uses_200ms_camera_settle_guard()
    test_reverse_retargets_instead_of_replaying_old_out_steps()
    test_reverse_past_submitted_level_changes_direction()
    test_no_progress_latches_stall_then_three_frames_recover()
    test_target_can_change_while_stalled_without_old_replay()
    test_new_burst_can_wake_static_map()
    test_long_stall_rebases_without_late_replay()
    test_telemetry_fallback_is_250ms()
    test_limit_applies_to_outstanding_error_not_session_total()
    test_fast_backlog_is_bounded_without_permanent_ceiling()
    test_frame_age_future_sample_race_is_clamped_without_breaking_wrap()
    test_u32_wrap_zero_is_not_a_sentinel()
    test_send_failure_does_not_advance_success_state()
    test_successful_catchup_rebases_before_next_event()
    test_gate_close_clears_valid_zero_timestamp_state()
    print(
        "WHEEL_ZOOM_PACING_TEST=PASS "
        "event_model=OEM_STEPS_V1 scheduler=OEM_TARGET_FOLLOW_V1 "
        "tick_ms=50 min_pace_ms=200 fallback_ms=250 "
        "recovery_frames=3 fresh_age_ms=100 stall_age_ms=150 "
        "burst_gap_ms=300 stall_abort_quiet_ms=350 "
        "stall_abort_ms=1200 outstanding_limit=12 "
        "settled_rebase=IMMEDIATE send_retry_ms=150 "
        "submit_failure_advances_state=NO u32_zero_sentinel=NO "
        "future_frame_timestamp_clamp=YES decoded_feedback=LIVENESS_ONLY "        "camera_completion_signal=UNAVAILABLE pacing=CAMERA_SETTLE_GUARD_200MS_V1"
    )


if __name__ == "__main__":
    main()
