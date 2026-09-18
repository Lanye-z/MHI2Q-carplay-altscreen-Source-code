/* p1404_control_fence.h - process-wide private111 control transaction fence. */
#ifndef P1404_CONTROL_FENCE_H
#define P1404_CONTROL_FENCE_H

#include <stdint.h>

/*
 * P1404 exposes one wired CarPlay receiver/control chain inside dio_manager.
 * Keep the fence process-wide and conservative: a newer private111 SETUP or any
 * teardown invalidates every older private111 SETUP token. This avoids relying on
 * undocumented control-thread serialization.
 */
uint32_t alt_control_fence_begin(void);
int      alt_control_fence_is_current(uint32_t generation);

/* lock_current keeps the fence lock held only on success. The caller must pair a
 * successful return with alt_control_fence_unlock(). */
int      alt_control_fence_lock_current(uint32_t generation);

/* Atomically serialize after any in-flight private commit, invalidate all older
 * SETUP tokens, and KEEP the fence lock held for teardown. */
uint32_t alt_control_fence_cancel_and_lock(void);
void     alt_control_fence_unlock(void);

/* Host-test/process-init helper. Never call while another thread owns the fence. */
void     alt_control_fence_reset(void);

#endif
