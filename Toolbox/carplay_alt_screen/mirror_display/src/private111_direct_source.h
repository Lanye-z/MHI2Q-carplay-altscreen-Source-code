#ifndef PRIVATE111_DIRECT_SOURCE_H
#define PRIVATE111_DIRECT_SOURCE_H

#include "video_frame.h"
#include <stddef.h>
#include <stdint.h>

struct p111_frame_shm;
struct p111_h264_shm;

class Private111DirectSource {
public:
    explicit Private111DirectSource(bool verbose);
    ~Private111DirectSource();

    bool init();
    bool read_frame(VideoFrame *frame);
    void shutdown();

    bool h264_ready() const { return h264_ready_; }
    bool decoded_ready() const { return decoded_ready_; }
    uint32_t generation() const { return generation_; }
    uint32_t h264_packets() const { return last_h264_packets_; }
    uint32_t h264_bytes() const { return last_h264_bytes_; }
    uint32_t decoded_frames() const { return last_frame_count_; }

private:
    Private111DirectSource(const Private111DirectSource &);
    Private111DirectSource &operator=(const Private111DirectSource &);

    bool map_h264();
    bool map_frame();
    void log_h264_progress();
    unsigned long long now_us() const;

    bool verbose_;

    int h264_fd_;
    int frame_fd_;
    p111_h264_shm *h264_;
    p111_frame_shm *frames_;

    unsigned char *local_frame_;
    size_t local_capacity_;

    uint32_t generation_;
    uint32_t last_sequence_;
    uint32_t last_h264_packets_;
    uint32_t last_h264_bytes_;
    uint32_t last_frame_count_;
    uint32_t last_logged_h264_packets_;

    bool h264_ready_;
    bool decoded_ready_;
    bool first_frame_logged_;
};

#endif
