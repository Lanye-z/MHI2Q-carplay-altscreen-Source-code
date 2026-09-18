#include "carplay_window_source.h"
#include "cluster_video_display.h"

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <unistd.h>

static volatile sig_atomic_t g_stop = 0;
static const unsigned kTargetFps = 30;
static const char kBuildId[] = "context80-readback-v1-diag2";

static const char *volatile_path(const char *key, const char *fallback) {
    const char *v = getenv(key);
    return (v && *v) ? v : fallback;
}

static const char *ready_path() {
    return volatile_path("ALT111_MIRROR_READY_FILE",
                         "/tmp/MMI-Cockpit-Carplay/mirror/ready");
}

static const char *base_ready_path() {
    return volatile_path("ALT111_MIRROR_BASE_READY_FILE",
                         "/tmp/MMI-Cockpit-Carplay/mirror/basevideo.ready");
}

static const char *gate_token_path() {
    return volatile_path("ALT111_MIRROR_GATE_TOKEN_FILE",
                         "/tmp/MMI-Cockpit-Carplay/mirror/phone111.gate");
}

static const char *hook_log_path() {
    return volatile_path("ALT111_MIRROR_HOOK_LOG",
                         "/tmp/MMI-Cockpit-Carplay/altscreen_hook.log");
}

static unsigned long long now_us() {
    struct timeval tv;
    if (gettimeofday(&tv, 0) != 0) return 0;
    return (unsigned long long)(unsigned long)tv.tv_sec * 1000000ULL +
           (unsigned long long)(unsigned long)tv.tv_usec;
}

static void on_signal(int) {
    g_stop = 1;
}

static void strip_eol(char *s) {
    size_t n;
    if (!s) return;
    n = strlen(s);
    while (n &&
           (s[n - 1] == '\n' || s[n - 1] == '\r' ||
            s[n - 1] == ' ' || s[n - 1] == '\t')) {
        s[--n] = 0;
    }
}

static void copy_line(char *dst, size_t cap, const char *src) {
    if (!dst || !cap) return;
    if (!src) {
        dst[0] = 0;
        return;
    }
    strncpy(dst, src, cap - 1u);
    dst[cap - 1u] = 0;
    strip_eol(dst);
}

static void load_consumed_gate(char *out, size_t cap) {
    FILE *f;
    if (!out || !cap) return;
    out[0] = 0;
    f = fopen(gate_token_path(), "r");
    if (!f) return;
    if (fgets(out, (int)cap, f)) strip_eol(out);
    fclose(f);
}

static bool persist_gate(const char *line) {
    FILE *f;
    if (!line || !*line) return false;
    f = fopen(gate_token_path(), "w");
    if (!f) return false;
    fprintf(f, "%s\n", line);
    if (fclose(f) != 0) return false;
    return true;
}

/*
 * Do not create a privileged Screen window-manager context at boot.
 *
 * The validated CarPlay/Stream111 hook already emits PHONE_REQUEST_111 once
 * the phone has established the main AirPlay session and explicitly requested
 * the private alternate screen. Follow that log first; only after this gate is
 * observed do we create the Screen WM observer.
 *
 * A complete initial scan is required before accepting a candidate marker:
 * an older PHONE_REQUEST line may exist earlier in the same log, followed by a
 * newer HOOK_INIT for the current dio_manager process.
 */
