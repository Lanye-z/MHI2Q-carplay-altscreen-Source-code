#include "private111_direct_tap.h"
#include "private111_direct_shm.h"

#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

extern void altscreen_log(const char *fmt, ...);

static p111_h264_shm_t *g_h264;
static p111_frame_shm_t *g_frame;
static int g_h264_fd = -1;
static int g_frame_fd = -1;
static volatile unsigned g_tap_lock;
static void *g_stream;
static uint32_t g_generation;
static int g_h264_map_failed;
static int g_frame_map_failed;
static int g_seen_h264;
static int g_seen_frame;
static int g_seen_sps;
static int g_seen_pps;
static int g_seen_idr;

static void tap_lock(void) {
    while (__sync_lock_test_and_set(&g_tap_lock, 1u) != 0u) { }
}

static void tap_unlock(void) {
    __sync_lock_release(&g_tap_lock);
}

static uint32_t stream_cookie(void *stream) {
    return (uint32_t)(uintptr_t)stream;
}

static int env_truth(const char *name, int default_value) {
    const char *v = getenv(name);
    if (!v || !*v) return default_value;
    if (!strcmp(v, "0") || !strcmp(v, "NO") || !strcmp(v, "no") ||
        !strcmp(v, "false") || !strcmp(v, "FALSE"))
        return 0;
    return 1;
}

static p111_h264_shm_t *map_h264(void) {
    void *p;
    if (g_h264) return g_h264;
    if (g_h264_map_failed) return NULL;

    g_h264_fd = shm_open(P111_H264_SHM_NAME, O_RDWR | O_CREAT, 0666);
    if (g_h264_fd < 0) {
        g_h264_map_failed = 1;
        altscreen_log("ERROR PHASE=H264_TAP_SHM_OPEN name=%s result=FAILED",
                      P111_H264_SHM_NAME);
        return NULL;
    }
    if (ftruncate(g_h264_fd, (off_t)sizeof(p111_h264_shm_t)) != 0) {
        g_h264_map_failed = 1;
        altscreen_log("ERROR PHASE=H264_TAP_SHM_SIZE name=%s bytes=%u result=FAILED",
                      P111_H264_SHM_NAME, (unsigned)sizeof(p111_h264_shm_t));
        return NULL;
    }
    p = mmap(NULL, sizeof(p111_h264_shm_t), PROT_READ | PROT_WRITE,
             MAP_SHARED, g_h264_fd, 0);
    if (p == MAP_FAILED || !p) {
        g_h264_map_failed = 1;
        altscreen_log("ERROR PHASE=H264_TAP_SHM_MAP name=%s result=FAILED",
                      P111_H264_SHM_NAME);
        return NULL;
    }
    g_h264 = (p111_h264_shm_t *)p;
    if (g_h264->magic != P111_H264_SHM_MAGIC ||
        g_h264->version != P111_H264_SHM_VERSION) {
        memset(g_h264, 0, sizeof(*g_h264));
        g_h264->magic = P111_H264_SHM_MAGIC;
        g_h264->version = P111_H264_SHM_VERSION;
    }
    g_h264->writer_pid = (uint32_t)getpid();
    altscreen_log("PHASE=H264_TAP_SHM_READY name=%s bytes=%u ring=%u writer_pid=%u",
                  P111_H264_SHM_NAME, (unsigned)sizeof(*g_h264),
                  (unsigned)P111_H264_RING_SIZE, (unsigned)g_h264->writer_pid);
    return g_h264;
}

