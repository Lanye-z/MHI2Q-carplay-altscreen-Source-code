#!/usr/bin/env python3
"""Host model for V3.4 updateViewArea request/ACK/frame lifecycle."""

TIMEOUT_MS = 4000


class ViewAreaModel:
    def __init__(self, generation=1):
        self.generation = generation
        self.target = 0
        self.applied = -1
        self.state = 0
        self.command_seq = 0
        self.inflight_seq = 0
        self.acked_seq = 0
        self.baseline_generation = 0
        self.baseline_count = 0
        self.baseline_valid = False
        self.frame_pending = False
        self.ack_at = None

    def set_target(self, index):
        assert index in (0, 1)
        if self.target != index:
            self.target = index
            self.applied = -1
            self.state = 0
            self.inflight_seq = 0
            self.acked_seq = 0
            self.baseline_valid = False
            self.frame_pending = False

    def submit(self, frame_generation=10, frame_count=100):
        assert self.state != 1
        self.command_seq = (self.command_seq + 1) & 0xFFFFFFFF
        if self.command_seq == 0:
            self.command_seq = 1
        self.inflight_seq = self.command_seq
        self.state = 1
        self.baseline_generation = frame_generation
        self.baseline_count = frame_count
        self.baseline_valid = True
        self.frame_pending = False
        return self.generation, self.inflight_seq, self.target

    def timeout(self):
        assert self.state == 1
        self.state = 0
        self.inflight_seq = 0
        self.baseline_valid = False
        self.frame_pending = False

    def ack(self, generation, seq, index, accepted=True, now_ms=0):
        current = (
            generation == self.generation
            and index == self.target
            and self.state == 1
            and seq == self.inflight_seq
        )
        if not current:
            return False
        if accepted:
            self.applied = index
            self.state = 2
            self.acked_seq = seq
            self.ack_at = now_ms
            self.frame_pending = True
        else:
            self.state = 0
            self.inflight_seq = 0
            self.baseline_valid = False
            self.frame_pending = False
        return True

    def frame(self, frame_generation, frame_count):
        if not self.frame_pending or self.state != 2:
            return False
        if not self.baseline_valid:
            self.baseline_generation = frame_generation
            self.baseline_count = frame_count
            self.baseline_valid = True
            return False
        fresh = (
            frame_generation != self.baseline_generation
            or frame_count != self.baseline_count
        )
        if fresh:
            self.frame_pending = False
        return fresh

    def frame_timeout(self, now_ms):
        if (
            self.frame_pending
            and self.ack_at is not None
            and now_ms > self.ack_at + TIMEOUT_MS
        ):
            self.frame_pending = False
            return True
        return False


def test_same_target_retry_rejects_old_ack():
    m = ViewAreaModel()
    m.set_target(1)
    g1, seq1, idx1 = m.submit()
    m.timeout()
    g2, seq2, idx2 = m.submit(frame_count=101)
    assert seq2 != seq1 and g2 == g1 and idx2 == idx1 == 1
    assert not m.ack(g1, seq1, 1, True, 10)
    assert m.state == 1 and m.inflight_seq == seq2
    assert m.ack(g2, seq2, 1, True, 20)
    assert m.state == 2 and m.acked_seq == seq2


def test_target_change_rejects_old_ack_and_forces_resend():
    m = ViewAreaModel()
    m.set_target(1)
    g, seq, _ = m.submit()
    m.set_target(0)
    assert m.applied == -1
    assert not m.ack(g, seq, 1, True, 10)
    _, new_seq, idx = m.submit(frame_count=102)
    assert new_seq != seq and idx == 0


def test_old_generation_rejected():
    m = ViewAreaModel(generation=7)
    m.set_target(1)
    _, seq, _ = m.submit()
    assert not m.ack(6, seq, 1, True, 10)
    assert m.state == 1


def test_ack_is_not_visual_completion():
    m = ViewAreaModel()
    m.set_target(1)
    g, seq, idx = m.submit(frame_generation=20, frame_count=200)
    assert m.ack(g, seq, idx, True, 100)
    assert m.frame_pending
    assert not m.frame(20, 200)
    assert m.frame_pending
    assert m.frame(20, 201)
    assert not m.frame_pending


def test_ack_without_new_frame_times_out():
    m = ViewAreaModel()
    m.set_target(1)
    g, seq, idx = m.submit()
    assert m.ack(g, seq, idx, True, 100)
    assert not m.frame_timeout(4100)
    assert m.frame_timeout(4101)
    assert not m.frame_pending


def main():
    test_same_target_retry_rejects_old_ack()
    test_target_change_rejects_old_ack_and_forces_resend()
    test_old_generation_rejected()
    test_ack_is_not_visual_completion()
    test_ack_without_new_frame_times_out()
    print(
        "VIEW_AREA_LIFECYCLE_TEST=PASS "
        "same_target_retry_stale_ack=FENCED "
        "retarget_resend=YES old_generation=FENCED "
        "ack_is_visual_proof=NO post_ack_fresh_frame_tracked=YES"
    )


if __name__ == "__main__":
    main()
