/*
 * p1404_cockpit_native.c - private111 stock-decoder compatibility staging.
 *
 * Direct-display V2 keeps the V1-proven private111/stock OMX/displayable3/
 * Context80 chain and changes only decoded-pixel acquisition. The vendor
 * 0x0001000c OMX/Screen buffer is no longer treated as row-linear NV12.
 * After stock CScreenRender posts each private frame, Screen linearizes the
 * exact stock window into a normal pixmap; the result is repacked into the
 * existing /carplay111_decoded NV12 SHM. The real instrument sink remains the
 * separate MMI-derived displayable3 sidecar under Java-owned Context80.
 *
 * The historical displayable58/manage-window code below remains active only so
 * stock OMX can complete its normal buffer lifecycle while this fallback is
 * used.  It is decoder staging, not the direct-display source or success gate.
 * /carplay111_h264 is captured independently at ScreenStreamProcessData and is
 * the handoff boundary for the future standalone Qualcomm/QNX decoder backend.
 * Main110 remains exact stock passthrough.
 */
#include "p1404_cockpit_native.h"
#include "p1404_abi.h"
#include "p1404_airplay.h"
#include "altscreen_core.h"
#include "altscreen_paths.h"
#include "p1404_observe.h"
#include "private111_direct_tap.h"

#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <dlfcn.h>
#include <unistd.h>

/* Host fixtures and the legacy preload build may omit the K1004 direct
 * resolver. Keep it optional there; the exact direct overlay provides it. */
extern void *p1404_direct_stock_symbol_named(const char *name)
    __attribute__((weak));

#define NATIVE_SLOTS 8u
#define SCREEN_STREAM_VIDEO_IMPL_OFF 0x38u
#define OMX_VIDEO_RENDERER_OFF       0x0cu
#define NATIVE_MIN_POSTS             3u
#define NATIVE_POST_WINDOW_SECONDS   2u
#define NATIVE_STALL_SECONDS         3u
#define NATIVE_EVENT_RETRY_SECONDS   2u
#define NATIVE_EVENT_TIMEOUT_SECONDS 4u
#define P1404_P_WAIT                 0
#define NATIVE_CONFIG_REFUSED_STATUS (-58796)
#define P1404_RTLD_NOW                2
#define SCREEN_WINDOW_MANAGER_CONTEXT 1
#define SCREEN_DISPLAY_MANAGER_CONTEXT 8
#define SCREEN_PROPERTY_SIZE          40
#define SCREEN_PROPERTY_DISPLAY_COUNT 59
#define SCREEN_PROPERTY_DISPLAYS      60
#define SCREEN_PROPERTY_ID            87
#define SCREEN_MAX_DISPLAYS            8
#define DISPLAY_MANAGER_SECRET         "How are you gentlemen?"
#define DMDT_PATH                    "/eso/bin/apps/dmdt"

#define CSCREEN_CONFIG_SYMBOL "_ZN3dio13CScreenRender6configERKNS_16st_screen_configE"
#define CSCREEN_RENDER_SYMBOL "_ZN3dio13CScreenRender6renderEPh"
/* Stock K1004 disassembly: CScreenRender+0x08 is the exact screen_window_t
 * passed to screen_post_window(); +0x40 is CWindowBuffers. */
#define CSCREEN_WINDOW_OFF 0x08u

typedef int (*f_cscreen_config_t)(void *, const struct p1404_screen_config *);
typedef int (*f_cscreen_render_t)(void *, unsigned char *);
typedef int (*f_screen_stream_start_t)(void *);
typedef void *(*f_screen_copy_main_t)(int *);
typedef int (*f_screen_create_t)(void **, const void *);
typedef int (*f_screen_copy_delegates_t)(void *, void *);
typedef void (*f_screen_register_delegates_t)(void *, const void *);
typedef unsigned long native_pthread_t;
typedef int (*f_pthread_create_t)(native_pthread_t *, const void *,
                                  void *(*)(void *), void *);
typedef int (*f_pthread_detach_t)(native_pthread_t);
typedef long (*f_spawnl_t)(int, const char *, const char *, ...);
typedef void *screen_context_t;
typedef void *screen_display_t;
typedef void *screen_window_t;
typedef int (*f_screen_create_context_t)(screen_context_t *, int);
typedef int (*f_screen_destroy_context_t)(screen_context_t);
typedef int (*f_screen_get_context_iv_t)(screen_context_t, int, int *);
typedef int (*f_screen_get_context_pv_t)(screen_context_t, int, void **);
typedef int (*f_screen_get_display_iv_t)(screen_display_t, int, int *);
typedef int (*f_screen_create_window_group_t)(screen_window_t, const char *);
typedef int (*f_screen_create_window_buffers_t)(screen_window_t, int);
typedef int (*f_screen_manage_window_t)(screen_window_t, const char *);

enum native_route_action {
    NATIVE_ROUTE_NONE = 0,
    NATIVE_ROUTE_ACTIVATE = 1,
    NATIVE_ROUTE_RESTORE = 2
};

struct native_slot {
    void *receiver;
    void *stream;
    void *video_impl;
    void *renderer;
    uint64_t first_post_at;
    uint64_t last_post_at;
    uint32_t generation;
    uint32_t state_generation;
    uint32_t posts;
    uint32_t action_generation;
    unsigned long owner_thread;
    int monitor_started;
    int action;
    int action_pending;
    int preconfig_rewritten;
    int config_ok;
    int decoder_marked;
    int visible;
    int first_real_frame_posted;
    uint32_t config_width;
    uint32_t config_height;
    uint32_t config_format;
    uint32_t config_usage;
    uint64_t ui_event_at;
    uint64_t keyframe_event_at;
    int ui_event_state;       /* 0=needed, 1=inflight, 2=accepted, 3=timed-out */
    int keyframe_event_state; /* 0=needed, 1=inflight, 2=accepted, 3=timed-out */
};

struct native_thread_job {
    struct native_slot *slot;
    void *receiver;
    void *stream;
    uint32_t generation;
    uint32_t state_generation;
    int action;
};

static struct native_slot g_native[NATIVE_SLOTS];
static volatile unsigned g_native_guard;
static volatile unsigned g_route_guard;
/* Protected by g_route_guard. Identifies the generation that most recently
 * committed context76, so an old detached worker can never restore over a
 * newer private session. */
static uint32_t g_route_generation;
static f_cscreen_config_t g_real_config;
static f_cscreen_render_t g_real_render;
static f_screen_stream_start_t g_real_stream_start;
static f_screen_copy_main_t g_real_screen_copy_main;
static f_screen_create_t g_real_screen_create;
static f_screen_copy_delegates_t g_real_screen_copy_delegates;
static f_screen_register_delegates_t g_real_screen_register_delegates;

static void *native_direct_stock(const char *name) {
    return p1404_direct_stock_symbol_named ?
        p1404_direct_stock_symbol_named(name) : NULL;
}

static struct {
    void *receiver;
    void *stream;
    unsigned long owner_thread;
    int active;
    int invoked;
    int attached;
} g_start_claim;
static f_pthread_create_t g_pthread_create;
static f_pthread_detach_t g_pthread_detach;
static f_spawnl_t g_spawnl;
static void *g_screen_buffer_lib;
static f_screen_create_window_group_t g_screen_create_window_group;
static f_screen_create_window_buffers_t g_screen_create_window_buffers;
static f_screen_manage_window_t g_screen_manage_window;
static struct {
    void *renderer;
    screen_window_t window;
    unsigned long owner_thread;
    int active;
    int group_skipped;
    int manage_rc;
    int buffers_rc;
    int managed;
} g_managed_config;
static uint32_t g_generation;
static uint32_t g_target_width;
static uint32_t g_target_height;