static p111_frame_shm_t *map_frame(void) {
    void *p;
    if (g_frame) return g_frame;
    if (g_frame_map_failed) return NULL;

    g_frame_fd = shm_open(P111_FRAME_SHM_NAME, O_RDWR | O_CREAT, 0666);
    if (g_frame_fd < 0) {
        g_frame_map_failed = 1;
        altscreen_log("ERROR PHASE=FRAME_TAP_SHM_OPEN name=%s result=FAILED",
                      P111_FRAME_SHM_NAME);
        return NULL;
    }
    if (ftruncate(g_frame_fd, (off_t)sizeof(p111_frame_shm_t)) != 0) {
        g_frame_map_failed = 1;
        altscreen_log("ERROR PHASE=FRAME_TAP_SHM_SIZE name=%s bytes=%u result=FAILED",
                      P111_FRAME_SHM_NAME, (unsigned)sizeof(p111_frame_shm_t));
        return NULL;
    }
    p = mmap(NULL, sizeof(p111_frame_shm_t), PROT_READ | PROT_WRITE,
             MAP_SHARED, g_frame_fd, 0);
    if (p == MAP_FAILED || !p) {
        g_frame_map_failed = 1;
        altscreen_log("ERROR PHASE=FRAME_TAP_SHM_MAP name=%s result=FAILED",
                      P111_FRAME_SHM_NAME);
        return NULL;
    }
    g_frame = (p111_frame_shm_t *)p;
    if (g_frame->magic != P111_FRAME_SHM_MAGIC ||
        g_frame->version != P111_FRAME_SHM_VERSION) {
        memset(g_frame, 0, sizeof(*g_frame));
        g_frame->magic = P111_FRAME_SHM_MAGIC;
        g_frame->version = P111_FRAME_SHM_VERSION;
    }
    g_frame->writer_pid = (uint32_t)getpid();
    altscreen_log("PHASE=FRAME_TAP_SHM_READY name=%s bytes=%u slots=%u slot_bytes=%u writer_pid=%u",
                  P111_FRAME_SHM_NAME, (unsigned)sizeof(*g_frame),
                  (unsigned)P111_FRAME_SLOTS, (unsigned)P111_FRAME_SLOT_BYTES,
                  (unsigned)g_frame->writer_pid);
    return g_frame;
}

static void begin_stream_locked(void *stream) {
    const uint32_t cookie = stream_cookie(stream);
    if (g_stream == stream && g_generation) return;

    g_stream = stream;
    ++g_generation;
    if (!g_generation) ++g_generation;
    g_seen_h264 = 0;
    g_seen_frame = 0;
    g_seen_sps = 0;
    g_seen_pps = 0;
    g_seen_idr = 0;

    if (map_h264()) {
        g_h264->active = 0;
        g_h264->generation = g_generation;
        g_h264->stream_cookie = cookie;
        g_h264->write_pos = 0;
        g_h264->write_seq = 0;
        g_h264->total_bytes = 0;
        g_h264->packet_count = 0;
        g_h264->drop_count = 0;
        g_h264->wrap_count = 0;
        g_h264->last_payload_bytes = 0;
        g_h264->sps_count = 0;
        g_h264->pps_count = 0;
        g_h264->idr_count = 0;
        g_h264->annexb_count = 0;
        __sync_synchronize();
        g_h264->active = 1;
    }

    if (env_truth("ALT111_DIRECT_FRAME_TAP", 1) && map_frame()) {
        g_frame->active = 0;
        g_frame->generation = g_generation;
        g_frame->stream_cookie = cookie;
        g_frame->width = 0;
        g_frame->height = 0;
        g_frame->stride = 0;
        g_frame->format = P111_FRAME_FORMAT_NV12;
        g_frame->frame_bytes = 0;
        g_frame->sequence = 0;
        g_frame->current_slot = 0;
        g_frame->frame_count = 0;
        g_frame->drop_count = 0;
        g_frame->last_copy_bytes = 0;
        __sync_synchronize();
        g_frame->active = 1;
    }

    altscreen_log("PHASE=DIRECT111_TAP_ATTACH stream=%p generation=%u cookie=0x%08x h264=%d decoded_fallback=%d stock_forward=1",
                  stream, g_generation, cookie, g_h264 != NULL,
                  g_frame != NULL);
}

