/*
 * OEM plane 33/58 census for Audi MHI2Q.
 *
 * Read-only design:
 *   - creates only a SCREEN_WINDOW_MANAGER_CONTEXT owned by this observer;
 *   - discovers existing/future stock windows from CREATE/PROPERTY/POST events;
 *   - calls screen_get_* APIs only on foreign windows and buffers;
 *   - never creates/manages/destroys a foreign window and never sets a property.
 *
 * Important QNX detail:
 * SCREEN_PROPERTY_WINDOW_COUNT/WINDOWS are scoped to the calling context and
 * are NOT a global census.  The window-manager event queue is therefore the
 * only identity-safe observation path used here.
 */
#include <dlfcn.h>
#include <errno.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define CENSUS_SCHEMA "OEM_PLANE33_58_CENSUS_V1_1"

#define SCR_WINDOW_MANAGER_CONTEXT         1

#define SCR_EVENT_NONE                     0
#define SCR_EVENT_CREATE                   1
#define SCR_EVENT_PROPERTY                 2
#define SCR_EVENT_CLOSE                    3
#define SCR_EVENT_POST                     9

#define SCR_PROP_BUFFER_COUNT              4
#define SCR_PROP_BUFFER_SIZE               5
#define SCR_PROP_DISPLAY                  11
#define SCR_PROP_FORMAT                   14
#define SCR_PROP_GROUP                    18
#define SCR_PROP_ID_STRING                20
#define SCR_PROP_NAME                     30
#define SCR_PROP_OWNER_PID                31
#define SCR_PROP_PLANAR_OFFSETS           33
#define SCR_PROP_POSITION                 35
#define SCR_PROP_RENDER_BUFFERS           37
#define SCR_PROP_SIZE                     40
#define SCR_PROP_SOURCE_POSITION          41
#define SCR_PROP_SOURCE_SIZE              42
#define SCR_PROP_STRIDE                   44
#define SCR_PROP_TYPE                     47
#define SCR_PROP_USAGE                    48
#define SCR_PROP_VISIBLE                  51
#define SCR_PROP_WINDOW                   52
#define SCR_PROP_SCALE_QUALITY            56
#define SCR_PROP_SOURCE_CLIP_POSITION     68
#define SCR_PROP_SOURCE_CLIP_SIZE         72
#define SCR_PROP_SCALE_FACTOR            114
#define SCR_PROP_MANAGER_STRING          152

typedef void *scr_context_t;
typedef void *scr_event_t;
typedef void *scr_window_t;
typedef void *scr_buffer_t;
typedef void *scr_display_t;
typedef void *scr_group_t;

typedef int (*fn_create_context)(scr_context_t *, int);
typedef int (*fn_destroy_context)(scr_context_t);
typedef int (*fn_create_event)(scr_event_t *);
typedef int (*fn_destroy_event)(scr_event_t);
typedef int (*fn_get_event)(scr_context_t, scr_event_t, uint64_t);
typedef int (*fn_get_event_iv)(scr_event_t, int, int *);
typedef int (*fn_get_event_pv)(scr_event_t, int, void **);
typedef int (*fn_get_window_iv)(scr_window_t, int, int *);
typedef int (*fn_get_window_pv)(scr_window_t, int, void **);
typedef int (*fn_get_window_cv)(scr_window_t, int, int, char *);
typedef int (*fn_get_buffer_iv)(scr_buffer_t, int, int *);
typedef int (*fn_get_display_cv)(scr_display_t, int, int, char *);
typedef int (*fn_get_group_cv)(scr_group_t, int, int, char *);

struct api {
    void *lib;
    fn_create_context create_context;
    fn_destroy_context destroy_context;
    fn_create_event create_event;
    fn_destroy_event destroy_event;
    fn_get_event get_event;
    fn_get_event_iv get_event_iv;
    fn_get_event_pv get_event_pv;
    fn_get_window_iv get_window_iv;
    fn_get_window_pv get_window_pv;
    fn_get_window_cv get_window_cv;
    fn_get_buffer_iv get_buffer_iv;
    fn_get_display_cv get_display_cv;
    fn_get_group_cv get_group_cv;
};

struct tracked {
    scr_window_t window;
    unsigned long event_seq;
    int last_event_type;
};

static volatile sig_atomic_t g_stop;

static void on_signal(int sig) {
    (void)sig;
    g_stop = 1;
}

static void *sym(void *lib, const char *name) {
    dlerror();
    return dlsym(lib, name);
}