static void native_lock(void) {
    while (__sync_lock_test_and_set(&g_native_guard, 1u) != 0u) { }
}
static void native_unlock(void) { __sync_lock_release(&g_native_guard); }
static void route_lock(void) {
    while (__sync_lock_test_and_set(&g_route_guard, 1u) != 0u) { }
}
static void route_unlock(void) { __sync_lock_release(&g_route_guard); }

static void *read_ptr_at(void *base, unsigned off) {
    void *value = NULL;
    if (base) memcpy(&value, (const unsigned char *)base + off, sizeof(value));
    return value;
}


/* Stock CScreenRender owns the QNX window and buffers. The measured
 * P1404/K1004 layout is CScreenRender+0x40 -> CWindowBuffers, whose +0 array
 * and +4 count are used by stock getWindowBufferHeader/render. The same Screen
 * handle is registered with DisplayManager immediately before buffer creation;
 * stock OMX allocation, posting and teardown remain unchanged. */
static int bind_screen_native_api(void) {
    void *lib;
    f_screen_create_window_group_t create_group;
    f_screen_create_window_buffers_t create_buffers;
    f_screen_manage_window_t manage_window;
    if (g_screen_create_window_group && g_screen_create_window_buffers &&
        g_screen_manage_window)
        return 1;
    lib = dlopen("libscreen.so.1", P1404_RTLD_NOW);
    if (!lib) return 0;
    create_group = (f_screen_create_window_group_t)
        dlsym(lib, "screen_create_window_group");
    create_buffers = (f_screen_create_window_buffers_t)
        dlsym(lib, "screen_create_window_buffers");
    manage_window = (f_screen_manage_window_t)dlsym(lib, "screen_manage_window");
    native_lock();
    if (!g_screen_buffer_lib) {
        g_screen_buffer_lib = lib;
        g_screen_create_window_group = create_group;
        g_screen_create_window_buffers = create_buffers;
        g_screen_manage_window = manage_window;
        lib = NULL;
    }
    native_unlock();
    if (lib) dlclose(lib);
    return g_screen_create_window_group && g_screen_create_window_buffers &&
           g_screen_manage_window;
}



static int native_route_requested(void) {
    /* Java/HMI owns Context80. Native route activation is disabled.
     * Stock displayable58 exists only as V1 decoder compatibility staging;
     * direct display consumes /carplay111_decoded, never Window58 readback. */
    return 0;
}

static struct native_slot *find_renderer_locked(void *renderer) {
    unsigned i;
    for (i = 0; i < NATIVE_SLOTS; ++i)
        if (g_native[i].renderer == renderer && g_native[i].stream)
            return &g_native[i];
    return NULL;
}

static struct native_slot *find_preconfig_locked(void *renderer,
                                                  unsigned long owner_thread) {
    unsigned i;
    void *candidate;
    for (i = 0; i < NATIVE_SLOTS; ++i) {
        if (!g_native[i].stream || g_native[i].renderer ||
            g_native[i].owner_thread != owner_thread || !g_native[i].video_impl)
            continue;
        candidate = read_ptr_at(g_native[i].video_impl, OMX_VIDEO_RENDERER_OFF);
        if (candidate == renderer) return &g_native[i];
    }
    return NULL;
}

static struct native_slot *find_stream_locked(void *receiver, void *stream) {
    unsigned i;
    for (i = 0; i < NATIVE_SLOTS; ++i)
        if (g_native[i].receiver == receiver && g_native[i].stream == stream)
            return &g_native[i];
    return NULL;
}

static struct native_slot *free_slot_locked(void) {
    unsigned i;
    for (i = 0; i < NATIVE_SLOTS; ++i)
        if (!g_native[i].stream) return &g_native[i];
    return NULL;
}

int p1404_cockpit_native_get_geometry(uint32_t *width, uint32_t *height) {
    uint32_t w, h;
    native_lock();
    w = g_target_width;
    h = g_target_height;
    native_unlock();
    if (!w || !h) return 0;
    if (width) *width = w;
    if (height) *height = h;
    return 1;
}

void p1404_cockpit_native_set_test_geometry(uint32_t width, uint32_t height) {
    if (!width || !height || width > 8192u || height > 8192u) return;
    native_lock();
    g_target_width = width;
    g_target_height = height;
    native_unlock();
    (void)altscreen_set_cluster_geometry(width, height);
}

int p1404_cockpit_native_refresh_geometry(void) {
    void *lib = NULL;
    screen_context_t context = NULL;
    screen_display_t displays[SCREEN_MAX_DISPLAYS];
    f_screen_create_context_t create_context = NULL;
    f_screen_destroy_context_t destroy_context = NULL;
    f_screen_get_context_iv_t get_context_iv = NULL;
    f_screen_get_context_pv_t get_context_pv = NULL;
    f_screen_get_display_iv_t get_display_iv = NULL;
    int count = 0, i, id, size[2], ok = 0;
    uint32_t width = 0, height = 0;

    memset(displays, 0, sizeof(displays));
    lib = dlopen("libscreen.so.1", P1404_RTLD_NOW);
    if (!lib) goto done;
    create_context = (f_screen_create_context_t)dlsym(lib, "screen_create_context");
    destroy_context = (f_screen_destroy_context_t)dlsym(lib, "screen_destroy_context");
    get_context_iv = (f_screen_get_context_iv_t)dlsym(lib, "screen_get_context_property_iv");
    get_context_pv = (f_screen_get_context_pv_t)dlsym(lib, "screen_get_context_property_pv");
    get_display_iv = (f_screen_get_display_iv_t)dlsym(lib, "screen_get_display_property_iv");
    if (!create_context || !destroy_context || !get_context_iv ||
        !get_context_pv || !get_display_iv) goto done;
    if (create_context(&context, SCREEN_WINDOW_MANAGER_CONTEXT) != 0 &&
        create_context(&context, SCREEN_DISPLAY_MANAGER_CONTEXT) != 0) goto done;
    if (get_context_iv(context, SCREEN_PROPERTY_DISPLAY_COUNT, &count) != 0 ||
        count <= 0 || count > SCREEN_MAX_DISPLAYS) goto done;
    if (get_context_pv(context, SCREEN_PROPERTY_DISPLAYS, (void **)displays) != 0)
        goto done;
    for (i = 0; i < count; ++i) {
        id = -1;
        size[0] = size[1] = 0;
        if (get_display_iv(displays[i], SCREEN_PROPERTY_ID, &id) != 0 ||
            get_display_iv(displays[i], SCREEN_PROPERTY_SIZE, size) != 0) continue;
        altscreen_log("PHASE=NATIVE_111_DISPLAY_CANDIDATE index=%d id=%d size=%dx%d",
                      i, id, size[0], size[1]);
        if (id == (int)ALT111_TARGET_DISPLAY_ID && size[0] > 0 && size[1] > 0 &&
            size[0] <= 8192 && size[1] <= 8192) {
            width = (uint32_t)size[0];
            height = (uint32_t)size[1];
            ok = 1;
            break;
        }
    }
done:
    if (context && destroy_context) (void)destroy_context(context);
    if (lib) dlclose(lib);
    if (!ok) {
        altscreen_log("ERROR PHASE=NATIVE_111_GEOMETRY_QUERY_FAILED target_display=1 count=%d fixed_fallback=0 private111_refused=1",
                      count);
        return 0;
    }
    native_lock();
    g_target_width = width;
    g_target_height = height;
    native_unlock();
    (void)altscreen_set_cluster_geometry(width, height);
    altscreen_log("PHASE=NATIVE_111_GEOMETRY_READY target_display=1 size=%ux%u source=SCREEN_PROPERTY_SIZE fixed_fallback=0",
                  width, height);
    return 1;
}

