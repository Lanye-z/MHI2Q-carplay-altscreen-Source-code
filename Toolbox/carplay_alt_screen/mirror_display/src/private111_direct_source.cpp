#include "private111_direct_source.h"
#include "private111_direct_shm.h"

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/time.h>
#include <unistd.h>

Private111DirectSource::Private111DirectSource(bool verbose)
    : verbose_(verbose),
      h264_fd_(-1),
      frame_fd_(-1),
      h264_(0),
      frames_(0),
      local_frame_(0),
      local_capacity_(0),
      generation_(0),
      last_sequence_(0),
      last_h264_packets_(0),
      last_h264_bytes_(0),
      last_frame_count_(0),
      last_logged_h264_packets_(0),
      h264_ready_(false),
      decoded_ready_(false),
      first_frame_logged_(false) {
}

Private111DirectSource::~Private111DirectSource() {
    shutdown();
}

unsigned long long Private111DirectSource::now_us() const {
    struct timeval tv;
    if (gettimeofday(&tv, 0) != 0) return 0;
    return (unsigned long long)(unsigned long)tv.tv_sec * 1000000ULL +
           (unsigned long long)(unsigned long)tv.tv_usec;
}

bool Private111DirectSource::map_h264() {
    if (h264_) return true;
    h264_fd_ = shm_open(P111_H264_SHM_NAME, O_RDONLY, 0);
    if (h264_fd_ < 0) return false;

    void *p = mmap(0, sizeof(p111_h264_shm_t), PROT_READ,
                   MAP_SHARED, h264_fd_, 0);
    if (p == MAP_FAILED || !p) {
        close(h264_fd_);
        h264_fd_ = -1;
        return false;
    }
    h264_ = (p111_h264_shm_t *)p;
    if (h264_->magic != P111_H264_SHM_MAGIC ||
        h264_->version != P111_H264_SHM_VERSION) {
        munmap(h264_, sizeof(p111_h264_shm_t));
        h264_ = 0;
        close(h264_fd_);
        h264_fd_ = -1;
        return false;
    }

    fprintf(stderr,
            "direct111: PHASE=H264_SHM_ATTACHED name=%s version=%u ring=%u writer_pid=%u\n",
            P111_H264_SHM_NAME, (unsigned)h264_->version,
            (unsigned)P111_H264_RING_SIZE, (unsigned)h264_->writer_pid);
    return true;
}

bool Private111DirectSource::map_frame() {
    if (frames_) return true;
    frame_fd_ = shm_open(P111_FRAME_SHM_NAME, O_RDONLY, 0);
    if (frame_fd_ < 0) return false;

    void *p = mmap(0, sizeof(p111_frame_shm_t), PROT_READ,
                   MAP_SHARED, frame_fd_, 0);
    if (p == MAP_FAILED || !p) {
        close(frame_fd_);
        frame_fd_ = -1;
        return false;
    }
    frames_ = (p111_frame_shm_t *)p;
    if (frames_->magic != P111_FRAME_SHM_MAGIC ||
        frames_->version != P111_FRAME_SHM_VERSION) {
        munmap(frames_, sizeof(p111_frame_shm_t));
        frames_ = 0;
        close(frame_fd_);
        frame_fd_ = -1;
        return false;
    }

    local_capacity_ = P111_FRAME_SLOT_BYTES;
    local_frame_ = (unsigned char *)malloc(local_capacity_);
    if (!local_frame_) {
        munmap(frames_, sizeof(p111_frame_shm_t));
        frames_ = 0;
        close(frame_fd_);
        frame_fd_ = -1;
        local_capacity_ = 0;
        return false;
    }

    fprintf(stderr,
            "direct111: PHASE=DECODED_SHM_ATTACHED name=%s version=%u slots=%u slot_bytes=%u writer_pid=%u\n",
            P111_FRAME_SHM_NAME, (unsigned)frames_->version,
            (unsigned)P111_FRAME_SLOTS, (unsigned)P111_FRAME_SLOT_BYTES,
            (unsigned)frames_->writer_pid);
    return true;
}

bool Private111DirectSource::init() {
    shutdown();
    fprintf(stderr,
            "direct111: PHASE=SOURCE_INIT mode=private111-direct decoder_backend=stock-omx-tap h264_shm=%s decoded_shm=%s window58_readback=0\n",
            P111_H264_SHM_NAME, P111_FRAME_SHM_NAME);

    /*
     * The writer is created lazily after the phone opens private111, so lack of
     * SHM at process start is expected. read_frame() retries both attachments.
     */
    (void)map_h264();
    (void)map_frame();
    return true;
}

