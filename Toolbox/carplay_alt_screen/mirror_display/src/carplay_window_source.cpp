#include "carplay_window_source.h"

#include <dlfcn.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <sys/time.h>

/*
 * QNX Screen values used on the MHI2Q/QNX 6.5 target.
 *
 * V3 incorrectly treated SCREEN_PROPERTY_WINDOW_COUNT/WINDOWS as a global
 * census. QNX defines those properties as the windows associated with the
 * calling context. V4 therefore uses the window-manager event queue instead:
 * CREATE tracks Window58, POST proves it has content, PROPERTY refreshes
 * geometry, and CLOSE releases the locally tracked handle.
 */
#define SCREEN_WINDOW_MANAGER_CONTEXT 1

#define SCREEN_EVENT_NONE 0
#define SCREEN_EVENT_CREATE 1
#define SCREEN_EVENT_PROPERTY 2
#define SCREEN_EVENT_CLOSE 3
#define SCREEN_EVENT_POST 9

#define SCREEN_PROPERTY_BUFFER_SIZE 5
#define SCREEN_PROPERTY_ID_STRING 20
#define SCREEN_PROPERTY_FORMAT 14
#define SCREEN_PROPERTY_POINTER 34
#define SCREEN_PROPERTY_RENDER_BUFFERS 37
#define SCREEN_PROPERTY_SIZE 40
#define SCREEN_PROPERTY_STRIDE 44
#define SCREEN_PROPERTY_TYPE 47
#define SCREEN_PROPERTY_USAGE 48
#define SCREEN_PROPERTY_WINDOW 52
#define SCREEN_PROPERTY_ID 87

#define SCREEN_FORMAT_RGBA8888 8
#define SCREEN_USAGE_READ (1 << 1)
#define SCREEN_USAGE_NATIVE (1 << 3)

CarPlayWindowSource::CarPlayWindowSource(int window_id, bool verbose)
    : target_id_(window_id),
      verbose_(verbose),
      lib_(0),
      ctx_(0),
      event_(0),
      window_(0),
      pixmap_(0),
      buffer_(0),
      pixels_(0),
      width_(0),
      height_(0),
      stride_(0),
      target_posted_(false),
      event_count_(0),
      read_failures_(0),
      create_context_(0),
      destroy_context_(0),
      create_event_(0),
      destroy_event_(0),
      get_event_(0),
      get_event_iv_(0),
      get_event_pv_(0),
      get_window_iv_(0),
      get_window_cv_(0),
      destroy_window_(0),
      create_pixmap_(0),
      destroy_pixmap_(0),
      set_pixmap_iv_(0),
      create_pixmap_buffer_(0),
      get_pixmap_pv_(0),
      get_buffer_pv_(0),
      get_buffer_iv_(0),
      read_window_(0) {
}

CarPlayWindowSource::~CarPlayWindowSource() {
    shutdown();
}

unsigned long long CarPlayWindowSource::now_us() const {
    struct timeval tv;
    if (gettimeofday(&tv, 0) != 0) return 0;
    return (unsigned long long)(unsigned long)tv.tv_sec * 1000000ULL +
           (unsigned long long)(unsigned long)tv.tv_usec;
}