int p1404_cockpit_native_rewrite_config(const struct p1404_screen_config *input,
                                        struct p1404_screen_config *output) {
    uint32_t requested_width, requested_height;
    if (!input || !output || sizeof(*output) != 44u) return 0;
    if (!input->source_width || !input->source_height ||
        input->source_width > 8192u || input->source_height > 8192u ||
        !p1404_cockpit_native_get_geometry(&requested_width, &requested_height))
        return 0;
    memcpy(output, input, sizeof(*output));
    /* Respect the resolution negotiated from the runtime display request.
     * Window and source remain identical so Screen performs no scaling. */
    output->window_width = input->source_width;
    output->window_height = input->source_height;
    output->source_width = input->source_width;
    output->source_height = input->source_height;
    output->offset_x = 0;
    output->offset_y = 0;
    output->window_id = ALT111_DISPLAYABLE_ID;
    altscreen_log("PHASE=NATIVE_111_GEOMETRY_APPLIED requested=%ux%u negotiated=%ux%u fixed=0 screen_scaling=0",
                  requested_width, requested_height,
                  input->source_width, input->source_height);
    return 1;
}

int p1404_cockpit_native_bind_stock(void) {
    if (!g_real_config)
        g_real_config = (f_cscreen_config_t)p1404_stock_symbol_named(CSCREEN_CONFIG_SYMBOL);
    if (!g_real_render)
        g_real_render = (f_cscreen_render_t)p1404_stock_symbol_named(CSCREEN_RENDER_SYMBOL);
    if (!g_real_stream_start)
        g_real_stream_start = (f_screen_stream_start_t)
            p1404_stock_symbol_named("ScreenStreamStart");
    if (!g_real_screen_copy_main)
        g_real_screen_copy_main = (f_screen_copy_main_t)
            p1404_stock_symbol_named("ScreenCopyMain");
    if (!g_real_screen_create)
        g_real_screen_create = (f_screen_create_t)
            p1404_stock_symbol_named("ScreenCreate");
    if (!g_real_screen_copy_delegates)
        g_real_screen_copy_delegates = (f_screen_copy_delegates_t)
            p1404_stock_symbol_named("ScreenCopyDelegates");
    if (!g_real_screen_register_delegates)
        g_real_screen_register_delegates = (f_screen_register_delegates_t)
            p1404_stock_symbol_named("ScreenRegisterDelegates");
    if (!g_pthread_create)
        g_pthread_create = (f_pthread_create_t)dlsym(RTLD_DEFAULT, "pthread_create");
    if (!g_pthread_detach)
        g_pthread_detach = (f_pthread_detach_t)dlsym(RTLD_DEFAULT, "pthread_detach");
    if (!g_spawnl)
        g_spawnl = (f_spawnl_t)dlsym(RTLD_DEFAULT, "spawnl");
    /* Loader constructors must resolve symbols only. Creating a Screen manager
     * context here can fault or deadlock dio_manager before authorization and
     * before the logger exists. Geometry is queried lazily at Alt advertisement
     * and again before the private renderer attaches. */
    altscreen_log("PHASE=NATIVE_111_STOCK_BIND config=%d render=%d stream_start=%d screen_copy_main=%d screen_create=%d copy_delegates=%d register_delegates=%d pthread_create=%d pthread_detach=%d spawnl=%d geometry=%d",
                  g_real_config != NULL, g_real_render != NULL,
                  g_real_stream_start != NULL, g_real_screen_copy_main != NULL,
                  g_real_screen_create != NULL,
                  g_real_screen_copy_delegates != NULL,
                  g_real_screen_register_delegates != NULL,
                  g_pthread_create != NULL,
                  g_pthread_detach != NULL, g_spawnl != NULL,
                  p1404_cockpit_native_get_geometry(NULL, NULL));
    return g_real_config && g_real_render && g_real_stream_start &&
           g_real_screen_copy_main && g_real_screen_create &&
           g_real_screen_copy_delegates && g_real_screen_register_delegates &&
           bind_screen_native_api();
}

static int run_dmdt(const char *verb, const char *a, const char *b) {
    long rc;
    if (!g_spawnl || !verb || !a || !b) return -1;
    rc = g_spawnl(P1404_P_WAIT, DMDT_PATH, "dmdt", verb, a, b, (char *)0);
    return (int)rc;
}

static int run_activate_route(void) {
    int a, b, c;
    a = run_dmdt("dc", "76", "58");
    b = run_dmdt("sc", "1", "72");
    c = run_dmdt("sc", "1", "76");
    altscreen_log("PHASE=NATIVE_111_ROUTE_ACTIVATE_RESULT dc76_58=%d sc1_72=%d sc1_76=%d",
                  a, b, c);
    return a == 0 && b == 0 && c == 0;
}

static int run_restore_route(void) {
    int a, b, c;
    a = run_dmdt("dc", "76", "58");
    b = run_dmdt("sc", "1", "72");
    c = run_dmdt("sc", "1", "74");
    altscreen_log("PHASE=NATIVE_111_ROUTE_RESTORE_RESULT dc76_58=%d sc1_72=%d sc1_74=%d",
                  a, b, c);
    return a == 0 && b == 0 && c == 0;
}

static void *native_route_worker(void *arg) {
    struct native_thread_job *job = (struct native_thread_job *)arg;
    struct native_slot *slot = job ? job->slot : NULL;
    void *receiver = job ? job->receiver : NULL;
    void *stream = job ? job->stream : NULL;
    uint32_t generation = job ? job->generation : 0;
    uint32_t state_generation = job ? job->state_generation : 0;
    int action = job ? job->action : NATIVE_ROUTE_NONE;
    int live = 0;
    int executed = 0;
    int ok = 0;
    int route_still_requested = 0;
    int stale_activate = 0;
    int committed_restore = 0;

    /* dmdt changes global display-manager state. Serialize the entire
     * validate/execute/commit sequence so an old detached action cannot race a
     * new generation and restore context74 over its context76 activation. */
    route_lock();
    native_lock();
    live = slot && slot->stream == stream && slot->receiver == receiver &&
           slot->generation == generation &&
           slot->state_generation == state_generation &&
           slot->action_pending && slot->action == action;
    native_unlock();

    if (live && action == NATIVE_ROUTE_ACTIVATE) {
        if (native_route_requested()) {
            executed = 1;
            ok = run_activate_route();
        }
        route_still_requested = native_route_requested();
        if (executed && !ok) (void)run_restore_route();
    } else if (live && action == NATIVE_ROUTE_RESTORE) {
        executed = 1;
        ok = run_restore_route();
    }

    native_lock();
    live = slot && slot->stream == stream && slot->receiver == receiver &&
           slot->generation == generation &&
           slot->state_generation == state_generation;
    if (live) {
        slot->action_pending = 0;
        slot->action = NATIVE_ROUTE_NONE;
        if (action == NATIVE_ROUTE_ACTIVATE) {
            if (executed && ok && route_still_requested) {
                slot->visible = 1;
                g_route_generation = generation;
            } else if (executed && ok) {
                stale_activate = 1;
            }
        } else if (action == NATIVE_ROUTE_RESTORE && executed && ok) {
            slot->visible = 0;
            slot->first_real_frame_posted = 0;
            slot->posts = 0;
            slot->first_post_at = 0;
            if (g_route_generation == generation) g_route_generation = 0;
            committed_restore = 1;
        }
    } else if (action == NATIVE_ROUTE_ACTIVATE && executed && ok) {
        stale_activate = 1;
    }
    native_unlock();

    if (stale_activate) {
        (void)run_restore_route();
        if (g_route_generation == generation) g_route_generation = 0;
    }
    route_unlock();

    if (committed_restore)
        alt_state_mark_native(receiver, state_generation,
                              ALT_STATE_NATIVE_COCKPIT_HIDDEN,
                              "native111-route-restored-context74");
    if (action == NATIVE_ROUTE_ACTIVATE && executed && ok && !stale_activate) {
        uint32_t width = 0, height = 0;
        (void)p1404_cockpit_native_get_geometry(&width, &height);
        alt_state_mark_native(receiver, state_generation,
                              ALT_STATE_NATIVE_UI_ACTIVE,
                              "private111-context76-activation-after-config-and-showui");
        alt_state_mark_native(receiver, state_generation,
                              ALT_STATE_NATIVE_COCKPIT_VISIBLE,
                              "private111-stock-omx->displayable58-context76-dynamic-geometry");
        altscreen_log("PHASE=NATIVE_111_COCKPIT_ACTIVE receiver=%p stream=%p requested_geometry=%ux%u displayable=58 context=76 gate=first_real_type111_frame_posted",
                      receiver, stream, width, height);
    }
    free(job);
    return NULL;
}