static int open_api(struct api *a) {
    memset(a, 0, sizeof(*a));
    a->lib = dlopen("libscreen.so.1", RTLD_LAZY);
    if (!a->lib) a->lib = dlopen("libscreen.so", RTLD_LAZY);
    if (!a->lib) {
        fprintf(stderr, "ERROR libscreen unavailable: %s\n", dlerror());
        return -1;
    }

    a->create_context = (fn_create_context)sym(a->lib, "screen_create_context");
    a->destroy_context = (fn_destroy_context)sym(a->lib, "screen_destroy_context");
    a->create_event = (fn_create_event)sym(a->lib, "screen_create_event");
    a->destroy_event = (fn_destroy_event)sym(a->lib, "screen_destroy_event");
    a->get_event = (fn_get_event)sym(a->lib, "screen_get_event");
    a->get_event_iv = (fn_get_event_iv)sym(a->lib, "screen_get_event_property_iv");
    a->get_event_pv = (fn_get_event_pv)sym(a->lib, "screen_get_event_property_pv");
    a->get_window_iv = (fn_get_window_iv)sym(a->lib, "screen_get_window_property_iv");
    a->get_window_pv = (fn_get_window_pv)sym(a->lib, "screen_get_window_property_pv");
    a->get_window_cv = (fn_get_window_cv)sym(a->lib, "screen_get_window_property_cv");
    a->get_buffer_iv = (fn_get_buffer_iv)sym(a->lib, "screen_get_buffer_property_iv");
    a->get_display_cv = (fn_get_display_cv)sym(a->lib, "screen_get_display_property_cv");
    a->get_group_cv = (fn_get_group_cv)sym(a->lib, "screen_get_group_property_cv");

    if (!a->create_context || !a->destroy_context ||
        !a->create_event || !a->destroy_event ||
        !a->get_event || !a->get_event_iv || !a->get_event_pv ||
        !a->get_window_iv || !a->get_window_pv || !a->get_window_cv) {
        fprintf(stderr, "ERROR required libscreen read/event API missing\n");
        dlclose(a->lib);
        memset(a, 0, sizeof(*a));
        return -1;
    }
    return 0;
}

static void close_api(struct api *a) {
    if (a->lib) dlclose(a->lib);
    memset(a, 0, sizeof(*a));
}

static void out_iv1(FILE *out, struct api *a, scr_window_t w,
                    int prop, const char *name) {
    int v = 0x5a5a5a5a;
    int rc;
    int e;
    errno = 0;
    rc = a->get_window_iv(w, prop, &v);
    e = errno;
    if (rc == 0) fprintf(out, "%s=%d rc=0\n", name, v);
    else fprintf(out, "%s=NA rc=%d errno=%d\n", name, rc, e);
}

static void out_iv2(FILE *out, struct api *a, scr_window_t w,
                    int prop, const char *name) {
    int v[2] = { 0x5a5a5a5a, 0x5a5a5a5a };
    int rc;
    int e;
    errno = 0;
    rc = a->get_window_iv(w, prop, v);
    e = errno;
    if (rc == 0) fprintf(out, "%s=%d,%d rc=0\n", name, v[0], v[1]);
    else fprintf(out, "%s=NA rc=%d errno=%d\n", name, rc, e);
}

static void out_cv(FILE *out, struct api *a, scr_window_t w,
                   int prop, const char *name, int len) {
    char buf[192];
    int rc;
    int e;
    if (len > (int)sizeof(buf) - 1) len = (int)sizeof(buf) - 1;
    memset(buf, 0, sizeof(buf));
    errno = 0;
    rc = a->get_window_cv(w, prop, len, buf);
    e = errno;
    buf[sizeof(buf) - 1] = 0;
    if (rc == 0) fprintf(out, "%s='%s' rc=0\n", name, buf);
    else fprintf(out, "%s=NA rc=%d errno=%d\n", name, rc, e);
}

