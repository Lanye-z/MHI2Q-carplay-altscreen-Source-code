#ifndef VIDEO_FRAME_H
#define VIDEO_FRAME_H

enum PixelFormat {
    PIXEL_FORMAT_RGBA8888 = 0,
    PIXEL_FORMAT_BGRA8888 = 1,
    PIXEL_FORMAT_RGBX8888 = 2,
    PIXEL_FORMAT_BGRX8888 = 3,
    PIXEL_FORMAT_NV12 = 4
};

struct VideoFrame {
    const unsigned char *data;
    int width;
    int height;
    int stride;
    PixelFormat format;
    unsigned long long timestamp_us;
    unsigned sequence;
    unsigned h264_sequence;
    unsigned h264_rx_us32;
    unsigned render_us32;
    unsigned publish_us32;
    unsigned readback_us;
    unsigned copy_us;

    VideoFrame()
        : data(0), width(0), height(0), stride(0),
          format(PIXEL_FORMAT_RGBA8888), timestamp_us(0), sequence(0),
          h264_sequence(0), h264_rx_us32(0), render_us32(0),
          publish_us32(0), readback_us(0), copy_us(0) {
    }
};

#endif