bool CarPlayWindowSource::open_api() {
    lib_ = dlopen("libscreen.so.1", RTLD_LAZY);
    if (!lib_) lib_ = dlopen("libscreen.so", RTLD_LAZY);
    if (!lib_) {
        fprintf(stderr, "source: cannot load libscreen\n");
        return false;
    }

    create_context_ =
        (create_context_fn)dlsym(lib_, "screen_create_context");
    destroy_context_ =
        (destroy_context_fn)dlsym(lib_, "screen_destroy_context");
    create_event_ =
        (create_event_fn)dlsym(lib_, "screen_create_event");
    destroy_event_ =
        (destroy_event_fn)dlsym(lib_, "screen_destroy_event");
    get_event_ =
        (get_event_fn)dlsym(lib_, "screen_get_event");
    get_event_iv_ =
        (get_event_iv_fn)dlsym(lib_, "screen_get_event_property_iv");
    get_event_pv_ =
        (get_event_pv_fn)dlsym(lib_, "screen_get_event_property_pv");
    get_window_iv_ =
        (get_window_iv_fn)dlsym(lib_, "screen_get_window_property_iv");
    get_window_cv_ =
        (get_window_cv_fn)dlsym(lib_, "screen_get_window_property_cv");
    destroy_window_ =
        (destroy_window_fn)dlsym(lib_, "screen_destroy_window");
    create_pixmap_ =
        (create_pixmap_fn)dlsym(lib_, "screen_create_pixmap");
    destroy_pixmap_ =
        (destroy_pixmap_fn)dlsym(lib_, "screen_destroy_pixmap");
    set_pixmap_iv_ =
        (set_pixmap_iv_fn)dlsym(lib_, "screen_set_pixmap_property_iv");
    create_pixmap_buffer_ =
        (create_pixmap_buffer_fn)dlsym(lib_, "screen_create_pixmap_buffer");
    get_pixmap_pv_ =
        (get_pixmap_pv_fn)dlsym(lib_, "screen_get_pixmap_property_pv");
    get_buffer_pv_ =
        (get_buffer_pv_fn)dlsym(lib_, "screen_get_buffer_property_pv");
    get_buffer_iv_ =
        (get_buffer_iv_fn)dlsym(lib_, "screen_get_buffer_property_iv");
    read_window_ =
        (read_window_fn)dlsym(lib_, "screen_read_window");

    if (!create_context_ || !destroy_context_ ||
        !create_event_ || !destroy_event_ || !get_event_ ||
        !get_event_iv_ || !get_event_pv_ ||
        !get_window_iv_ || !destroy_window_ ||
        !create_pixmap_ || !destroy_pixmap_ || !set_pixmap_iv_ ||
        !create_pixmap_buffer_ || !get_pixmap_pv_ ||
        !get_buffer_pv_ || !get_buffer_iv_ || !read_window_) {
        fprintf(stderr,
                "source: required Screen API missing "
                "ctx_create=%p ctx_destroy=%p event_create=%p "
                "event_destroy=%p get_event=%p event_iv=%p event_pv=%p "
                "win_iv=%p win_cv=%p win_destroy=%p pixmap=%p pixbuf=%p "
                "read_window=%p\n",
                (void *)create_context_,
                (void *)destroy_context_,
                (void *)create_event_,
                (void *)destroy_event_,
                (void *)get_event_,
                (void *)get_event_iv_,
                (void *)get_event_pv_,
                (void *)get_window_iv_,
                (void *)get_window_cv_,
                (void *)destroy_window_,
                (void *)create_pixmap_,
                (void *)create_pixmap_buffer_,
                (void *)read_window_);
        return false;
    }
    if (!get_window_cv_) {
        fprintf(stderr,
                "source: WARN screen_get_window_property_cv unavailable; "
                "Window58 identity will use numeric fallback only\n");
    }
    return true;
}

bool CarPlayWindowSource::init() {
    shutdown();
    if (!open_api()) return false;

    /*
     * This privileged context is intentionally created only after the main
     * process has observed PHONE_REQUEST_111. There is no DISPLAY_MANAGER
     * fallback here: the V4 acquisition contract is specifically the
     * window-manager event queue, not a context inventory.
     */
    errno = 0;
    if (create_context_(&ctx_, SCREEN_WINDOW_MANAGER_CONTEXT) != 0 || !ctx_) {
        fprintf(stderr,
                "source: WINDOW_MANAGER_CONTEXT create failed errno=%d\n",
                errno);
        shutdown();
        return false;
    }

    errno = 0;
    if (create_event_(&event_) != 0 || !event_) {
        fprintf(stderr, "source: screen_create_event failed errno=%d\n", errno);
        shutdown();
        return false;
    }

    event_count_ = 0;
    read_failures_ = 0;
    target_posted_ = false;
    fprintf(stderr,
            "source: WINDOW_MANAGER_CONTEXT event observer ready "
            "target_id=%d\n",
            target_id_);
    return true;
}

void CarPlayWindowSource::release_capture_buffer() {
    pixels_ = 0;
    buffer_ = 0;
    stride_ = 0;
    if (pixmap_ && destroy_pixmap_) {
        (void)destroy_pixmap_(pixmap_);
    }
    pixmap_ = 0;
}