static bool wait_for_phone111_gate() {
    static const char kFlatHookLog[] = "/tmp/altscreen_hook.log";
    char consumed[1024];
    char candidate[1024];
    char line[1024];
    bool have_hook_init = false;
    bool reported_waiting = false;
    bool reported_consumed = false;
    FILE *f = 0;
    const char *opened_path = 0;

    load_consumed_gate(consumed, sizeof(consumed));
    candidate[0] = 0;

    while (!g_stop) {
        if (!f) {
            const char *primary = hook_log_path();
            f = fopen(primary, "r");
            if (f) {
                opened_path = primary;
            } else if (strcmp(primary, kFlatHookLog) != 0) {
                f = fopen(kFlatHookLog, "r");
                if (f) opened_path = kFlatHookLog;
            }

            if (!f) {
                if (!reported_waiting) {
                    fprintf(stderr,
                            "carplay-mirror: GATE waiting "
                            "for=PHONE_REQUEST_111 screen_context=NOT_CREATED "
                            "hook_log=%s\n",
                            primary);
                    reported_waiting = true;
                }
                usleep(100000);
                continue;
            }

            fprintf(stderr,
                    "carplay-mirror: GATE hook log attached path=%s "
                    "screen_context=NOT_CREATED\n",
                    opened_path ? opened_path : "-");
        }

        bool read_any = false;
        while (fgets(line, sizeof(line), f)) {
            read_any = true;
            strip_eol(line);

            if (strstr(line, "PHASE=HOOK_INIT")) {
                have_hook_init = true;
                candidate[0] = 0;
                reported_consumed = false;
                continue;
            }

            if (have_hook_init &&
                strstr(line, "PHASE=PHONE_REQUEST_111") &&
                strstr(line, "PHONE_REQUESTED_ALTSCREEN=YES")) {
                copy_line(candidate, sizeof(candidate), line);
            }
        }

        if (candidate[0]) {
            if (consumed[0] && strcmp(candidate, consumed) == 0) {
                if (!reported_consumed) {
                    fprintf(stderr,
                            "carplay-mirror: GATE marker already consumed; "
                            "waiting for next PHONE_REQUEST_111 session\n");
                    reported_consumed = true;
                }
            } else {
                /*
                 * Persist before opening Screen. If this sidecar crashes after
                 * acquiring WM privileges, the boot supervisor must not spin
                 * up another WM observer for the same CarPlay request.
                 */
                if (!persist_gate(candidate)) {
                    fprintf(stderr,
                            "carplay-mirror: GATE token write failed path=%s; "
                            "Screen context remains unopened\n",
                            gate_token_path());
                    usleep(100000);
                    continue;
                }

                copy_line(consumed, sizeof(consumed), candidate);
                if (f) {
                    fclose(f);
                    f = 0;
                }
                fprintf(stderr,
                        "carplay-mirror: GATE PASS "
                        "trigger=PHONE_REQUEST_111 "
                        "screen_context=CREATE_NOW\n");
                return true;
            }
        }

        clearerr(f);
        usleep(read_any ? 20000 : 50000);
    }

    if (f) fclose(f);
    return false;
}

/* Marker writes are deliberately best-effort. The launcher may run with /tmp
 * unavailable; runtime presentation must continue even when these files cannot
 * be created. */
static void marker(bool on,
                   const char *source,
                   const char *mode,
                   int pixel_valid) {
    const char *ready = ready_path();
    const char *base = base_ready_path();
    if (!on) {
        unlink(ready);
        unlink(base);
        return;
    }

    FILE *f = fopen(ready, "w");
    if (f) {
        fprintf(f,
                "ready=1\n"
                "pid=%ld\n"
                "source=%s\n"
                "sink=mirror-displayable3\n"
                "mode=%s\n"
                "pixel_valid=%d\n",
                (long)getpid(),
                source ? source : "unknown",
                mode ? mode : "unknown",
                pixel_valid ? 1 : 0);
        fclose(f);
    }

    f = fopen(base, "w");
    if (f) {
        fprintf(f,
                "ready=1\n"
                "pid=%ld\n"
                "mode=%s\n"
                "pixel_valid=%d\n",
                (long)getpid(),
                mode ? mode : "unknown",
                pixel_valid ? 1 : 0);
        fclose(f);
    }
}

/*
 * Context ownership is intentionally outside this pixel sidecar.
 * The sidecar only proves Window58 readback and posts to displayable3.
 * Java/HMI owns terminal1 and ctx80={98,101,102,3}.
 */
static bool activate() {
    fprintf(stderr, "route: native context writer disabled; waiting for Java/HMI ctx80\n");
    return true;
}
static void restore() {
    fprintf(stderr, "route: native restore disabled; Java/HMI owns stock release\n");
}

