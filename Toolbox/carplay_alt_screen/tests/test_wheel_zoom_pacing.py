#!/usr/bin/env python3
"""V3.3 adaptive wheel contract for OEM_TARGET_FOLLOW_V1."""

TARGET_LIMIT = 12
MAX_EVENT_STEPS = 16
ACTIVE_SHORT_PACE_MS = 100
ACTIVE_NORMAL_PACE_MS = 150
ACTIVE_LONG_PACE_MS = 200
QUIET_SMALL_BACKLOG_PACE_MS = 100
QUIET_BACKLOG_PACE_MS = 150
SEND_RETRY_MS = 150
FALLBACK_PACE_MS = 250
FRESH_FRAME_AGE_MS = 100
STALL_AGE_MS = 150
RECOVERY_FRAMES = 3
BURST_GAP_MS = 300
INPUT_ACTIVE_MS = 300
SHORT_BURST_MAX_STEPS = 2
NORMAL_BURST_MAX_STEPS = 6
SMALL_BACKLOG_MAX_STEPS = 2
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
        self.have_input_direction = False
        self.last_input_direction = None
        self.reverse_response_pending = False
        self.burst_input_steps = 0
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
        direction = "IN" if delta < 0 else "OUT"
        new_burst = (
            not self.have_input_time
            or elapsed_u32(now_ms, self.last_input_ms) >= BURST_GAP_MS
        )
        direction_changed = (
            self.have_input_direction and direction != self.last_input_direction
        )
        if new_burst or direction_changed:
            self.burst_input_steps = 0
            if new_burst:
                self.reverse_response_pending = False
        self.burst_input_steps += abs(delta)
        if direction_changed:
            self.reverse_response_pending = True
        self.last_input_direction = direction
        self.have_input_direction = True
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
        self.have_input_direction = False
        self.last_input_direction = None
        self.reverse_response_pending = False
        self.burst_input_steps = 0
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

    def _selected_pace(self, input_quiet, error):
        backlog = abs(error)
        next_direction = "IN" if error < 0 else "OUT"
        if (
            self.reverse_response_pending
            and next_direction == self.last_input_direction
        ):
            return ACTIVE_SHORT_PACE_MS, "REVERSE_RESPONSE"
        if input_quiet >= INPUT_ACTIVE_MS:
            if backlog <= SMALL_BACKLOG_MAX_STEPS:
                return QUIET_SMALL_BACKLOG_PACE_MS, "QUIET_SMALL_BACKLOG"
            return QUIET_BACKLOG_PACE_MS, "QUIET_BACKLOG"
        if self.burst_input_steps <= SHORT_BURST_MAX_STEPS:
            return ACTIVE_SHORT_PACE_MS, "ACTIVE_SHORT"
        if self.burst_input_steps <= NORMAL_BURST_MAX_STEPS:
            return ACTIVE_NORMAL_PACE_MS, "ACTIVE_NORMAL"
        return ACTIVE_LONG_PACE_MS, "ACTIVE_LONG"

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
        selected_pace, pace_mode = (0, "FIRST_SEND") if first_send else (
            self._selected_pace(input_quiet, self.target - self.sent_level)
        )

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
                self.reverse_response_pending = False
                return

        if self.stall:
            return

        if first_send:
            ready = True
        elif self.first_step_pending:
            ready = elapsed >= selected_pace
        elif progress is not None and progress["fresh"] is not None:
            ready = elapsed >= selected_pace and progress["fresh"] > 0
        else:
            selected_pace, pace_mode = FALLBACK_PACE_MS, "NO_TELEMETRY_FALLBACK"
            ready = elapsed >= selected_pace

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
        self.sent.append((
            u32(now_ms), direction, self.target, self.sent_level,
            pace_mode, selected_pace
        ))
        self.last_send_ms = u32(now_ms)
        self.have_send_time = True
        self.have_failed_send_time = False
        self.first_step_pending = False
        if self.reverse_response_pending and direction == self.last_input_direction:
            self.reverse_response_pending = False
        self.send_frame_base = self.frame_count if self.telemetry else None
        if self.target == self.sent_level and self.target != 0:
            self.target = 0
            self.sent_level = 0
            self.rebases += 1


def test_first_detent_is_immediate():
    m = Model()
    m.frame(0)
    m.add(0, 1)
    assert m.sent[0][:4] == (0, "OUT", 1, 1)


