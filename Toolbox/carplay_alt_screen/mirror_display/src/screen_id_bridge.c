/*
 * Sidecar-only compatibility bridge for the promoted V4 Mirror ELF.
 *
 * The old V4 binary reads SCREEN_PROPERTY_ID through the integer accessor.
 * On MHI2Q the Audi/displayable identity can instead be exposed through the
 * character accessor while the QNX numeric window id is unrelated.
 *
 * For property 87 only, read both forms. If ID_STRING is "58", return integer
 * 58 to the unchanged V4 observer. Every other property is passed through.
 */
typedef unsigned int size_t;

extern void *dlopen(const char *, int);
extern void *dlsym(void *, const char *);
extern int strcmp(const char *, const char *);
extern int snprintf(char *, size_t, const char *, ...);
extern int write(int, const void *, size_t);

#define RTLD_LAZY 1
#define SCREEN_PROPERTY_ID 87

typedef int (*screen_get_iv_fn)(void *, int, int *);
typedef int (*screen_get_cv_fn)(void *, int, int, char *);

static void *g_screen;
static screen_get_iv_fn g_real_iv;
static screen_get_cv_fn g_real_cv;
static int g_bound;
static int g_logged_target;

static void bridge_log_target(int numeric_id, const char *id_string) {
    char line[192];
    int n;
    if (g_logged_target) return;
    g_logged_target = 1;
    n = snprintf(line, sizeof(line),
        "WINDOW58_ID_BRIDGE numeric_id=%d id_string='%s' target=YES match=STRING\n",
        numeric_id, id_string ? id_string : "");
    if (n > 0) {
        size_t len = (size_t)n;
        if (len > sizeof(line)) len = sizeof(line);
        (void)write(2, line, len);
    }
}

static void bind_screen(void) {
    if (g_bound) return;
    g_bound = 1;
    g_screen = dlopen("libscreen.so.1", RTLD_LAZY);
    if (!g_screen) g_screen = dlopen("libscreen.so", RTLD_LAZY);
    if (!g_screen) return;
    g_real_iv = (screen_get_iv_fn)dlsym(g_screen,
        "screen_get_window_property_iv");
    g_real_cv = (screen_get_cv_fn)dlsym(g_screen,
        "screen_get_window_property_cv");
}

int screen_get_window_property_iv(void *window, int property, int *value) {
    int numeric = -1;
    int rc;
    char id_string[64];
    int cv_rc;
    int i;

    bind_screen();
    if (!g_real_iv) return -1;

    if (property != SCREEN_PROPERTY_ID || !value || !g_real_cv) {
        return g_real_iv(window, property, value);
    }

    rc = g_real_iv(window, property, &numeric);
    for (i = 0; i < (int)sizeof(id_string); ++i) id_string[i] = 0;
    cv_rc = g_real_cv(window, SCREEN_PROPERTY_ID,
                      (int)sizeof(id_string) - 1, id_string);

    if (cv_rc == 0 && strcmp(id_string, "58") == 0) {
        *value = 58;
        bridge_log_target(numeric, id_string);
        return 0;
    }

    *value = numeric;
    return rc;
}