static int request_route_action(struct native_slot *slot, int action) {
    struct native_thread_job *job;
    native_pthread_t thread = 0;
    int rc;
    if (!slot || !g_pthread_create || !g_pthread_detach || !g_spawnl) return 0;
    job = (struct native_thread_job *)calloc(1u, sizeof(*job));
    if (!job) return 0;
    native_lock();
    if (!slot->stream || slot->action_pending) {
        native_unlock();
        free(job);
        return 0;
    }
    slot->action_pending = 1;
    slot->action = action;
    slot->action_generation = slot->generation;
    job->slot = slot;
    job->receiver = slot->receiver;
    job->stream = slot->stream;
    job->generation = slot->generation;
    job->state_generation = slot->state_generation;
    job->action = action;
    native_unlock();
    rc = g_pthread_create(&thread, NULL, native_route_worker, job);
    if (rc != 0) {
        native_lock();
        if (slot->action_generation == slot->generation) {
            slot->action_pending = 0;
            slot->action = NATIVE_ROUTE_NONE;
        }
        native_unlock();
        free(job);
        altscreen_log("ERROR PHASE=NATIVE_111_ROUTE_THREAD_CREATE action=%d rc=%d", action, rc);
        return 0;
    }
    (void)g_pthread_detach(thread);
    return 1;
}

static void *native_monitor_worker(void *arg) {
    struct native_thread_job *job = (struct native_thread_job *)arg;
    struct native_slot *slot = job ? job->slot : NULL;
    void *receiver = job ? job->receiver : NULL;
    void *stream = job ? job->stream : NULL;
    uint32_t generation = job ? job->generation : 0;
    uint32_t state_generation = job ? job->state_generation : 0;
    uint64_t now;
    int visible, pending, live, route_ready, event_kind, send_rc;
    for (;;) {
        sleep(1u);
        now = obs_now_us();
        event_kind = 0;
        native_lock();
        live = slot && slot->stream == stream && slot->receiver == receiver &&
               slot->generation == generation &&
               slot->state_generation == state_generation;
        visible = live ? slot->visible : 0;
        pending = live ? slot->action_pending : 0;
        route_ready = live && slot->ui_event_state == 2 &&
                      slot->preconfig_rewritten && slot->config_ok &&
                      slot->first_real_frame_posted;
        if (live) {
            if (slot->ui_event_state == 1 &&
                now > slot->ui_event_at + NATIVE_EVENT_TIMEOUT_SECONDS) {
                slot->ui_event_state = 3;
                altscreen_log("ERROR PHASE=ALT111_EVENT_TIMEOUT receiver=%p stream=%p generation=%u event=showUI retry=0 fail_closed=1",
                              receiver, stream, generation);
            }
            if (slot->keyframe_event_state == 1 &&
                now > slot->keyframe_event_at + NATIVE_EVENT_TIMEOUT_SECONDS) {
                slot->keyframe_event_state = 3;
                altscreen_log("ERROR PHASE=ALT111_EVENT_TIMEOUT receiver=%p stream=%p generation=%u event=forceKeyFrame retry=0 fail_closed=1",
                              receiver, stream, generation);
            }
            if (slot->ui_event_state == 0 &&
                (!slot->ui_event_at || now > slot->ui_event_at + NATIVE_EVENT_RETRY_SECONDS)) {
                slot->ui_event_state = 1;
                slot->ui_event_at = now;
                event_kind = ALT111_EVENT_SHOW_UI;
            } else if (slot->ui_event_state == 2 && slot->preconfig_rewritten &&
                       slot->keyframe_event_state == 0 &&
                       (!slot->keyframe_event_at ||
                        now > slot->keyframe_event_at + NATIVE_EVENT_RETRY_SECONDS)) {
                slot->keyframe_event_state = 1;
                slot->keyframe_event_at = now;
                event_kind = ALT111_EVENT_FORCE_KEYFRAME;
            }
        }
        native_unlock();
        if (!live) break;
        if (event_kind) {
            send_rc = alt_send_cluster_event(receiver, stream, generation, event_kind);
            if (send_rc != 0)
                p1404_cockpit_native_event_result(receiver, stream, generation,
                                                   event_kind, send_rc, 0);
        }
        if (route_ready && !visible && !pending && native_route_requested()) {
            altscreen_log("PHASE=NATIVE_111_ROUTE_READY receiver=%p stream=%p generation=%u basis=dynamic_config_plus_accepted_showui_plus_first_real_type111_post video_availability_gate=real_frame",
                          receiver, stream, generation);
            (void)request_route_action(slot, NATIVE_ROUTE_ACTIVATE);
        } else if (visible && !pending && !native_route_requested()) {
            altscreen_log("WARN PHASE=NATIVE_111_ROUTE_WATCHDOG reason=route_marker_removed restore=1");
            (void)request_route_action(slot, NATIVE_ROUTE_RESTORE);
        }
    }
    free(job);
    return NULL;
}

void p1404_cockpit_native_event_result(void *receiver, void *stream,
                                        uint32_t generation, int event_kind,
                                        int status, int response_received) {
    struct native_slot *slot;
    uint32_t state_generation = 0;
    int accepted = status == 0 && response_received;
    int applied = 0;
    native_lock();
    slot = find_stream_locked(receiver, stream);
    if (slot && slot->generation == generation) {
        state_generation = slot->state_generation;
        if (event_kind == ALT111_EVENT_SHOW_UI && slot->ui_event_state == 1) {
            slot->ui_event_state = accepted ? 2 : 0;
            applied = 1;
        } else if (event_kind == ALT111_EVENT_FORCE_KEYFRAME &&
                   slot->keyframe_event_state == 1) {
            slot->keyframe_event_state = accepted ? 2 : 0;
            applied = 1;
        }
    }
    native_unlock();
    if (accepted && applied && event_kind == ALT111_EVENT_SHOW_UI)
        alt_state_mark_native(receiver, state_generation,
                              ALT_STATE_NATIVE_UI_ACTIVE,
                              "showUI-alt-uuid-cluster-map-response-status0");
    altscreen_log("PHASE=ALT111_EVENT_RESULT receiver=%p stream=%p generation=%u event=%d status=%d response_received=%d accepted=%d applied=%d retry=%d",
                  receiver, stream, generation, event_kind, status,
                  response_received, accepted && applied, applied,
                  applied && !accepted);
}