void CarPlayWindowSource::release_event_window(void *window,
                                                const char *reason) {
    if (!window || !destroy_window_) return;
    errno = 0;
    if (destroy_window_(window) != 0 && verbose_) {
        fprintf(stderr,
                "source: screen_destroy_window handle=%p reason=%s "
                "failed errno=%d\n",
                window,
                reason ? reason : "-",
                errno);
    }
}

void CarPlayWindowSource::release_target_window(const char *reason) {
    void *tracked = window_;

    release_capture_buffer();
    window_ = 0;
    width_ = 0;
    height_ = 0;
    target_posted_ = false;

    if (tracked) {
        fprintf(stderr,
                "source: release CarPlay window id=%d handle=%p reason=%s\n",
                target_id_,
                tracked,
                reason ? reason : "-");
        release_event_window(tracked, reason);
    }
}

bool CarPlayWindowSource::create_capture_buffer() {
    if (!window_ || !target_posted_ || width_ <= 0 || height_ <= 0) {
        return false;
    }

    release_capture_buffer();

    errno = 0;
    if (create_pixmap_(&pixmap_, ctx_) != 0 || !pixmap_) {
        fprintf(stderr, "source: screen_create_pixmap failed errno=%d\n", errno);
        return false;
    }

    const int usage = SCREEN_USAGE_READ | SCREEN_USAGE_NATIVE;
    const int format = SCREEN_FORMAT_RGBA8888;
    int size[2] = {width_, height_};

    if (set_pixmap_iv_(pixmap_, SCREEN_PROPERTY_USAGE, &usage) != 0 ||
        set_pixmap_iv_(pixmap_, SCREEN_PROPERTY_FORMAT, &format) != 0 ||
        set_pixmap_iv_(pixmap_, SCREEN_PROPERTY_BUFFER_SIZE, size) != 0 ||
        create_pixmap_buffer_(pixmap_) != 0 ||
        get_pixmap_pv_(pixmap_, SCREEN_PROPERTY_RENDER_BUFFERS, &buffer_) != 0 ||
        !buffer_ ||
        get_buffer_pv_(buffer_, SCREEN_PROPERTY_POINTER,
                       (void **)&pixels_) != 0 ||
        !pixels_ ||
        get_buffer_iv_(buffer_, SCREEN_PROPERTY_STRIDE, &stride_) != 0 ||
        stride_ < width_ * 4) {
        fprintf(stderr,
                "source: capture pixmap setup failed size=%dx%d stride=%d "
                "errno=%d\n",
                width_,
                height_,
                stride_,
                errno);
        release_capture_buffer();
        return false;
    }

    /*
     * The vehicle-tested Mirror baseline requests Screen format value 8 but
     * interprets the CPU-visible bytes as BGRA8888. Preserve that byte order
     * contract so the existing GLES renderer performs the same R/B swap.
     */
    fprintf(stderr,
            "source: capture buffer ready id=%d size=%dx%d stride=%d "
            "screen_format=8 cpu_format=BGRA8888 event_driven=1\n",
            target_id_,
            width_,
            height_,
            stride_);
    return true;
}