void Private111DirectSource::log_h264_progress() {
    if (!h264_) return;

    const uint32_t packets = h264_->packet_count;
    const uint32_t bytes = h264_->total_bytes;
    last_h264_packets_ = packets;
    last_h264_bytes_ = bytes;

    if (!h264_ready_ && h264_->active &&
        h264_->sps_count && h264_->pps_count && h264_->idr_count) {
        h264_ready_ = true;
        fprintf(stderr,
                "direct111: PHASE=H264_STREAM_VALID generation=%u packets=%u bytes=%u sps=%u pps=%u idr=%u annexb=%u\n",
                (unsigned)h264_->generation, (unsigned)packets,
                (unsigned)bytes, (unsigned)h264_->sps_count,
                (unsigned)h264_->pps_count, (unsigned)h264_->idr_count,
                (unsigned)h264_->annexb_count);
    }

    if (verbose_ && packets &&
        (last_logged_h264_packets_ == 0 ||
         packets - last_logged_h264_packets_ >= 256u)) {
        last_logged_h264_packets_ = packets;
        fprintf(stderr,
                "direct111: PHASE=H264_PROGRESS generation=%u active=%u packets=%u bytes=%u seq=%u wraps=%u drops=%u sps=%u pps=%u idr=%u\n",
                (unsigned)h264_->generation, (unsigned)h264_->active,
                (unsigned)packets, (unsigned)bytes,
                (unsigned)h264_->write_seq, (unsigned)h264_->wrap_count,
                (unsigned)h264_->drop_count, (unsigned)h264_->sps_count,
                (unsigned)h264_->pps_count, (unsigned)h264_->idr_count);
    }
}

bool Private111DirectSource::read_frame(VideoFrame *frame) {
    if (!frame) return false;
    if (!h264_) (void)map_h264();
    if (!frames_) (void)map_frame();

    log_h264_progress();
    if (!frames_ || !local_frame_) return false;
    if (!frames_->active || !frames_->sequence) return false;

    const uint32_t seq1 = frames_->sequence;
    const uint32_t gen = frames_->generation;
    const uint32_t slot = frames_->current_slot;
    const uint32_t width = frames_->width;
    const uint32_t height = frames_->height;
    const uint32_t stride = frames_->stride;
    const uint32_t format = frames_->format;
    const uint32_t bytes = frames_->frame_bytes;

    if (!seq1 || seq1 == last_sequence_) return false;
    if (slot >= P111_FRAME_SLOTS || !width || !height || !stride ||
        format != P111_FRAME_FORMAT_NV12 || !bytes ||
        bytes > P111_FRAME_SLOT_BYTES || bytes > local_capacity_) {
        fprintf(stderr,
                "direct111: ERROR PHASE=DECODED_FRAME_METADATA seq=%u gen=%u slot=%u size=%ux%u stride=%u format=%u bytes=%u\n",
                (unsigned)seq1, (unsigned)gen, (unsigned)slot,
                (unsigned)width, (unsigned)height, (unsigned)stride,
                (unsigned)format, (unsigned)bytes);
        return false;
    }

    const unsigned char *src =
        &frames_->data[(size_t)slot * P111_FRAME_SLOT_BYTES];
    memcpy(local_frame_, src, bytes);
    __sync_synchronize();

    const uint32_t seq2 = frames_->sequence;
    const uint32_t slot2 = frames_->current_slot;
    if (seq1 != seq2 || slot != slot2) {
        if (verbose_) {
            fprintf(stderr,
                    "direct111: PHASE=DECODED_FRAME_RACE retry=1 seq=%u->%u slot=%u->%u\n",
                    (unsigned)seq1, (unsigned)seq2,
                    (unsigned)slot, (unsigned)slot2);
        }
        return false;
    }

    if (generation_ != gen) {
        generation_ = gen;
        last_sequence_ = 0;
        decoded_ready_ = false;
        first_frame_logged_ = false;
        fprintf(stderr,
                "direct111: PHASE=SOURCE_GENERATION generation=%u stream_cookie=0x%08x decoder_backend=stock-omx-tap\n",
                (unsigned)gen, (unsigned)frames_->stream_cookie);
    }

    last_sequence_ = seq1;
    last_frame_count_ = frames_->frame_count;

    frame->data = local_frame_;
    frame->width = (int)width;
    frame->height = (int)height;
    frame->stride = (int)stride;
    frame->format = PIXEL_FORMAT_NV12;
    frame->timestamp_us = now_us();

    if (!first_frame_logged_) {
        first_frame_logged_ = true;
        decoded_ready_ = true;
        fprintf(stderr,
                "direct111: PHASE=DECODER_FIRST_FRAME backend=stock-omx-tap generation=%u seq=%u size=%ux%u stride=%u bytes=%u H264_VALID=%s\n",
                (unsigned)gen, (unsigned)seq1, (unsigned)width,
                (unsigned)height, (unsigned)stride, (unsigned)bytes,
                h264_ready_ ? "YES" : "NOT_YET");
    }

    return true;
}

void Private111DirectSource::shutdown() {
    if (h264_) {
        munmap(h264_, sizeof(p111_h264_shm_t));
        h264_ = 0;
    }
    if (frames_) {
        munmap(frames_, sizeof(p111_frame_shm_t));
        frames_ = 0;
    }
    if (h264_fd_ >= 0) {
        close(h264_fd_);
        h264_fd_ = -1;
    }
    if (frame_fd_ >= 0) {
        close(frame_fd_);
        frame_fd_ = -1;
    }
    if (local_frame_) {
        free(local_frame_);
        local_frame_ = 0;
    }
    local_capacity_ = 0;
    generation_ = 0;
    last_sequence_ = 0;
    last_h264_packets_ = 0;
    last_h264_bytes_ = 0;
    last_frame_count_ = 0;
    last_logged_h264_packets_ = 0;
    h264_ready_ = false;
    decoded_ready_ = false;
    first_frame_logged_ = false;
}