int p1404_cockpit_native_prepare_start(void *receiver) {
    int ok = 0;
    if (!receiver || !p1404_mutate_armed || !p1404_cockpit_native_bind_stock())
        return 0;
    native_lock();
    if (!g_start_claim.active) {
        memset(&g_start_claim, 0, sizeof(g_start_claim));
        g_start_claim.receiver = receiver;
        g_start_claim.owner_thread = obs_thread_id();
        g_start_claim.active = 1;
        ok = 1;
    }
    native_unlock();
    altscreen_log("PHASE=NATIVE_111_START_CLAIM_PREPARE receiver=%p owner_thread=%lu ready=%d preconfig_attach=1",
                  receiver, obs_thread_id(), ok);
    return ok;
}

int p1404_cockpit_native_complete_start(void *receiver, void **stream) {
    int ok = 0;
    void *claimed_stream = NULL;
    unsigned long owner = obs_thread_id();
    if (stream) *stream = NULL;
    native_lock();
    if (g_start_claim.active && g_start_claim.receiver == receiver &&
        g_start_claim.owner_thread == owner) {
        claimed_stream = g_start_claim.stream;
        ok = g_start_claim.invoked && g_start_claim.attached && claimed_stream;
        memset(&g_start_claim, 0, sizeof(g_start_claim));
    }
    native_unlock();
    if (stream) *stream = claimed_stream;
    altscreen_log("PHASE=NATIVE_111_START_CLAIM_COMPLETE receiver=%p owner_thread=%lu stream=%p attached=%d preconfig_attach=%d",
                  receiver, owner, claimed_stream, ok, ok);
    return ok;
}

/* dio_manager imports ScreenCreate directly. Besides preserving its exact stock
 * behavior, this narrow front door guarantees that a redirect-install refusal
 * still starts the asynchronous worker and produces an explicit hook log rather
 * than another silent all-NO vehicle session. */
int ScreenCreate(void **out_screen, const void *properties) {
    f_screen_create_t stock = g_real_screen_create;
    if (altscreen_runtime_ensure_initialized)
        altscreen_runtime_ensure_initialized();
    if (!stock)
        stock = (f_screen_create_t)native_direct_stock("ScreenCreate");
    if (!stock) {
        if (out_screen) *out_screen = NULL;
        return -1;
    }
    g_real_screen_create = stock;
    return stock(out_screen, properties);
}

/* Exact stock ABI: ScreenCopyMain returns the retained Screen object in r0 and
 * writes OSStatus through its sole argument. The previous int(void **) wrapper
 * accidentally returned -58796 as a Screen pointer when reached before dlsym
 * was ready; _ScreenCopyProperty then crashed in CFLRetain. */
void *ScreenCopyMain(int *out_err) {
    void *receiver = NULL;
    void *display_descriptor = NULL;
    void *stock_main = NULL;
    void *alt_screen = NULL;
    uint32_t delegates[5]; /* exact 20-byte Screen delegate block */
    unsigned long owner = obs_thread_id();
    int private_claim = 0;
    int rc = NATIVE_CONFIG_REFUSED_STATUS;
    int stock_err = NATIVE_CONFIG_REFUSED_STATUS;
    if (altscreen_runtime_ensure_initialized)
        altscreen_runtime_ensure_initialized();
    if (!g_real_screen_copy_main)
        g_real_screen_copy_main = (f_screen_copy_main_t)
            native_direct_stock("ScreenCopyMain");
    if (!g_real_screen_copy_main) (void)p1404_cockpit_native_bind_stock();
    if (!g_real_screen_copy_main) {
        if (out_err) *out_err = NATIVE_CONFIG_REFUSED_STATUS;
        return NULL;
    }
    if (altscreen_runtime_is_ready && !altscreen_runtime_is_ready())
        return g_real_screen_copy_main(out_err);
    native_lock();
    if (g_start_claim.active && g_start_claim.owner_thread == owner) {
        receiver = g_start_claim.receiver;
        private_claim = 1;
    }
    native_unlock();
    if (!private_claim) return g_real_screen_copy_main(out_err);

    /* StartSession does not consume a display-info dictionary here. It calls
     * ScreenCopyDelegates on the returned object and therefore requires a real
     * stock Screen runtime instance (80 bytes on K1004), with delegates at
     * +0x3c. Returning the /info dictionary directly is an ABI violation. */
    if (!g_real_screen_create)
        g_real_screen_create = (f_screen_create_t)native_direct_stock("ScreenCreate");
    if (!g_real_screen_copy_delegates)
        g_real_screen_copy_delegates = (f_screen_copy_delegates_t)
            native_direct_stock("ScreenCopyDelegates");
    if (!g_real_screen_register_delegates)
        g_real_screen_register_delegates = (f_screen_register_delegates_t)
            native_direct_stock("ScreenRegisterDelegates");
    if (!g_real_screen_create || !g_real_screen_copy_delegates ||
        !g_real_screen_register_delegates) goto fail;

    display_descriptor = alt_build_cluster_display();
    if (!display_descriptor) goto fail;
    rc = g_real_screen_create(&alt_screen, display_descriptor);
    alt_airplay_release_object(display_descriptor);
    display_descriptor = NULL;
    if (rc != 0 || !alt_screen) goto fail;

    memset(delegates, 0, sizeof(delegates));
    stock_main = g_real_screen_copy_main(&stock_err);
    if (!stock_main || stock_err != 0) goto fail;
    rc = g_real_screen_copy_delegates(stock_main, delegates);
    alt_airplay_release_object(stock_main);
    stock_main = NULL;
    if (rc != 0) goto fail;
    g_real_screen_register_delegates(alt_screen, delegates);

    if (out_err) *out_err = 0;
    altscreen_log("PHASE=NATIVE_111_PRIVATE_SCREEN_COPY receiver=%p owner_thread=%lu screen=%p type=111 runtime_object=ScreenCreate delegates=stock_main geometry=runtime_display1 stock_main_mutated=0",
                  receiver, owner, alt_screen);
    return alt_screen;

fail:
    if (stock_main) alt_airplay_release_object(stock_main);
    if (display_descriptor) alt_airplay_release_object(display_descriptor);
    if (alt_screen) alt_airplay_release_object(alt_screen);
    if (out_err) *out_err = rc != 0 ? rc : NATIVE_CONFIG_REFUSED_STATUS;
    altscreen_log("ERROR PHASE=NATIVE_111_PRIVATE_SCREEN_COPY receiver=%p owner_thread=%lu result=REFUSED rc=%d stock_err=%d runtime_screen_required=1 stock_main_mutated=0",
                  receiver, owner, rc, stock_err);
    return NULL;
}

static int finalize_private_attach(void *receiver, void *stream) {
    struct native_slot *slot;
    struct native_thread_job *monitor_job;
    native_pthread_t monitor = 0;
    uint32_t generation = 0;
    void *video_impl = NULL, *renderer = NULL;
    int rc;
    monitor_job = (struct native_thread_job *)calloc(1u, sizeof(*monitor_job));
    if (!monitor_job) return 0;
    native_lock();
    slot = find_stream_locked(receiver, stream);
    if (slot && slot->owner_thread == obs_thread_id() && slot->renderer &&
        slot->preconfig_rewritten && !slot->monitor_started) {
        slot->monitor_started = 1;
        generation = slot->generation;
        video_impl = slot->video_impl;
        renderer = slot->renderer;
        monitor_job->slot = slot;
        monitor_job->receiver = receiver;
        monitor_job->stream = stream;
        monitor_job->generation = generation;
        monitor_job->state_generation = slot->state_generation;
    } else slot = NULL;
    native_unlock();
    if (!slot) {
        free(monitor_job);
        return 0;
    }
    rc = g_pthread_create && g_pthread_detach ?
        g_pthread_create(&monitor, NULL, native_monitor_worker, monitor_job) : -1;
    if (rc != 0) {
        native_lock();
        slot = find_stream_locked(receiver, stream);
        if (slot && slot->generation == generation) slot->monitor_started = 0;
        native_unlock();
        free(monitor_job);
        altscreen_log("ERROR PHASE=NATIVE_111_ATTACH receiver=%p stream=%p result=REFUSED monitor_thread_rc=%d source59_fallthrough_blocked=1",
                      receiver, stream, rc);
        return 0;
    }
    (void)g_pthread_detach(monitor);
    altscreen_log("PHASE=NATIVE_111_ATTACH receiver=%p stream=%p video_impl=%p renderer=%p displayable=58 first_config_rewritten=1 main110_untouched=1 capture=0 rfb=0 scaling=0 fixed_geometry=0",
                  receiver, stream, video_impl, renderer);
    return 1;
}