bool CarPlayWindowSource::pump_event(unsigned long long timeout_ns) {
    if (!ctx_ || !event_) return false;

    errno = 0;
    const int event_rc = get_event_(ctx_, event_, timeout_ns);
    const int event_errno = errno;
    if (event_rc != 0) {
        if (verbose_) {
            fprintf(stderr,
                    "source: screen_get_event failed rc=%d errno=%d "
                    "timeout_ns=%llu\n",
                    event_rc,
                    event_errno,
                    timeout_ns);
        }
        return false;
    }

    int type = SCREEN_EVENT_NONE;
    errno = 0;
    const int type_rc =
        get_event_iv_(event_, SCREEN_PROPERTY_TYPE, &type);
    const int type_errno = errno;
    if (type_rc != 0) {
        fprintf(stderr,
                "source: event type read failed rc=%d errno=%d\n",
                type_rc,
                type_errno);
        return false;
    }
    if (type == SCREEN_EVENT_NONE) return false;

    ++event_count_;

    if (type != SCREEN_EVENT_CREATE &&
        type != SCREEN_EVENT_PROPERTY &&
        type != SCREEN_EVENT_CLOSE &&
        type != SCREEN_EVENT_POST) {
        if (verbose_ && event_count_ <= 16u) {
            fprintf(stderr,
                    "source: event ignored seq=%u type=%d\n",
                    event_count_,
                    type);
        }
        return true;
    }

    void *event_window = 0;
    errno = 0;
    const int window_rc =
        get_event_pv_(event_, SCREEN_PROPERTY_WINDOW, &event_window);
    const int window_errno = errno;
    if (window_rc != 0 || !event_window) {
        if (verbose_ || type == SCREEN_EVENT_CREATE) {
            fprintf(stderr,
                    "source: event window read seq=%u type=%d rc=%d "
                    "handle=%p errno=%d\n",
                    event_count_,
                    type,
                    window_rc,
                    event_window,
                    window_errno);
        }
        return true;
    }

    int numeric_id = -1;
    char id_string[64];
    char target_string[24];
    int size[2] = {0, 0};
    memset(id_string, 0, sizeof(id_string));
    memset(target_string, 0, sizeof(target_string));
    (void)snprintf(target_string, sizeof(target_string), "%d", target_id_);

    errno = 0;
    const int id_rc =
        get_window_iv_(event_window, SCREEN_PROPERTY_ID, &numeric_id);
    const int id_errno = errno;

    int id_string_rc = -1;
    int id_string_errno = 0;
    if (get_window_cv_) {
        errno = 0;
        id_string_rc = get_window_cv_(
            event_window, SCREEN_PROPERTY_ID_STRING,
            (int)sizeof(id_string) - 1, id_string);
        id_string_errno = errno;
    }

    errno = 0;
    const int size_rc =
        get_window_iv_(event_window, SCREEN_PROPERTY_SIZE, size);
    const int size_errno = errno;

    const bool string_match =
        id_string_rc == 0 && strcmp(id_string, target_string) == 0;
    const bool numeric_fallback =
        !string_match && id_string_rc != 0 &&
        id_rc == 0 && numeric_id == target_id_;
    const bool target = string_match || numeric_fallback;
    const char *match_basis =
        string_match ? "STRING" : (numeric_fallback ? "NUMERIC_FALLBACK" : "NO");

    if (target || (verbose_ && event_count_ <= 24u)) {
        fprintf(stderr,
                "source: event seq=%u type=%d handle=%p "
                "numeric_id_rc=%d numeric_id=%d numeric_id_errno=%d "
                "id_string_rc=%d id_string='%s' id_string_errno=%d "
                "size_rc=%d size=%dx%d size_errno=%d "
                "target=%s match=%s id_string_property=20%s\n",
                event_count_,
                type,
                event_window,
                id_rc,
                numeric_id,
                id_errno,
                id_string_rc,
                id_string,
                id_string_errno,
                size_rc,
                size[0],
                size[1],
                size_errno,
                target ? "YES" : "NO",
                match_basis,
                target ? " [target]" : "");
    }

    if (!target) {
        /*
         * SCREEN_PROPERTY_WINDOW allocates local tracking resources for this
         * event handle. We are an observer, so release every non-target handle
         * immediately instead of accumulating manager-side references.
         */
        release_event_window(event_window, "non-target-event");
        return true;
    }

    if (type == SCREEN_EVENT_CLOSE) {
        fprintf(stderr,
                "source: target CLOSE id=%d event_seq=%u handle=%p\n",
                target_id_,
                event_count_,
                event_window);

        if (event_window == window_) {
            release_capture_buffer();
            window_ = 0;
            width_ = 0;
            height_ = 0;
            target_posted_ = false;
            release_event_window(event_window, "target-close");
        } else {
            release_event_window(event_window, "target-close-event");
            release_target_window("target-close");
        }
        return true;
    }

    if (!window_ || (type == SCREEN_EVENT_CREATE && event_window != window_)) {
        if (window_ && event_window != window_) {
            release_target_window("replacement-create");
        }
        window_ = event_window;
        event_window = 0;
        target_posted_ = false;
        fprintf(stderr,
                "source: bound CarPlay window id=%d handle=%p "
                "source_event=%d event_seq=%u\n",
                target_id_,
                window_,
                type,
                event_count_);
    } else if (event_window != window_) {
        release_event_window(event_window, "duplicate-target-event");
        event_window = 0;
    }

    if (size_rc == 0 && size[0] > 0 && size[1] > 0 &&
        (width_ != size[0] || height_ != size[1])) {
        if (pixmap_) release_capture_buffer();
        width_ = size[0];
        height_ = size[1];
        fprintf(stderr,
                "source: target geometry id=%d size=%dx%d "
                "event=%d event_seq=%u\n",
                target_id_,
                width_,
                height_,
                type,
                event_count_);
    }

    if (type == SCREEN_EVENT_CREATE) {
        fprintf(stderr,
                "source: target CREATE id=%d waiting_for_first_post=1 "
                "event_seq=%u\n",
                target_id_,
                event_count_);
        return true;
    }

    if (type == SCREEN_EVENT_POST) {
        if (!target_posted_) {
            fprintf(stderr,
                    "source: target FIRST_POST id=%d event_seq=%u "
                    "content_valid=1\n",
                    target_id_,
                    event_count_);
        }
        target_posted_ = true;
    }

    if (target_posted_ && !pixmap_ && width_ > 0 && height_ > 0) {
        (void)create_capture_buffer();
    }

    return true;
}