static uint32_t scan_annexb_flags(const uint8_t *d, size_t n,
                                  unsigned *sps, unsigned *pps,
                                  unsigned *idr, unsigned *annexb) {
    size_t i;
    uint32_t flags = 0;
    if (sps) *sps = 0;
    if (pps) *pps = 0;
    if (idr) *idr = 0;
    if (annexb) *annexb = 0;
    if (!d || n < 4u) return 0;

    for (i = 0; i + 3u < n; ++i) {
        size_t h = 0;
        uint8_t nal;
        if (i + 4u < n && d[i] == 0 && d[i + 1u] == 0 &&
            d[i + 2u] == 0 && d[i + 3u] == 1) h = i + 4u;
        else if (d[i] == 0 && d[i + 1u] == 0 && d[i + 2u] == 1)
            h = i + 3u;
        if (!h || h >= n) continue;
        flags |= P111_H264_FLAG_ANNEXB;
        if (annexb) ++*annexb;
        nal = (uint8_t)(d[h] & 0x1fu);
        if (nal == 7u) {
            flags |= P111_H264_FLAG_SPS;
            if (sps) ++*sps;
        } else if (nal == 8u) {
            flags |= P111_H264_FLAG_PPS;
            if (pps) ++*pps;
        } else if (nal == 5u) {
            flags |= P111_H264_FLAG_IDR;
            if (idr) ++*idr;
        }
        i = h;
    }
    return flags;
}

void p111_h264_tap_write(void *stream, const void *data, size_t bytes) {
    p111_h264_record_t rec;
    uint32_t need, pos, flags;
    unsigned sps = 0, pps = 0, idr = 0, annexb = 0;

    if (!stream || !data || !bytes) return;
    tap_lock();
    begin_stream_locked(stream);
    if (!g_h264 || !g_h264->active) {
        tap_unlock();
        return;
    }

    if (bytes > (size_t)(P111_H264_RING_SIZE - sizeof(rec))) {
        ++g_h264->drop_count;
        tap_unlock();
        return;
    }

    flags = scan_annexb_flags((const uint8_t *)data, bytes,
                              &sps, &pps, &idr, &annexb);
    g_h264->sps_count += sps;
    g_h264->pps_count += pps;
    g_h264->idr_count += idr;
    g_h264->annexb_count += annexb;

    rec.magic = P111_H264_RECORD_MAGIC;
    rec.sequence = g_h264->write_seq + 1u;
    rec.payload_bytes = (uint32_t)bytes;
    rec.flags = flags;

    need = (uint32_t)sizeof(rec) + (uint32_t)bytes;
    pos = g_h264->write_pos;
    if (pos > P111_H264_RING_SIZE || need > P111_H264_RING_SIZE - pos) {
        if (P111_H264_RING_SIZE - pos >= sizeof(rec)) {
            p111_h264_record_t wrap;
            memset(&wrap, 0, sizeof(wrap));
            wrap.magic = P111_H264_RECORD_MAGIC;
            wrap.sequence = rec.sequence;
            wrap.flags = P111_H264_FLAG_WRAP;
            memcpy(&g_h264->ring[pos], &wrap, sizeof(wrap));
        }
        pos = 0;
        ++g_h264->wrap_count;
    }

    memcpy(&g_h264->ring[pos], &rec, sizeof(rec));
    memcpy(&g_h264->ring[pos + sizeof(rec)], data, bytes);
    __sync_synchronize();
    g_h264->write_pos = pos + need;
    g_h264->write_seq = rec.sequence;
    g_h264->last_payload_bytes = (uint32_t)bytes;
    g_h264->total_bytes += (uint32_t)bytes;
    ++g_h264->packet_count;

    if (!g_seen_h264) {
        g_seen_h264 = 1;
        altscreen_log("PHASE=H264_TAP_FIRST_DATA stream=%p generation=%u bytes=%u flags=0x%x",
                      stream, g_generation, (unsigned)bytes, (unsigned)flags);
    }
    if (sps && !g_seen_sps) {
        g_seen_sps = 1;
        altscreen_log("PHASE=H264_TAP_FIRST_SPS stream=%p generation=%u seq=%u",
                      stream, g_generation, rec.sequence);
    }
    if (pps && !g_seen_pps) {
        g_seen_pps = 1;
        altscreen_log("PHASE=H264_TAP_FIRST_PPS stream=%p generation=%u seq=%u",
                      stream, g_generation, rec.sequence);
    }
    if (idr && !g_seen_idr) {
        g_seen_idr = 1;
        altscreen_log("PHASE=H264_TAP_FIRST_IDR stream=%p generation=%u seq=%u H264_STREAM_VALID=%s",
                      stream, g_generation, rec.sequence,
                      (g_seen_sps && g_seen_pps) ? "YES" : "WAITING_CONFIG");
    }
    if ((g_h264->packet_count & 255u) == 0u) {
        altscreen_log("PHASE=H264_TAP_PROGRESS stream=%p generation=%u packets=%u bytes=%u seq=%u wraps=%u drops=%u sps=%u pps=%u idr=%u",
                      stream, g_generation, g_h264->packet_count,
                      g_h264->total_bytes, g_h264->write_seq,
                      g_h264->wrap_count, g_h264->drop_count,
                      g_h264->sps_count, g_h264->pps_count,
                      g_h264->idr_count);
    }

    tap_unlock();
}