/* ScreenStreamStart is called through libairplay's PLT after ScreenStreamCreate.
 * Stock initializes the video implementation and invokes its first config inside
 * this call. A staged, thread-qualified slot lets the config interposer bind the
 * newly-created renderer before that first config reaches displayable 59. */
int ScreenStreamStart(void *stream) {
    void *receiver = NULL;
    unsigned long owner = obs_thread_id();
    int private_claim = 0;
    int staged = 0;
    int attached = 0;
    int rc;
    if (altscreen_runtime_ensure_initialized)
        altscreen_runtime_ensure_initialized();
    if (!g_real_stream_start)
        g_real_stream_start = (f_screen_stream_start_t)
            native_direct_stock("ScreenStreamStart");
    if (!g_real_stream_start) (void)p1404_cockpit_native_bind_stock();
    if (!g_real_stream_start) return NATIVE_CONFIG_REFUSED_STATUS;
    if (altscreen_runtime_is_ready && !altscreen_runtime_is_ready())
        return g_real_stream_start(stream);
    native_lock();
    if (g_start_claim.active && !g_start_claim.invoked &&
        g_start_claim.owner_thread == owner) {
        g_start_claim.invoked = 1;
        g_start_claim.stream = stream;
        receiver = g_start_claim.receiver;
        private_claim = 1;
    }
    native_unlock();
    if (!private_claim) return g_real_stream_start(stream);

    staged = p1404_cockpit_native_attach(receiver, stream);
    if (!staged) {
        altscreen_log("ERROR PHASE=NATIVE_111_PRECONFIG_ATTACH receiver=%p stream=%p result=REFUSED stock_start_called=0 main110_untouched=1",
                      receiver, stream);
        return NATIVE_CONFIG_REFUSED_STATUS;
    }
    altscreen_log("PHASE=NATIVE_111_PRECONFIG_ATTACH receiver=%p stream=%p result=STAGED stock_start_called=1 main110_untouched=1",
                  receiver, stream);
    rc = g_real_stream_start(stream);
    if (rc == 0) attached = finalize_private_attach(receiver, stream);
    if (rc != 0 || !attached) {
        p1404_cockpit_native_detach(receiver, stream);
        if (rc == 0) rc = NATIVE_CONFIG_REFUSED_STATUS;
    }
    native_lock();
    if (g_start_claim.active && g_start_claim.receiver == receiver &&
        g_start_claim.owner_thread == owner && g_start_claim.stream == stream)
        g_start_claim.attached = attached;
    native_unlock();
    altscreen_log("%s PHASE=NATIVE_111_PRECONFIG_COMPLETE receiver=%p stream=%p stock_rc=%d attached=%d first_config_rewritten=%d main110_untouched=1",
                  attached ? "" : "ERROR", receiver, stream, rc, attached, attached);
    return rc;
}

int p1404_cockpit_native_attach(void *receiver, void *stream) {
    struct native_slot *slot;
    struct altscreen_ctx state_snap;
    uint32_t width = 0, height = 0;
    void *video_impl, *renderer;
    uint32_t assigned_generation = 0;
    memset(&state_snap, 0, sizeof(state_snap));
    if (!receiver || !stream || !p1404_mutate_armed) return 0;
    if (!p1404_cockpit_native_bind_stock()) return 0;
    if (!alt_state_snapshot(receiver, 1, &state_snap) || !state_snap.generation) {
        altscreen_log("ERROR PHASE=NATIVE_111_ATTACH_STAGE receiver=%p stream=%p result=REFUSED state_generation_unavailable=1", receiver, stream);
        return 0;
    }
    if (!p1404_cockpit_native_get_geometry(&width, &height) &&
        !p1404_cockpit_native_refresh_geometry()) return 0;
    (void)p1404_cockpit_native_get_geometry(&width, &height);
    video_impl = read_ptr_at(stream, SCREEN_STREAM_VIDEO_IMPL_OFF);
    renderer = read_ptr_at(video_impl, OMX_VIDEO_RENDERER_OFF);
    if (!video_impl) {
        altscreen_log("ERROR PHASE=NATIVE_111_ATTACH_STAGE receiver=%p stream=%p video_impl=%p result=REFUSED source59_fallthrough_blocked=1",
                      receiver, stream, video_impl);
        return 0;
    }

    native_lock();
    slot = find_stream_locked(receiver, stream);
    if (!slot) slot = free_slot_locked();
    if (slot) {
        memset(slot, 0, sizeof(*slot));
        slot->receiver = receiver;
        slot->stream = stream;
        slot->video_impl = video_impl;
        slot->renderer = renderer;
        slot->owner_thread = obs_thread_id();
        slot->generation = ++g_generation;
        if (!slot->generation) slot->generation = ++g_generation;
        slot->state_generation = state_snap.generation;
        assigned_generation = slot->generation;
    }
    native_unlock();
    if (!slot) {
        altscreen_log("ERROR PHASE=NATIVE_111_ATTACH_STAGE receiver=%p stream=%p result=REFUSED route_slots_full=1 source59_fallthrough_blocked=1",
                      receiver, stream);
        return 0;
    }
    altscreen_log("PHASE=NATIVE_111_ATTACH_STAGE receiver=%p stream=%p video_impl=%p renderer_before_start=%p generation=%u state_generation=%u requested_geometry=%ux%u first_config_pending=1",
                  receiver, stream, video_impl, renderer, assigned_generation,
                  state_snap.generation, width, height);
    return 1;
}

void p1404_cockpit_native_detach(void *receiver, void *stream) {
    struct native_slot *slot;
    uint32_t generation = 0;
    uint32_t state_generation = 0;
    int send_stop = 0;
    int restore = 0;
    int restored = 0;
    native_lock();
    slot = find_stream_locked(receiver, stream);
    if (slot) {
        generation = slot->generation;
        state_generation = slot->state_generation;
        send_stop = slot->monitor_started;
        restore = slot->visible ||
                  (slot->action_pending && slot->action == NATIVE_ROUTE_ACTIVATE);
        slot->stream = NULL;
        slot->receiver = NULL;
        slot->renderer = NULL;
        ++slot->generation;
    }
    native_unlock();
    if (generation) p111_direct_tap_stream_end(stream);
    if (generation && send_stop)
        (void)alt_send_cluster_event(receiver, stream, generation,
                                     ALT111_EVENT_STOP_UI);
    if (restore) {
        route_lock();
        /* A pending old activation either completed and restored itself before
         * we acquired this lock, or will observe the invalidated generation
         * after release and perform no display mutation. Only the generation
         * that actually owns context76 may restore it here. */
        if (g_route_generation == generation) {
            restored = run_restore_route();
            if (restored) g_route_generation = 0;
        }
        route_unlock();
    }
    if (restored)
        alt_state_mark_native(receiver, state_generation,
                              ALT_STATE_NATIVE_COCKPIT_HIDDEN,
                              "private111-detach-restored-context74");
    altscreen_log("PHASE=NATIVE_111_DETACH receiver=%p stream=%p restore=%d restored=%d",
                  receiver, stream, restore, restored);
}