bool CarPlayWindowSource::read_frame(VideoFrame *frame) {
    if (!frame || !ctx_ || !event_) return false;

    /*
     * Before the first valid POST, wait on the event queue rather than polling
     * context properties. Once active, drain a bounded number of queued events
     * non-blocking each frame so CLOSE/PROPERTY cannot starve behind POSTs.
     */
    if (!window_ || !target_posted_ || !pixmap_) {
        (void)pump_event(100000000ULL);
        for (unsigned i = 0; i < 31u; ++i) {
            if (!pump_event(0)) break;
        }
        if (!window_ || !target_posted_ || !pixmap_) return false;
    } else {
        for (unsigned i = 0; i < 8u; ++i) {
            if (!pump_event(0)) break;
            if (!window_ || !target_posted_ || !pixmap_) return false;
        }
    }

    errno = 0;
    if (read_window_(window_, buffer_, 0, 0, 0) != 0) {
        ++read_failures_;
        if (read_failures_ == 1u ||
            (verbose_ && (read_failures_ % 30u) == 0u)) {
            fprintf(stderr,
                    "source: screen_read_window id=%d handle=%p failed "
                    "errno=%d failures=%u; keeping event binding\n",
                    target_id_,
                    window_,
                    errno,
                    read_failures_);
        }
        return false;
    }

    if (read_failures_) {
        fprintf(stderr,
                "source: screen_read_window recovered id=%d "
                "after_failures=%u\n",
                target_id_,
                read_failures_);
        read_failures_ = 0;
    }

    frame->data = pixels_;
    frame->width = width_;
    frame->height = height_;
    frame->stride = stride_;
    frame->format = PIXEL_FORMAT_BGRA8888;
    frame->timestamp_us = now_us();
    return true;
}

void CarPlayWindowSource::shutdown() {
    release_target_window("shutdown");

    if (event_ && destroy_event_) {
        (void)destroy_event_(event_);
    }
    event_ = 0;

    if (ctx_ && destroy_context_) {
        (void)destroy_context_(ctx_);
    }
    ctx_ = 0;

    if (lib_) dlclose(lib_);
    lib_ = 0;

    create_context_ = 0;
    destroy_context_ = 0;
    create_event_ = 0;
    destroy_event_ = 0;
    get_event_ = 0;
    get_event_iv_ = 0;
    get_event_pv_ = 0;
    get_window_iv_ = 0;
    get_window_cv_ = 0;
    destroy_window_ = 0;
    create_pixmap_ = 0;
    destroy_pixmap_ = 0;
    set_pixmap_iv_ = 0;
    create_pixmap_buffer_ = 0;
    get_pixmap_pv_ = 0;
    get_buffer_pv_ = 0;
    get_buffer_iv_ = 0;
    read_window_ = 0;

    width_ = 0;
    height_ = 0;
    stride_ = 0;
    target_posted_ = false;
    event_count_ = 0;
    read_failures_ = 0;
}
