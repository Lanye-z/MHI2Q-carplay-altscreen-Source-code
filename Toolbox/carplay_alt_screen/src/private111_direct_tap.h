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

/* V1 stock-OMX fallback. format/usage come from the exact private
 * CScreenRender config and let the writer pack QNX-padded NV12 safely into the
 * tight NV12 contract consumed by the existing MMI renderer sidecar. */
void p111_frame_tap_write(void *stream, const unsigned char *buffer,
                          uint32_t width, uint32_t height,
                          uint32_t format, uint32_t usage);

void p111_direct_tap_stream_end(void *stream);

#endif