static void out_buffer(FILE *out, struct api *a, scr_buffer_t b, int index) {
    int v1;
    int v3[3];
    int rc;
    int e;

    fprintf(out, "buffer_%d_handle=%p\n", index, b);
    if (!a->get_buffer_iv || !b) {
        fprintf(out, "buffer_%d_properties=NA reason=get_buffer_iv_or_handle_missing\n",
                index);
        return;
    }

    v3[0] = v3[1] = v3[2] = 0;
    errno = 0;
    rc = a->get_buffer_iv(b, SCR_PROP_BUFFER_SIZE, v3);
    e = errno;
    if (rc == 0)
        fprintf(out, "buffer_%d_size=%d,%d rc=0\n", index, v3[0], v3[1]);
    else
        fprintf(out, "buffer_%d_size=NA rc=%d errno=%d\n", index, rc, e);

    v1 = 0;
    errno = 0;
    rc = a->get_buffer_iv(b, SCR_PROP_FORMAT, &v1);
    e = errno;
    if (rc == 0) fprintf(out, "buffer_%d_format=%d rc=0\n", index, v1);
    else fprintf(out, "buffer_%d_format=NA rc=%d errno=%d\n", index, rc, e);

    v1 = 0;
    errno = 0;
    rc = a->get_buffer_iv(b, SCR_PROP_STRIDE, &v1);
    e = errno;
    if (rc == 0) fprintf(out, "buffer_%d_stride=%d rc=0\n", index, v1);
    else fprintf(out, "buffer_%d_stride=NA rc=%d errno=%d\n", index, rc, e);

    v3[0] = v3[1] = v3[2] = 0;
    errno = 0;
    rc = a->get_buffer_iv(b, SCR_PROP_PLANAR_OFFSETS, v3);
    e = errno;
    if (rc == 0) {
        fprintf(out, "buffer_%d_planar_offsets=%d,%d,%d rc=0\n",
                index, v3[0], v3[1], v3[2]);
    } else {
        fprintf(out, "buffer_%d_planar_offsets=NA rc=%d errno=%d\n",
                index, rc, e);
    }
}

static void out_related(FILE *out, struct api *a, scr_window_t w) {
    void *p = NULL;
    int rc;
    int e;

    errno = 0;
    rc = a->get_window_pv(w, SCR_PROP_GROUP, &p);
    e = errno;
    if (rc == 0) {
        fprintf(out, "group_handle=%p rc=0\n", p);
        if (p && a->get_group_cv) {
            char name[192];
            memset(name, 0, sizeof(name));
            errno = 0;
            rc = a->get_group_cv((scr_group_t)p, SCR_PROP_NAME,
                                 (int)sizeof(name) - 1, name);
            e = errno;
            if (rc == 0) fprintf(out, "group_name='%s' rc=0\n", name);
            else fprintf(out, "group_name=NA rc=%d errno=%d\n", rc, e);
        } else {
            fprintf(out, "group_name=NA reason=group_cv_unavailable\n");
        }
    } else {
        fprintf(out, "group_handle=NA rc=%d errno=%d\n", rc, e);
    }

    p = NULL;
    errno = 0;
    rc = a->get_window_pv(w, SCR_PROP_DISPLAY, &p);
    e = errno;
    if (rc == 0) {
        fprintf(out, "display_handle=%p rc=0\n", p);
        if (p && a->get_display_cv) {
            char id[192];
            memset(id, 0, sizeof(id));
            errno = 0;
            rc = a->get_display_cv((scr_display_t)p, SCR_PROP_ID_STRING,
                                   (int)sizeof(id) - 1, id);
            e = errno;
            if (rc == 0) fprintf(out, "display_id_string='%s' rc=0\n", id);
            else fprintf(out, "display_id_string=NA rc=%d errno=%d\n", rc, e);
        } else {
            fprintf(out, "display_id_string=NA reason=display_cv_unavailable\n");
        }
    } else {
        fprintf(out, "display_handle=NA rc=%d errno=%d\n", rc, e);
    }

    fprintf(out, "parent=UNAVAILABLE_IN_QNX650_WINDOW_API\n");
    fprintf(out, "viewport=UNAVAILABLE_AS_STANDARD_QNX650_WINDOW_PROPERTY\n");
}

static void out_buffers(FILE *out, struct api *a, scr_window_t w) {
    int count = 0;
    int rc;
    int e;
    int i;
    void **buffers;

    errno = 0;
    rc = a->get_window_iv(w, SCR_PROP_BUFFER_COUNT, &count);
    e = errno;
    if (rc != 0) {
        fprintf(out, "buffer_count=NA rc=%d errno=%d\n", rc, e);
        return;
    }
    fprintf(out, "buffer_count=%d rc=0\n", count);
    if (count <= 0 || count > 16) {
        if (count > 16)
            fprintf(out, "render_buffers=SKIPPED reason=unexpected_count\n");
        return;
    }

    buffers = (void **)calloc((size_t)count, sizeof(void *));
    if (!buffers) {
        fprintf(out, "render_buffers=NA reason=oom\n");
        return;
    }

    errno = 0;
    rc = a->get_window_pv(w, SCR_PROP_RENDER_BUFFERS, buffers);
    e = errno;
    if (rc != 0) {
        fprintf(out, "render_buffers=NA rc=%d errno=%d\n", rc, e);
        free(buffers);
        return;
    }

    for (i = 0; i < count; ++i)
        out_buffer(out, a, (scr_buffer_t)buffers[i], i);
    free(buffers);
}