#ifdef ALTSCREEN_NATIVE_HOST_TEST
void p1404_cockpit_native_test_route_reset(void) {
    native_lock();
    memset(g_native, 0, sizeof(g_native));
    memset(&g_managed_config, 0, sizeof(g_managed_config));
    g_generation = 0;
    native_unlock();
    route_lock();
    g_route_generation = 0;
    route_unlock();
}
int p1404_cockpit_native_test_route_seed(void *receiver, void *stream,
                                         uint32_t generation,
                                         uint32_t state_generation) {
    struct native_slot *slot;
    int ok = 0;
    native_lock();
    slot = free_slot_locked();
    if (slot && receiver && stream && generation && state_generation) {
        memset(slot, 0, sizeof(*slot));
        slot->receiver = receiver;
        slot->stream = stream;
        slot->generation = generation;
        slot->state_generation = state_generation;
        ok = 1;
    }
    native_unlock();
    return ok;
}
int p1404_cockpit_native_test_route_request(void *receiver, void *stream,
                                            int action) {
    struct native_slot *slot;
    native_lock();
    slot = find_stream_locked(receiver, stream);
    native_unlock();
    return request_route_action(slot, action);
}
int p1404_cockpit_native_test_route_visible(void *receiver, void *stream) {
    struct native_slot *slot;
    int visible = 0;
    native_lock();
    slot = find_stream_locked(receiver, stream);
    if (slot) visible = slot->visible;
    native_unlock();
    return visible;
}
#endif

/* CScreenRender submits its fixed static group as a delayed Screen operation.
 * For the thread-qualified private renderer, suppress only that group request.
 * Main110 and every unrelated caller keep the stock group and behavior. */
int screen_create_window_group(screen_window_t window, const char *name) {
    int private_config = 0;
    if (!g_screen_create_window_group) (void)bind_screen_native_api();
    native_lock();
    if (g_managed_config.active &&
        g_managed_config.owner_thread == obs_thread_id()) {
        g_managed_config.window = window;
        g_managed_config.group_skipped = 1;
        private_config = 1;
    }
    native_unlock();
    if (private_config) return window && name ? 0 : -1;
    return g_screen_create_window_group ?
        g_screen_create_window_group(window, name) : -1;
}

/* At this call all stock window properties, including displayable 58, NV12,
 * usage and native geometry, are already present. Register that exact window
 * through the DisplayManager handshake used by MMI Cockpit Mirror 2.2, then
 * let stock allocate and own its decoder buffers. */
int screen_create_window_buffers(screen_window_t window, int count) {
    int private_config = 0;
    int group_skipped = 0;
    int manage_rc = -1;
    int buffers_rc;
    if (!g_screen_create_window_buffers || !g_screen_manage_window)
        (void)bind_screen_native_api();
    native_lock();
    if (g_managed_config.active &&
        g_managed_config.owner_thread == obs_thread_id() &&
        (!g_managed_config.window || g_managed_config.window == window)) {
        g_managed_config.window = window;
        group_skipped = g_managed_config.group_skipped;
        private_config = 1;
    }
    native_unlock();
    if (!private_config)
        return g_screen_create_window_buffers ?
            g_screen_create_window_buffers(window, count) : -1;
    if (group_skipped && g_screen_manage_window)
        manage_rc = g_screen_manage_window(window, DISPLAY_MANAGER_SECRET);
    if (manage_rc != 0) {
        native_lock();
        g_managed_config.manage_rc = manage_rc;
        native_unlock();
        return manage_rc;
    }
    buffers_rc = g_screen_create_window_buffers ?
        g_screen_create_window_buffers(window, count) : -1;
    native_lock();
    g_managed_config.manage_rc = manage_rc;
    g_managed_config.buffers_rc = buffers_rc;
    g_managed_config.managed = buffers_rc == 0;
    native_unlock();
    return buffers_rc;
}

/* Exported with the exact C++ names used by libairplay's PLT. */
int p1404_hook_cscreen_config(void *self, const struct p1404_screen_config *config)
    __asm__(CSCREEN_CONFIG_SYMBOL);
int p1404_hook_cscreen_config(void *self, const struct p1404_screen_config *config) {
    struct p1404_screen_config native_config;
    struct native_slot *slot;
    void *receiver = NULL;
    void *stream = NULL;
    uint32_t target_width = 0, target_height = 0;
    uint32_t generation = 0;
    uint32_t state_generation = 0;
    int owned_private = 0;
    int rewritten = 0;
    int geometry_match = 0;
    int managed_scope = 0;
    int managed_ok = 0;
    int group_skipped = 0;
    int manage_rc = -1;
    int buffers_rc = -1;
    int rc;

    if (altscreen_runtime_ensure_initialized)
        altscreen_runtime_ensure_initialized();
    if (!g_real_config)
        g_real_config = (f_cscreen_config_t)
            native_direct_stock(CSCREEN_CONFIG_SYMBOL);
    if (!g_real_config) (void)p1404_cockpit_native_bind_stock();
    if (!g_real_config) return -1;
    if (altscreen_runtime_is_ready && !altscreen_runtime_is_ready())
        return g_real_config(self, config);
    native_lock();
    slot = find_renderer_locked(self);
    if (!slot) {
        slot = find_preconfig_locked(self, obs_thread_id());
        if (slot) {
            slot->renderer = self;
            altscreen_log("PHASE=NATIVE_111_RENDERER_BOUND_PRECONFIG receiver=%p stream=%p renderer=%p owner_thread=%lu first_config=1",
                          slot->receiver, slot->stream, self, obs_thread_id());
        }
    }
    if (slot) {
        receiver = slot->receiver;
        stream = slot->stream;
        generation = slot->generation;
        state_generation = slot->state_generation;
        owned_private = 1;
    }
    native_unlock();
    if (owned_private)
        rewritten = p1404_cockpit_native_rewrite_config(config, &native_config);
    if (owned_private && !rewritten) {
        altscreen_log("ERROR PHASE=NATIVE_111_CONFIG_REFUSED receiver=%p stream=%p renderer=%p source=%ux%u runtime_geometry_unavailable_or_invalid=1 main110_untouched=1",
                      receiver, stream, self,
                      config ? config->source_width : 0u,
                      config ? config->source_height : 0u);
        return NATIVE_CONFIG_REFUSED_STATUS;
    }
    if (rewritten) {
        native_lock();
        if (!g_managed_config.active) {
            memset(&g_managed_config, 0, sizeof(g_managed_config));
            g_managed_config.renderer = self;
            g_managed_config.owner_thread = obs_thread_id();
            g_managed_config.active = 1;
            managed_scope = 1;
        }
        native_unlock();
        if (!managed_scope) {
            altscreen_log("ERROR PHASE=NATIVE_111_MANAGED_WINDOW_SCOPE receiver=%p stream=%p renderer=%p result=REFUSED concurrent_private_config=1 main110_untouched=1",
                          receiver, stream, self);
            return NATIVE_CONFIG_REFUSED_STATUS;
        }
    }
    rc = g_real_config(self, rewritten ? &native_config : config);
    if (managed_scope) {
        native_lock();
        group_skipped = g_managed_config.group_skipped;
        manage_rc = g_managed_config.manage_rc;
        buffers_rc = g_managed_config.buffers_rc;
        managed_ok = g_managed_config.managed;
        memset(&g_managed_config, 0, sizeof(g_managed_config));
        native_unlock();
        altscreen_log("PHASE=NATIVE_111_MANAGED_WINDOW receiver=%p stream=%p renderer=%p group_skipped=%d manage_rc=%d buffers_rc=%d managed=%d manager=displaymanager stock_buffer_owner=1 compat_decoder_staging=1 direct_sink_window58=0",
                      receiver, stream, self, group_skipped, manage_rc,
                      buffers_rc, managed_ok);
        if (rc == 0 && !managed_ok) rc = NATIVE_CONFIG_REFUSED_STATUS;
    }
    if (rewritten) {
        (void)p1404_cockpit_native_get_geometry(&target_width, &target_height);
        geometry_match = native_config.source_width == target_width &&
                         native_config.source_height == target_height;
        altscreen_log("PHASE=NATIVE_111_CONFIG_RETURN receiver=%p stream=%p renderer=%p rc=%d input=%ux%u_source_%ux%u output=%ux%u_source_%ux%u target=%ux%u geometry_match=%d displayable=58 format=%u usage=0x%x scaling=0 fixed_geometry=0 dm_managed=%d",
                      receiver, stream, self, rc,
                      config ? config->window_width : 0u,
                      config ? config->window_height : 0u,
                      config ? config->source_width : 0u,
                      config ? config->source_height : 0u,
                      native_config.window_width, native_config.window_height,
                      native_config.source_width, native_config.source_height,
                      target_width, target_height, geometry_match,
                      native_config.format, native_config.usage, managed_ok);
        if (rc == 0) {
            native_lock();
            slot = find_renderer_locked(self);
            if (slot && slot->stream == stream &&
                slot->generation == generation) {
                slot->preconfig_rewritten = 1;
                slot->config_ok = geometry_match;
                slot->config_width = native_config.source_width;
                slot->config_height = native_config.source_height;
                slot->config_format = native_config.format;
                slot->config_usage = native_config.usage;
                slot->first_real_frame_posted = 0;
                if (slot->keyframe_event_state == 2)
                    slot->keyframe_event_state = 0;
            }
            native_unlock();
            if (geometry_match) {
                alt_state_mark_native(receiver, state_generation,
                    ALT_STATE_NATIVE_VIDEO_CONFIG,
                    "stock-omx-cscreen-config-dynamic-geometry-displayable58");
            } else {
                altscreen_log("PHASE=NATIVE_111_CONFIG_WAIT_NEGOTIATED_GEOMETRY receiver=%p stream=%p renderer=%p current=%ux%u target=%ux%u route_ready=0",
                              receiver, stream, self, native_config.source_width,
                              native_config.source_height, target_width, target_height);
            }
        }
    }
    return rc;
}