void p111_frame_tap_write(void *stream, const unsigned char *buffer,
                          uint32_t width, uint32_t height) {
    uint64_t bytes64;
    uint32_t bytes, slot, seq;
    unsigned char *dst;

    if (!stream || !buffer || !width || !height) return;
    if (!env_truth("ALT111_DIRECT_FRAME_TAP", 1)) return;

    bytes64 = (uint64_t)width * (uint64_t)height * 3u / 2u;
    if (!bytes64 || bytes64 > P111_FRAME_SLOT_BYTES) {
        tap_lock();
        begin_stream_locked(stream);
        if (g_frame) ++g_frame->drop_count;
        tap_unlock();
        return;
    }
    bytes = (uint32_t)bytes64;

    tap_lock();
    begin_stream_locked(stream);
    if (!g_frame || !g_frame->active) {
        tap_unlock();
        return;
    }

    seq = g_frame->sequence + 1u;
    slot = seq % P111_FRAME_SLOTS;
    dst = &g_frame->data[(size_t)slot * P111_FRAME_SLOT_BYTES];

    /*
     * Measured stock CScreenRender config uses NV12 buffers.  This copy is an
     * explicitly-labelled fallback/diagnostic backend; it never changes or
     * consumes the stock buffer and the real renderer is still called.
     */
    memcpy(dst, buffer, bytes);
    __sync_synchronize();
    g_frame->width = width;
    g_frame->height = height;
    g_frame->stride = width;
    g_frame->format = P111_FRAME_FORMAT_NV12;
    g_frame->frame_bytes = bytes;
    g_frame->current_slot = slot;
    g_frame->last_copy_bytes = bytes;
    g_frame->sequence = seq;
    ++g_frame->frame_count;

    if (!g_seen_frame) {
        g_seen_frame = 1;
        altscreen_log("PHASE=DECODER_FIRST_FRAME backend=stock-omx-tap stream=%p generation=%u seq=%u format=NV12 size=%ux%u bytes=%u window58_readback=0",
                      stream, g_generation, seq, width, height, bytes);
    } else if ((g_frame->frame_count % 300u) == 0u) {
        altscreen_log("PHASE=DECODER_PROGRESS backend=stock-omx-tap stream=%p generation=%u frames=%u seq=%u size=%ux%u drops=%u",
                      stream, g_generation, g_frame->frame_count, seq,
                      width, height, g_frame->drop_count);
    }

    tap_unlock();
}

void p111_direct_tap_stream_end(void *stream) {
    tap_lock();
    if (!stream || g_stream == stream) {
        if (g_h264) {
            __sync_synchronize();
            g_h264->active = 0;
        }
        if (g_frame) {
            __sync_synchronize();
            g_frame->active = 0;
        }
        altscreen_log("PHASE=DIRECT111_TAP_STOP stream=%p generation=%u h264_packets=%u decoded_frames=%u",
                      stream, g_generation,
                      g_h264 ? g_h264->packet_count : 0u,
                      g_frame ? g_frame->frame_count : 0u);
        g_stream = NULL;
    }
    tap_unlock();
}
