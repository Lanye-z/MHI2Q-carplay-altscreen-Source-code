/*
 * OEM plane 33/58 census for Audi MHI2Q.
 *
 * Read-only design:
 *   - creates only a SCREEN_DISPLAY_MANAGER_CONTEXT;
 *   - enumerates existing windows;
 *   - calls screen_get_* APIs only;
 *   - never creates/manages/destroys a window and never sets a property.
 */
#include <dlfcn.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define CENSUS_SCHEMA "OEM_PLANE33_58_CENSUS_V1_1"

#define SCR_DISPLAY_MANAGER_CONTEXT       8
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
#define SCR_PROP_USAGE                    48
#define SCR_PROP_VISIBLE                  51
#define SCR_PROP_SCALE_QUALITY            56
#define SCR_PROP_SOURCE_CLIP_POSITION     68
#define SCR_PROP_SOURCE_CLIP_SIZE         72
#define SCR_PROP_WINDOW_COUNT            108
#define SCR_PROP_WINDOWS                 109
#define SCR_PROP_SCALE_FACTOR            114
#define SCR_PROP_MANAGER_STRING          152

typedef void *scr_context_t;
typedef void *scr_window_t;
typedef void *scr_buffer_t;
typedef void *scr_display_t;
typedef void *scr_group_t;

