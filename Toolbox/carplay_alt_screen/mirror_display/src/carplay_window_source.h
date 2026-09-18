#ifndef CARPLAY_WINDOW_SOURCE_H
#define CARPLAY_WINDOW_SOURCE_H

#include "video_frame.h"

class CarPlayWindowSource {
public:
    CarPlayWindowSource(int window_id, bool verbose);
    ~CarPlayWindowSource();

    bool init();
    bool read_frame(VideoFrame *frame);
    void shutdown();

    bool has_window() const { return window_ != 0; }
    int width() const { return width_; }
    int height() const { return height_; }
    int stride() const { return stride_; }
    bool pixel_valid() const { return pixel_valid_; }
    bool pixel_changed() const { return pixel_changed_; }
    unsigned pixel_nonblack_permille() const { return pixel_nonblack_permille_; }
    unsigned long pixel_hash() const { return pixel_hash_; }
    unsigned long pixel_probe_count() const { return pixel_probe_count_; }

private:
    bool open_api();
    bool pump_event(unsigned long long timeout_ns);
    bool create_capture_buffer();
    void release_capture_buffer();
    void probe_pixels();
    void release_target_window(const char *reason);
    void release_event_window(void *window, const char *reason);
    unsigned long long now_us() const;

    int target_id_;
    bool verbose_;
    void *lib_;
    void *ctx_;
    void *event_;
    void *window_;
    void *pixmap_;
    void *buffer_;
    unsigned char *pixels_;
    int width_;
    int height_;
    int stride_;
    bool target_posted_;
    unsigned event_count_;
    unsigned read_failures_;
    bool pixel_valid_;
    bool pixel_changed_;
    unsigned pixel_nonblack_permille_;
    unsigned long pixel_hash_;
    unsigned long previous_pixel_hash_;
    unsigned long pixel_probe_count_;

    typedef int (*create_context_fn)(void **, int);
    typedef int (*destroy_context_fn)(void *);
    typedef int (*create_event_fn)(void **);
    typedef int (*destroy_event_fn)(void *);
    typedef int (*get_event_fn)(void *, void *, unsigned long long);
    typedef int (*get_event_iv_fn)(void *, int, int *);
    typedef int (*get_event_pv_fn)(void *, int, void **);
    typedef int (*get_window_iv_fn)(void *, int, int *);
    typedef int (*get_window_cv_fn)(void *, int, int, char *);
    typedef int (*destroy_window_fn)(void *);
    typedef int (*create_pixmap_fn)(void **, void *);
    typedef int (*destroy_pixmap_fn)(void *);
    typedef int (*set_pixmap_iv_fn)(void *, int, const int *);
    typedef int (*create_pixmap_buffer_fn)(void *);
    typedef int (*get_pixmap_pv_fn)(void *, int, void **);
    typedef int (*get_buffer_pv_fn)(void *, int, void **);
    typedef int (*get_buffer_iv_fn)(void *, int, int *);
    typedef int (*read_window_fn)(void *, void *, int, const int *, int);

    create_context_fn create_context_;
    destroy_context_fn destroy_context_;
    create_event_fn create_event_;
    destroy_event_fn destroy_event_;
    get_event_fn get_event_;
    get_event_iv_fn get_event_iv_;
    get_event_pv_fn get_event_pv_;
    get_window_iv_fn get_window_iv_;
    get_window_cv_fn get_window_cv_;
    destroy_window_fn destroy_window_;
    create_pixmap_fn create_pixmap_;
    destroy_pixmap_fn destroy_pixmap_;
    set_pixmap_iv_fn set_pixmap_iv_;
    create_pixmap_buffer_fn create_pixmap_buffer_;
    get_pixmap_pv_fn get_pixmap_pv_;
    get_buffer_pv_fn get_buffer_pv_;
    get_buffer_iv_fn get_buffer_iv_;
    read_window_fn read_window_;
};

#endif