int main(int argc, char **argv) {
    bool verbose = false;
    bool sink_test_grid = false;
    const char *grid_env = getenv("ALT111_SINK_TEST_GRID");
    if (grid_env &&
        (!strcmp(grid_env, "1") ||
         !strcmp(grid_env, "YES") ||
         !strcmp(grid_env, "yes") ||
         !strcmp(grid_env, "true"))) {
        sink_test_grid = true;
    }
    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--verbose")) verbose = true;
        if (!strcmp(argv[i], "--sink-test-grid")) sink_test_grid = true;
    }

    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    signal(SIGHUP, on_signal);
    marker(false, 0, 0, 0);

    fprintf(stderr,
            "carplay-mirror: BUILD id=%s "
            "mode=%s gate=%s "
            "source_context=%s diagnostics=event_driven+pixel_truth\n",
            kBuildId,
            sink_test_grid ? "sink-test-grid" : "readback",
            sink_test_grid ? "BASEVIDEO_ACTIVE_ONLY" : "PHONE_REQUEST_111",
            sink_test_grid ? "NONE" :
                "none_before_gate_then_window_manager_event");

    if (sink_test_grid) {
        Mhi2qBackendConfig grid_cfg;
        grid_cfg.width = 1440;
        grid_cfg.height = 455;
        grid_cfg.displayable_id = 3;
        grid_cfg.verbose = verbose;

        ClusterVideoDisplay grid_display;
        if (!grid_display.init(grid_cfg)) return 20;
        grid_display.set_fullscreen_destination();
        if (!grid_display.present_test_grid()) {
            grid_display.shutdown();
            return 21;
        }

        fprintf(stderr,
                "carplay-mirror: SINK_TEST_GRID_PRESENT=YES "
                "displayable=3 size=1440x455 source_window=NONE "
                "stream111_dependency=NONE\n");
        fprintf(stderr,
                "carplay-mirror: GLES_PRESENT=YES mode=sink-test-grid "
                "displayable=3 source_pixel_valid=NA\n");
        marker(true, "diagnostic-test-grid", "sink-test-grid", 0);
        if (!activate()) {
            marker(false, 0, 0, 0);
            grid_display.shutdown();
            restore();
            return 22;
        }

        fprintf(stderr,
                "carplay-mirror: ACTIVE mode=sink-test-grid sink=displayable3 "
                "context=80 java_requires=baseActive+baseReady\n");
        while (!g_stop) {
            grid_display.refresh();
            usleep(100000);
        }

        marker(false, 0, 0, 0);
        restore();
        grid_display.shutdown();
        fprintf(stderr,
                "carplay-mirror: sink-test-grid stopped; "
                "Java/HMI context release requested\n");
        return 0;
    }

    if (!wait_for_phone111_gate()) {
        fprintf(stderr,
                "carplay-mirror: stopped before PHONE_REQUEST_111; "
                "Screen context was never created\n");
        return 0;
    }

    CarPlayWindowSource source(58, verbose);
    if (!source.init()) return 2;

    VideoFrame frame;
    bool reported_pixel_wait = false;
    fprintf(stderr,
            "carplay-mirror: waiting for Window58 CREATE/POST/readback "
            "and SOURCE_PIXEL_VALID after PHONE_REQUEST_111\n");
    while (!g_stop) {
        if (source.read_frame(&frame)) {
            if (source.pixel_valid()) break;
            if (!reported_pixel_wait) {
                fprintf(stderr,
                        "carplay-mirror: SOURCE_PIXEL_GATE=WAITING "
                        "readback_rc=OK reason=BLACK_OR_EMPTY_CONTENT "
                        "ctx80_not_requested=1\n");
                reported_pixel_wait = true;
            }
        }
        usleep(20000);
    }
    if (g_stop) {
        source.shutdown();
        return 0;
    }

    fprintf(stderr,
            "carplay-mirror: source ready %dx%d stride=%d "
            "pixel_valid=YES hash=0x%08lx nonblack_permille=%u changed=%s; "
            "starting pinned Mirror pixel plane\n",
            frame.width, frame.height, frame.stride,
            source.pixel_hash(),
            source.pixel_nonblack_permille(),
            source.pixel_changed() ? "YES" : "NO");

    Mhi2qBackendConfig cfg;
    cfg.width = 1440;
    cfg.height = 455;
    cfg.displayable_id = 3;
    cfg.verbose = verbose;

    ClusterVideoDisplay display;
    if (!display.init(cfg)) {
        source.shutdown();
        return 3;
    }
    display.set_fullscreen_destination();

    if (!display.present_frame(frame)) {
        display.shutdown();
        source.shutdown();
        return 4;
    }

    fprintf(stderr,
            "carplay-mirror: GLES_PRESENT=YES mode=readback "
            "displayable=3 source_pixel_valid=1 hash=0x%08lx\n",
            source.pixel_hash());
    marker(true, "carplay111-window58", "readback", 1);
    if (!activate()) {
        marker(false, 0, 0, 0);
        display.shutdown();
        source.shutdown();
        restore();
        return 5;
    }

    fprintf(stderr,
            "carplay-mirror: ACTIVE source=window58 sink=displayable3 "
            "context=80 first_present=1 pixel_plane=lanye-pinned "
            "target_fps=%u\n",
            kTargetFps);

    unsigned failures = 0;
    unsigned long source_frames = 1;
    unsigned long stats_presented_base = display.frame_count();
    unsigned long long stats_start = now_us();
    const unsigned long long frame_period_us =
        1000000ULL / (unsigned long long)kTargetFps;

    while (!g_stop) {
        const unsigned long long frame_start = now_us();

        if (source.read_frame(&frame)) {
            if (!source.pixel_valid()) {
                ++failures;
                if (failures == 1 || failures == 30) {
                    fprintf(stderr,
                            "carplay-mirror: SOURCE_PIXEL_GATE=INVALID "
                            "freezing_last_valid_frame=1 failures=%u "
                            "hash=0x%08lx nonblack_permille=%u\n",
                            failures,
                            source.pixel_hash(),
                            source.pixel_nonblack_permille());
                }
                usleep(100000);
                continue;
            }

            failures = 0;
            ++source_frames;
            if (!display.present_frame(frame)) {
                fprintf(stderr,
                        "carplay-mirror: display presentation failed; "
                        "stopping safely\n");
                break;
            }
        } else {
            ++failures;
            if (failures == 30) {
                fprintf(stderr,
                        "carplay-mirror: source temporarily unavailable; "
                        "freezing last frame failures=%u\n",
                        failures);
            }
            if (failures > 150) {
                fprintf(stderr,
                        "carplay-mirror: source lost; stopping safely "
                        "failures=%u\n",
                        failures);
                break;
            }
            usleep(100000);
            continue;
        }

        const unsigned long long now = now_us();
        if (verbose && now && stats_start &&
            now - stats_start >= 10000000ULL) {
            const unsigned long long span = now - stats_start;
            const unsigned long total_presented = display.frame_count();
            const unsigned long interval_presented =
                total_presented >= stats_presented_base
                    ? total_presented - stats_presented_base
                    : 0;
            const unsigned long fps100 = span
                ? (unsigned long)(((unsigned long long)interval_presented *
                                   100000000ULL) /
                                  span)
                : 0;
            fprintf(stderr,
                    "carplay-mirror: RUN source=window58 size=%dx%d stride=%d "
                    "source_frames=%lu presented_frames=%lu "
                    "present_fps=%lu.%02lu target_fps=%u context=80 "
                    "pixel_valid=%s hash=0x%08lx nonblack_permille=%u "
                    "changed=%s\n",
                    frame.width,
                    frame.height,
                    frame.stride,
                    source_frames,
                    total_presented,
                    fps100 / 100,
                    fps100 % 100,
                    kTargetFps,
                    source.pixel_valid() ? "YES" : "NO",
                    source.pixel_hash(),
                    source.pixel_nonblack_permille(),
                    source.pixel_changed() ? "YES" : "NO");
            stats_presented_base = total_presented;
            stats_start = now;
        }

        const unsigned long long spent = now_us() - frame_start;
        if (spent < frame_period_us) {
            usleep((unsigned int)(frame_period_us - spent));
        }
    }

    const unsigned long presented_frames = display.frame_count();
    marker(false, 0, 0, 0);
    restore();
    display.shutdown();
    source.shutdown();
    fprintf(stderr,
            "carplay-mirror: stopped; Java/HMI context release requested "
            "source_frames=%lu presented_frames=%lu\n",
            source_frames,
            presented_frames);
    return 0;
}