def test_active_short_burst_uses_100ms():
    m = Model()
    m.frame(0)
    m.add(0, 1)
    m.frame(50)
    m.add(50, 1)
    m.frame(99)
    m.tick(99)
    assert len(m.sent) == 1
    m.frame(100)
    m.tick(100)
    assert m.sent[-1][0] == 100
    assert m.sent[-1][4:] == ("ACTIVE_SHORT", 100)


def test_active_normal_burst_uses_150ms():
    m = Model()
    m.frame(0)
    m.add(0, 1)
    m.frame(20)
    m.add(20, 1)
    m.frame(40)
    m.add(40, 1)
    m.frame(100)
    m.tick(100)
    assert len(m.sent) == 1
    m.frame(149)
    m.tick(149)
    assert len(m.sent) == 1
    m.frame(150)
    m.tick(150)
    assert m.sent[-1][4:] == ("ACTIVE_NORMAL", 150)


def test_active_long_burst_uses_200ms():
    m = Model()
    m.frame(0)
    m.add(0, 1)
    for t in (20, 40, 60, 80, 100, 120):
        m.frame(t)
        m.add(t, 1)
    m.frame(150)
    m.tick(150)
    assert len(m.sent) == 1
    m.frame(200)
    m.tick(200)
    assert m.sent[-1][4:] == ("ACTIVE_LONG", 200)


def test_quiet_large_backlog_drains_at_150ms():
    m = Model()
    m.frame(0)
    m.add(0, 7)
    m.frame(200)
    m.tick(200)
    assert m.sent[-1][4:] == ("ACTIVE_LONG", 200)
    m.frame(300)
    m.tick(300)
    assert len(m.sent) == 2
    m.frame(350)
    m.tick(350)
    assert m.sent[-1][4:] == ("QUIET_BACKLOG", 150)


def test_quiet_small_backlog_drains_at_100ms():
    m = Model()
    m.frame(0)
    m.add(0, 3)
    m.frame(300)
    m.tick(300)
    assert m.sent[-1][4:] == ("QUIET_SMALL_BACKLOG", 100)
    m.frame(400)
    m.tick(400)
    assert m.sent[-1][4:] == ("QUIET_SMALL_BACKLOG", 100)


def test_reverse_crossing_gets_100ms_response():
    m = Model()
    m.frame(0)
    m.add(0, 4)
    m.frame(50)
    m.add(50, -5)
    assert m.target < m.sent_level
    m.frame(99)
    m.tick(99)
    assert len(m.sent) == 1
    m.frame(100)
    m.tick(100)
    assert m.sent[-1][1] == "IN"
    assert m.sent[-1][4:] == ("REVERSE_RESPONSE", 100)


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
    m.tick(199)
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
    assert m.sent[0][:4] == (150, "OUT", 1, 1)
    assert m.sent[0][4:] == ("FIRST_SEND", 0)
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
    test_active_short_burst_uses_100ms()
    test_active_normal_burst_uses_150ms()
    test_active_long_burst_uses_200ms()
    test_quiet_large_backlog_drains_at_150ms()
    test_quiet_small_backlog_drains_at_100ms()
    test_reverse_crossing_gets_100ms_response()
    test_reverse_retargets_instead_of_replaying_old_out_steps()
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
        "pacing=BURST_ADAPTIVE_100_150_200_V2 tick_ms=50 "
        "active_short_ms=100 active_normal_ms=150 active_long_ms=200 "
        "quiet_small_backlog_ms=100 quiet_backlog_ms=150 "
        "input_active_ms=300 short_burst_max=2 normal_burst_max=6 "
        "small_backlog_max=2 fallback_ms=250 send_retry_ms=150 "
        "recovery_frames=3 fresh_age_ms=100 stall_age_ms=150 "
        "burst_gap_ms=300 stall_abort_quiet_ms=350 stall_abort_ms=1200 "
        "outstanding_limit=12 settled_rebase=IMMEDIATE "
        "submit_failure_advances_state=NO u32_zero_sentinel=NO "
        "future_frame_timestamp_clamp=YES decoded_feedback=LIVENESS_ONLY "
        "camera_completion_signal=UNAVAILABLE"
    )


if __name__ == "__main__":
    main()