typedef int (*fn_create_context)(scr_context_t *, int);
typedef int (*fn_destroy_context)(scr_context_t);
typedef int (*fn_get_context_iv)(scr_context_t, int, int *);
typedef int (*fn_get_context_pv)(scr_context_t, int, void **);
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
    fn_get_context_iv get_context_iv;
    fn_get_context_pv get_context_pv;
    fn_get_window_iv get_window_iv;
    fn_get_window_pv get_window_pv;
    fn_get_window_cv get_window_cv;
    fn_get_buffer_iv get_buffer_iv;
    fn_get_display_cv get_display_cv;
    fn_get_group_cv get_group_cv;
};

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
    a->get_context_iv = (fn_get_context_iv)sym(a->lib, "screen_get_context_property_iv");
    a->get_context_pv = (fn_get_context_pv)sym(a->lib, "screen_get_context_property_pv");
    a->get_window_iv = (fn_get_window_iv)sym(a->lib, "screen_get_window_property_iv");
    a->get_window_pv = (fn_get_window_pv)sym(a->lib, "screen_get_window_property_pv");
    a->get_window_cv = (fn_get_window_cv)sym(a->lib, "screen_get_window_property_cv");
    a->get_buffer_iv = (fn_get_buffer_iv)sym(a->lib, "screen_get_buffer_property_iv");
    a->get_display_cv = (fn_get_display_cv)sym(a->lib, "screen_get_display_property_cv");
    a->get_group_cv = (fn_get_group_cv)sym(a->lib, "screen_get_group_property_cv");
    if (!a->create_context || !a->destroy_context ||
        !a->get_context_iv || !a->get_context_pv ||
        !a->get_window_iv || !a->get_window_pv || !a->get_window_cv) {
        fprintf(stderr, "ERROR required libscreen read API missing\n");
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

static void print_iv1(struct api *a, scr_window_t w, int prop, const char *name) {
    int v = 0x5a5a5a5a, rc, e;
    errno = 0;
    rc = a->get_window_iv(w, prop, &v);
    e = errno;
    if (rc == 0) printf("%s=%d rc=0\n", name, v);
    else printf("%s=NA rc=%d errno=%d\n", name, rc, e);
}

static void print_iv2(struct api *a, scr_window_t w, int prop, const char *name) {
    int v[2] = { 0x5a5a5a5a, 0x5a5a5a5a }, rc, e;
    errno = 0;
    rc = a->get_window_iv(w, prop, v);
    e = errno;
    if (rc == 0) printf("%s=%d,%d rc=0\n", name, v[0], v[1]);
    else printf("%s=NA rc=%d errno=%d\n", name, rc, e);
}

static void print_cv(struct api *a, scr_window_t w, int prop,
                     const char *name, int len) {
    char buf[192];
    int rc, e;
    if (len > (int)sizeof(buf) - 1) len = (int)sizeof(buf) - 1;
    memset(buf, 0, sizeof(buf));
    errno = 0;
    rc = a->get_window_cv(w, prop, len, buf);
    e = errno;
    buf[sizeof(buf) - 1] = 0;
    if (rc == 0) printf("%s='%s' rc=0\n", name, buf);
    else printf("%s=NA rc=%d errno=%d\n", name, rc, e);
}

static void print_buffer(struct api *a, scr_buffer_t b, int index) {
    int v1, v2[3], rc, e;
    printf("buffer_%d_handle=%p\n", index, b);
    if (!a->get_buffer_iv || !b) {
        printf("buffer_%d_properties=NA reason=get_buffer_iv_or_handle_missing\n", index);
        return;
    }

    v2[0] = v2[1] = v2[2] = 0;
    errno = 0; rc = a->get_buffer_iv(b, SCR_PROP_BUFFER_SIZE, v2); e = errno;
    if (rc == 0) printf("buffer_%d_size=%d,%d rc=0\n", index, v2[0], v2[1]);
    else printf("buffer_%d_size=NA rc=%d errno=%d\n", index, rc, e);

    v1 = 0;
    errno = 0; rc = a->get_buffer_iv(b, SCR_PROP_FORMAT, &v1); e = errno;
    if (rc == 0) printf("buffer_%d_format=%d rc=0\n", index, v1);
    else printf("buffer_%d_format=NA rc=%d errno=%d\n", index, rc, e);

    v1 = 0;
    errno = 0; rc = a->get_buffer_iv(b, SCR_PROP_STRIDE, &v1); e = errno;
    if (rc == 0) printf("buffer_%d_stride=%d rc=0\n", index, v1);
    else printf("buffer_%d_stride=NA rc=%d errno=%d\n", index, rc, e);

    v2[0] = v2[1] = v2[2] = 0;
    errno = 0; rc = a->get_buffer_iv(b, SCR_PROP_PLANAR_OFFSETS, v2); e = errno;
    if (rc == 0) printf("buffer_%d_planar_offsets=%d,%d,%d rc=0\n",
                        index, v2[0], v2[1], v2[2]);
    else printf("buffer_%d_planar_offsets=NA rc=%d errno=%d\n", index, rc, e);
}

static void print_related_objects(struct api *a, scr_window_t w) {
    void *p = NULL;
    int rc, e;
    errno = 0;
    rc = a->get_window_pv(w, SCR_PROP_GROUP, &p); e = errno;
    if (rc == 0) {
        printf("group_handle=%p rc=0\n", p);
        if (p && a->get_group_cv) {
            char name[192];
            memset(name, 0, sizeof(name));
            errno = 0;
            rc = a->get_group_cv((scr_group_t)p, SCR_PROP_NAME,
                                 (int)sizeof(name) - 1, name); e = errno;
            if (rc == 0) printf("group_name='%s' rc=0\n", name);
            else printf("group_name=NA rc=%d errno=%d\n", rc, e);
        } else printf("group_name=NA reason=group_cv_unavailable\n");
    } else printf("group_handle=NA rc=%d errno=%d\n", rc, e);

    p = NULL;
    errno = 0;
    rc = a->get_window_pv(w, SCR_PROP_DISPLAY, &p); e = errno;
    if (rc == 0) {
        printf("display_handle=%p rc=0\n", p);
        if (p && a->get_display_cv) {
            char id[192];
            memset(id, 0, sizeof(id));
            errno = 0;
            rc = a->get_display_cv((scr_display_t)p, SCR_PROP_ID_STRING,
                                   (int)sizeof(id) - 1, id); e = errno;
            if (rc == 0) printf("display_id_string='%s' rc=0\n", id);
            else printf("display_id_string=NA rc=%d errno=%d\n", rc, e);
        } else printf("display_id_string=NA reason=display_cv_unavailable\n");
    } else printf("display_handle=NA rc=%d errno=%d\n", rc, e);

    printf("parent=UNAVAILABLE_IN_QNX650_WINDOW_API\n");
    printf("viewport=UNAVAILABLE_AS_STANDARD_QNX650_WINDOW_PROPERTY\n");
}

static void print_buffers(struct api *a, scr_window_t w) {
    int count = 0, rc, e, i;
    void **buffers;
    errno = 0;
    rc = a->get_window_iv(w, SCR_PROP_BUFFER_COUNT, &count); e = errno;
    if (rc != 0) {
        printf("buffer_count=NA rc=%d errno=%d\n", rc, e);
        return;
    }
    printf("buffer_count=%d rc=0\n", count);
    if (count <= 0 || count > 16) {
        if (count > 16) printf("render_buffers=SKIPPED reason=unexpected_count\n");
        return;
    }
    buffers = (void **)calloc((size_t)count, sizeof(void *));
    if (!buffers) {
        printf("render_buffers=NA reason=oom\n");
        return;
    }
    errno = 0;
    rc = a->get_window_pv(w, SCR_PROP_RENDER_BUFFERS, buffers); e = errno;
    if (rc != 0) {
        printf("render_buffers=NA rc=%d errno=%d\n", rc, e);
        free(buffers);
        return;
    }
    for (i = 0; i < count; ++i) print_buffer(a, (scr_buffer_t)buffers[i], i);
    free(buffers);
}

static int target_id(const char *id) {
    return id && (!strcmp(id, "33") || !strcmp(id, "58"));
}

static void print_window(struct api *a, scr_window_t w, int index, const char *id) {
    printf("WINDOW_BEGIN index=%d handle=%p id='%s'\n", index, w, id ? id : "");
    print_iv2(a, w, SCR_PROP_SIZE, "SCREEN_PROPERTY_SIZE");
    print_iv2(a, w, SCR_PROP_BUFFER_SIZE, "SCREEN_PROPERTY_BUFFER_SIZE");
    print_iv2(a, w, SCR_PROP_SOURCE_SIZE, "SCREEN_PROPERTY_SOURCE_SIZE");
    print_iv2(a, w, SCR_PROP_SOURCE_POSITION, "SCREEN_PROPERTY_SOURCE_POSITION");
    print_iv2(a, w, SCR_PROP_POSITION, "SCREEN_PROPERTY_POSITION");
    print_iv1(a, w, SCR_PROP_VISIBLE, "SCREEN_PROPERTY_VISIBLE");
    print_iv1(a, w, SCR_PROP_FORMAT, "SCREEN_PROPERTY_FORMAT");
    print_iv1(a, w, SCR_PROP_OWNER_PID, "SCREEN_PROPERTY_OWNER_PID");
    print_iv1(a, w, SCR_PROP_USAGE, "SCREEN_PROPERTY_USAGE");
    print_iv2(a, w, SCR_PROP_SOURCE_CLIP_POSITION, "SCREEN_PROPERTY_SOURCE_CLIP_POSITION");
    print_iv2(a, w, SCR_PROP_SOURCE_CLIP_SIZE, "SCREEN_PROPERTY_SOURCE_CLIP_SIZE");
    print_iv1(a, w, SCR_PROP_SCALE_FACTOR, "SCREEN_PROPERTY_SCALE_FACTOR");
    print_iv1(a, w, SCR_PROP_SCALE_QUALITY, "SCREEN_PROPERTY_SCALE_QUALITY");
    print_cv(a, w, SCR_PROP_MANAGER_STRING, "SCREEN_PROPERTY_MANAGER_STRING", 191);
    print_related_objects(a, w);
    print_buffers(a, w);
    printf("WINDOW_END index=%d id='%s'\n", index, id ? id : "");
}

static void usage(const char *argv0) {
    fprintf(stderr, "usage: %s --label <Classic_Full|Classic_Small|Sport_Full|Sport_Small> [--all]\n",
            argv0);
}

int main(int argc, char **argv) {
    struct api a;
    scr_context_t ctx = NULL;
    void **windows = NULL;
    int count = 0, rc, e, i, matches33 = 0, matches58 = 0;
    const char *label = NULL;
    int show_all = 0;
    time_t now = time(NULL);

    for (i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--label") && i + 1 < argc) label = argv[++i];
        else if (!strcmp(argv[i], "--all")) show_all = 1;
        else { usage(argv[0]); return 64; }
    }
    if (!label || !*label) { usage(argv[0]); return 64; }

    printf("CENSUS_BEGIN schema=%s label=%s epoch=%lu mode=READ_ONLY\n",
           CENSUS_SCHEMA, label, (unsigned long)now);
    printf("safety=no_screen_set no_window_create no_window_manage no_context_switch no_carplay_hook\n");

    if (open_api(&a) != 0) {
        printf("CENSUS_END result=FAIL reason=libscreen_api\n");
        return 2;
    }

    errno = 0;
    rc = a.create_context(&ctx, SCR_DISPLAY_MANAGER_CONTEXT); e = errno;
    if (rc != 0 || !ctx) {
        printf("display_manager_context=FAIL rc=%d errno=%d\n", rc, e);
        printf("CENSUS_END result=FAIL reason=display_manager_context_required\n");
        close_api(&a);
        return 3;
    }
    printf("display_manager_context=OK handle=%p context_type=%d\n",
           ctx, SCR_DISPLAY_MANAGER_CONTEXT);

    errno = 0;
    rc = a.get_context_iv(ctx, SCR_PROP_WINDOW_COUNT, &count); e = errno;
    if (rc != 0 || count < 0 || count > 4096) {
        printf("window_count=FAIL rc=%d errno=%d value=%d\n", rc, e, count);
        a.destroy_context(ctx);
        close_api(&a);
        printf("CENSUS_END result=FAIL reason=window_count\n");
        return 4;
    }
    printf("window_count=%d rc=0\n", count);

    if (count > 0) {
        windows = (void **)calloc((size_t)count, sizeof(void *));
        if (!windows) {
            a.destroy_context(ctx); close_api(&a);
            printf("CENSUS_END result=FAIL reason=oom_windows\n");
            return 5;
        }
        errno = 0;
        rc = a.get_context_pv(ctx, SCR_PROP_WINDOWS, windows); e = errno;
        if (rc != 0) {
            printf("windows=FAIL rc=%d errno=%d\n", rc, e);
            free(windows); a.destroy_context(ctx); close_api(&a);
            printf("CENSUS_END result=FAIL reason=window_list\n");
            return 6;
        }
    }

    for (i = 0; i < count; ++i) {
        char id[128];
        int idrc;
        if (!windows[i]) continue;
        memset(id, 0, sizeof(id));
        errno = 0;
        idrc = a.get_window_cv((scr_window_t)windows[i], SCR_PROP_ID_STRING,
                               (int)sizeof(id) - 1, id);
        if (idrc != 0) {
            if (show_all) printf("WINDOW_ID_UNREADABLE index=%d handle=%p errno=%d\n",
                                 i, windows[i], errno);
            continue;
        }
        if (!strcmp(id, "33")) ++matches33;
        if (!strcmp(id, "58")) ++matches58;
        if (target_id(id) || show_all) print_window(&a, (scr_window_t)windows[i], i, id);
    }

    printf("target_33_match_count=%d\n", matches33);
    printf("target_58_match_count=%d\n", matches58);
    printf("CENSUS_END result=PASS label=%s targets_found=%d\n",
           label, matches33 + matches58);

    free(windows);
    a.destroy_context(ctx);
    close_api(&a);
    return (matches33 + matches58) > 0 ? 0 : 7;
}