int p1404_hook_cscreen_render(void *self, unsigned char *buffer)
    __asm__(CSCREEN_RENDER_SYMBOL);
int p1404_hook_cscreen_render(void *self, unsigned char *buffer) {
    struct native_slot *slot;
    struct altscreen_ctx snap;
    void *receiver = NULL;
    void *stream = NULL;
    uint64_t now;
    uint64_t first_post_at = 0;
    uint32_t posts = 0;
    uint32_t generation = 0;
    uint32_t state_generation = 0;
    uint32_t config_width = 0;
    uint32_t config_height = 0;
    uint32_t config_format = 0;
    uint32_t config_usage = 0;
    int config_ok = 0;
    int owned_private = 0;
    int first_real_post = 0;
    int should_mark = 0;
    int rc;

    if (altscreen_runtime_ensure_initialized)
        altscreen_runtime_ensure_initialized();
    if (!g_real_render)
        g_real_render = (f_cscreen_render_t)
            native_direct_stock(CSCREEN_RENDER_SYMBOL);
    if (!g_real_render) (void)p1404_cockpit_native_bind_stock();
    if (!g_real_render) return -1;
    if (altscreen_runtime_is_ready && !altscreen_runtime_is_ready())
        return g_real_render(self, buffer);

    native_lock();
    slot = find_renderer_locked(self);
    if (slot) {
        owned_private = 1;
        receiver = slot->receiver;
        stream = slot->stream;
        generation = slot->generation;
        state_generation = slot->state_generation;
        config_ok = slot->config_ok;
        config_width = slot->config_width;
        config_height = slot->config_height;
        config_format = slot->config_format;
        config_usage = slot->config_usage;
    }
    native_unlock();

    /*
     * Direct-display V2 deliberately lets stock render first.  The decoded
     * pointer is Screen format 0x0001000c on the tested i.MX6 firmware and V1
     * proved that treating it as row-linear NV12 produces the moving garbled
     * picture.  After stock posts the exact buffer, ask Screen to linearize the
     * renderer's own window into a normal pixmap.
     *
     * Main110 never enters this branch because ownership is bound to the
     * private stream.  Stock rendering remains the authoritative fail-open
     * path and is never suppressed by the V2 linearizer.
     */
    rc = g_real_render(self, buffer);
    if (rc != 0 || !owned_private || !config_ok) return rc;

    if (stream && buffer && config_width && config_height) {
        void *stock_window = read_ptr_at(self, CSCREEN_WINDOW_OFF);
        if (!p111_frame_tap_write_window(stream, stock_window,
                                         config_width, config_height,
                                         config_format, config_usage)) {
            /*
             * Diagnostic fail-open only: if Screen screenshot/linearization is
             * unavailable, preserve the V1 raw tap so the session and its
             * moving-frame evidence are not lost.  A visible garbled fallback
             * is explicitly not a V2 pixel-success result.
             */
            p111_frame_tap_write(stream, buffer,
                                 config_width, config_height,
                                 config_format, config_usage);
            altscreen_log("WARN PHASE=FRAME_LINEARIZER_RAW_FALLBACK stream=%p renderer=%p window=%p format=%u usage=0x%x stock_render_rc=%d",
                          stream, self, stock_window,
                          config_format, config_usage, rc);
        }
    }

    now = obs_now_us();
    native_lock();
    slot = find_renderer_locked(self);
    if (slot && slot->generation == generation && slot->stream == stream) {
        if (!slot->first_real_frame_posted) {
            slot->first_real_frame_posted = 1;
            first_real_post = 1;
        }
        if (!slot->posts ||
            (slot->last_post_at && now > slot->last_post_at + NATIVE_STALL_SECONDS)) {
            slot->posts = 0;
            slot->first_post_at = now;
            slot->decoder_marked = 0;
        }
        ++slot->posts;
        slot->last_post_at = now;
        posts = slot->posts;
        first_post_at = slot->first_post_at;
    }
    native_unlock();

    if (first_real_post)
        altscreen_log("PHASE=NATIVE_111_FIRST_REAL_FRAME receiver=%p stream=%p renderer=%p generation=%u result=POSTED geometry=%ux%u route_gate=eligible",
                      receiver, stream, self, generation, config_width, config_height);

    memset(&snap, 0, sizeof(snap));
    if (!alt_state_snapshot(receiver, 1, &snap) ||
        snap.generation != generation || snap.alt_screen_stream != stream)
        return rc;
    if (posts >= NATIVE_MIN_POSTS && snap.video_config_seen &&
        now <= first_post_at + NATIVE_POST_WINDOW_SECONDS) {
        native_lock();
        slot = find_renderer_locked(self);
        if (slot && slot->generation == generation && !slot->decoder_marked) {
            slot->decoder_marked = 1;
            should_mark = 1;
        }
        native_unlock();
    }
    if (should_mark) {
        alt_state_mark_native(receiver, state_generation,
            ALT_STATE_NATIVE_DECODER_READY,
            "private111-stock-omx-three-successful-posts-stock-avcc-config-observed");
        altscreen_log("PHASE=NATIVE_111_DECODER_READY receiver=%p stream=%p renderer=%p posts=%u sps=%u pps=%u idr=%u negotiated_geometry=%ux%u fixed_geometry=0 bitstream=stock_avcc annexb_observer_optional=1",
                      receiver, stream, self, posts, snap.nal_sps, snap.nal_pps,
                      snap.nal_idr, config_width, config_height);
    }
    return rc;
}
