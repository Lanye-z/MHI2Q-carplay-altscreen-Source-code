#ifndef PRIVATE111_DIRECT_TAP_H
#define PRIVATE111_DIRECT_TAP_H

#include <stddef.h>
#include <stdint.h>

/*
 * All functions are fail-open. A tap failure must never change the return
 * value or timing contract of stock CarPlay Main110/private111 processing.
 */

/* Cache the stock ScreenStream "avcc" codec configuration.  This call never
 * creates SHM or claims a stream private by itself; the cache is emitted only
 * after the existing private111 identity gate observes ProcessData. */
void p111_h264_tap_note_avcc(void *stream, const void *data, size_t bytes);

void p111_h264_tap_write(void *stream, const void *data, size_t bytes);

/* V1 raw-pointer fallback. Kept fail-open for diagnostics only in V2. */
void p111_frame_tap_write(void *stream, const unsigned char *buffer,
                          uint32_t width, uint32_t height,
                          uint32_t format, uint32_t usage);

/*
 * V2 preferred path. Call this only after stock CScreenRender::render() has
 * posted the decoded vendor buffer. Screen is then asked to read the exact
 * stock window into a normal pixmap, which lets the platform linearize the
 * vendor 0x0001000c layout before the existing packed-NV12 SHM contract.
 *
 * Returns non-zero when the frame was published or deliberately frame-paced.
 * Returns zero when Screen linearization failed; callers may use the V1 raw
 * pointer path as a diagnostic fail-open fallback.
 */
int p111_frame_tap_write_window(void *stream, void *screen_window,
                                uint32_t width, uint32_t height,
                                uint32_t source_format,
                                uint32_t source_usage);

void p111_direct_tap_stream_end(void *stream);

#endif
