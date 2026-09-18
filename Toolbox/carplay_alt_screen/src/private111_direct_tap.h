#ifndef PRIVATE111_DIRECT_TAP_H
#define PRIVATE111_DIRECT_TAP_H

#include <stddef.h>
#include <stdint.h>

/*
 * All functions are fail-open.  A tap failure must never change the return
 * value or timing contract of stock CarPlay Main110/private111 processing.
 */
void p111_h264_tap_write(void *stream, const void *data, size_t bytes);
void p111_frame_tap_write(void *stream, const unsigned char *buffer,
                          uint32_t width, uint32_t height);
void p111_direct_tap_stream_end(void *stream);

#endif