static int target_index(const char *id) {
    if (!id) return -1;
    if (!strcmp(id, "33")) return 0;
    if (!strcmp(id, "58")) return 1;
    return -1;
}

static int write_snapshot(const char *state_dir, const char *id,
                          scr_window_t w, int event_type,
                          unsigned long event_seq, struct api *a) {
    char path[512];
    char tmp[544];
    FILE *out;
    time_t now = time(NULL);

    if (!state_dir || !id || !w) return -1;
    (void)snprintf(path, sizeof(path), "%s/window%s.state", state_dir, id);
    (void)snprintf(tmp, sizeof(tmp), "%s.new", path);

    out = fopen(tmp, "w");
    if (!out) return -1;

    fprintf(out, "schema=%s\n", CENSUS_SCHEMA);
    fprintf(out, "mode=READ_ONLY\n");
    fprintf(out, "id_string=%s\n", id);
    fprintf(out, "window_handle=%p\n", w);
    fprintf(out, "event_type=%d\n", event_type);
    fprintf(out, "event_seq=%lu\n", event_seq);
    fprintf(out, "snapshot_epoch=%lu\n", (unsigned long)now);

    out_iv2(out, a, w, SCR_PROP_SIZE, "SCREEN_PROPERTY_SIZE");
    out_iv2(out, a, w, SCR_PROP_BUFFER_SIZE, "SCREEN_PROPERTY_BUFFER_SIZE");
    out_iv2(out, a, w, SCR_PROP_SOURCE_SIZE, "SCREEN_PROPERTY_SOURCE_SIZE");
    out_iv2(out, a, w, SCR_PROP_SOURCE_POSITION, "SCREEN_PROPERTY_SOURCE_POSITION");
    out_iv2(out, a, w, SCR_PROP_POSITION, "SCREEN_PROPERTY_POSITION");
    out_iv1(out, a, w, SCR_PROP_VISIBLE, "SCREEN_PROPERTY_VISIBLE");
    out_iv1(out, a, w, SCR_PROP_FORMAT, "SCREEN_PROPERTY_FORMAT");
    out_iv1(out, a, w, SCR_PROP_STRIDE, "SCREEN_PROPERTY_STRIDE_WINDOW");
    out_iv1(out, a, w, SCR_PROP_OWNER_PID, "SCREEN_PROPERTY_OWNER_PID");
    out_iv1(out, a, w, SCR_PROP_USAGE, "SCREEN_PROPERTY_USAGE");

    out_iv2(out, a, w, SCR_PROP_SOURCE_CLIP_POSITION,
            "SCREEN_PROPERTY_SOURCE_CLIP_POSITION");
    out_iv2(out, a, w, SCR_PROP_SOURCE_CLIP_SIZE,
            "SCREEN_PROPERTY_SOURCE_CLIP_SIZE");
    out_iv1(out, a, w, SCR_PROP_SCALE_FACTOR, "SCREEN_PROPERTY_SCALE_FACTOR");
    out_iv1(out, a, w, SCR_PROP_SCALE_QUALITY, "SCREEN_PROPERTY_SCALE_QUALITY");
    out_cv(out, a, w, SCR_PROP_MANAGER_STRING,
           "SCREEN_PROPERTY_MANAGER_STRING", 191);
    out_related(out, a, w);
    out_buffers(out, a, w);

    fprintf(out, "snapshot_complete=1\n");
    if (fflush(out) != 0 || fclose(out) != 0) {
        remove(tmp);
        return -1;
    }
    if (rename(tmp, path) != 0) {
        remove(tmp);
        return -1;
    }
    return 0;
}

static int touch_ready(const char *state_dir) {
    char path[512];
    FILE *f;
    (void)snprintf(path, sizeof(path), "%s/READY", state_dir);
    f = fopen(path, "w");
    if (!f) return -1;
    fprintf(f, "schema=%s\nmode=READ_ONLY\nobserver=WINDOW_MANAGER_EVENT_QUEUE\n",
            CENSUS_SCHEMA);
    return fclose(f);
}

static void usage(const char *argv0) {
    fprintf(stderr, "usage: %s --watch --state-dir <path>\n", argv0);
}

