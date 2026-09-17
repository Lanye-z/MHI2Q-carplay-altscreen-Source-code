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
private:
    bool open_api();
    bool find_window();
    bool create_capture_buffer();
    void release_capture_buffer();
    unsigned long long now_us() const;
    bool should_log_scan() const;
    int target_id_; bool verbose_; void *lib_; void *ctx_; void *window_; void *pixmap_; void *buffer_; unsigned char *pixels_;
    int width_, height_, stride_;
    unsigned scan_attempts_, read_failures_;
    typedef int (*create_context_fn)(void **,int); typedef int (*destroy_context_fn)(void *);
    typedef int (*get_context_iv_fn)(void *,int,int *); typedef int (*get_context_pv_fn)(void *,int,void **);
    typedef int (*get_window_iv_fn)(void *,int,int *); typedef int (*create_pixmap_fn)(void **,void *); typedef int (*destroy_pixmap_fn)(void *);
    typedef int (*set_pixmap_iv_fn)(void *,int,const int *); typedef int (*create_pixmap_buffer_fn)(void *); typedef int (*get_pixmap_pv_fn)(void *,int,void **);
    typedef int (*get_buffer_pv_fn)(void *,int,void **); typedef int (*get_buffer_iv_fn)(void *,int,int *); typedef int (*read_window_fn)(void *,void *,int,const int *,int);
    create_context_fn create_context_; destroy_context_fn destroy_context_; get_context_iv_fn get_context_iv_; get_context_pv_fn get_context_pv_;
    get_window_iv_fn get_window_iv_; create_pixmap_fn create_pixmap_; destroy_pixmap_fn destroy_pixmap_; set_pixmap_iv_fn set_pixmap_iv_;
    create_pixmap_buffer_fn create_pixmap_buffer_; get_pixmap_pv_fn get_pixmap_pv_; get_buffer_pv_fn get_buffer_pv_; get_buffer_iv_fn get_buffer_iv_; read_window_fn read_window_;
};
#endif