int main(int argc, char **argv) {
    struct api a;
    struct tracked tracked[2];
    scr_context_t ctx = NULL;
    scr_event_t event = NULL;
    const char *state_dir = NULL;
    int watch = 0;
    int i;
    int rc;
    int e;
    unsigned long event_seq = 0;

    memset(tracked, 0, sizeof(tracked));

    for (i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--watch")) {
            watch = 1;
        } else if (!strcmp(argv[i], "--state-dir") && i + 1 < argc) {
            state_dir = argv[++i];
        } else {
            usage(argv[0]);
            return 64;
        }
    }
    if (!watch || !state_dir || !*state_dir) {
        usage(argv[0]);
        return 64;
    }

    signal(SIGTERM, on_signal);
    signal(SIGINT, on_signal);
    signal(SIGHUP, on_signal);

    printf("CENSUS_WATCH_BEGIN schema=%s mode=READ_ONLY source=WINDOW_MANAGER_EVENT_QUEUE\n",
           CENSUS_SCHEMA);
    printf("safety=no_screen_set no_foreign_window_create no_foreign_window_manage "
           "no_foreign_window_destroy no_context_switch no_carplay_hook\n");
    fflush(stdout);

    if (open_api(&a) != 0) return 2;

    errno = 0;
    rc = a.create_context(&ctx, SCR_WINDOW_MANAGER_CONTEXT);
    e = errno;
    if (rc != 0 || !ctx) {
        printf("window_manager_context=FAIL rc=%d errno=%d\n", rc, e);
        close_api(&a);
        return 3;
    }
    printf("window_manager_context=OK handle=%p context_type=%d\n",
           ctx, SCR_WINDOW_MANAGER_CONTEXT);

    errno = 0;
    rc = a.create_event(&event);
    e = errno;
    if (rc != 0 || !event) {
        printf("event_create=FAIL rc=%d errno=%d\n", rc, e);
        a.destroy_context(ctx);
        close_api(&a);
        return 4;
    }

    if (touch_ready(state_dir) != 0) {
        printf("ready_file=FAIL path=%s errno=%d\n", state_dir, errno);
        a.destroy_event(event);
        a.destroy_context(ctx);
        close_api(&a);
        return 5;
    }

    printf("CENSUS_WATCH_READY state_dir=%s targets=33,58 "
           "events=CREATE,PROPERTY,POST,CLOSE\n", state_dir);
    fflush(stdout);

    while (!g_stop) {
        int type = SCR_EVENT_NONE;
        void *event_window = NULL;
        char id[128];
        int idx = -1;

        errno = 0;
        rc = a.get_event(ctx, event, 250000000ULL);
        e = errno;
        if (rc != 0) {
            if (e != ETIMEDOUT && e != EAGAIN)
                printf("event_wait=FAIL rc=%d errno=%d\n", rc, e);
            continue;
        }

        errno = 0;
        if (a.get_event_iv(event, SCR_PROP_TYPE, &type) != 0 ||
            type == SCR_EVENT_NONE)
            continue;

        ++event_seq;

        if (type != SCR_EVENT_CREATE &&
            type != SCR_EVENT_PROPERTY &&
            type != SCR_EVENT_CLOSE &&
            type != SCR_EVENT_POST)
            continue;

        errno = 0;
        if (a.get_event_pv(event, SCR_PROP_WINDOW, &event_window) != 0 ||
            !event_window)
            continue;

        memset(id, 0, sizeof(id));
        errno = 0;
        if (a.get_window_cv((scr_window_t)event_window, SCR_PROP_ID_STRING,
                            (int)sizeof(id) - 1, id) == 0) {
            idx = target_index(id);
        }

        if (idx < 0) {
            if (type == SCR_EVENT_CLOSE) {
                if (tracked[0].window == event_window) idx = 0;
                else if (tracked[1].window == event_window) idx = 1;
            }
            if (idx < 0) continue;
            (void)snprintf(id, sizeof(id), "%s", idx == 0 ? "33" : "58");
        }

        if (type == SCR_EVENT_CLOSE) {
            printf("TARGET_EVENT id=%s event=CLOSE seq=%lu handle=%p\n",
                   id, event_seq, event_window);
            if (tracked[idx].window == event_window)
                memset(&tracked[idx], 0, sizeof(tracked[idx]));
            fflush(stdout);
            continue;
        }

        tracked[idx].window = (scr_window_t)event_window;
        tracked[idx].event_seq = event_seq;
        tracked[idx].last_event_type = type;

        rc = write_snapshot(state_dir, id, tracked[idx].window,
                            type, event_seq, &a);
        printf("TARGET_EVENT id=%s event=%d seq=%lu handle=%p snapshot=%s\n",
               id, type, event_seq, event_window, rc == 0 ? "OK" : "FAIL");
        fflush(stdout);
    }

    printf("CENSUS_WATCH_END events=%lu tracked33=%d tracked58=%d\n",
           event_seq, tracked[0].window != NULL, tracked[1].window != NULL);
    fflush(stdout);

    a.destroy_event(event);
    a.destroy_context(ctx);
    close_api(&a);
    return 0;
}
