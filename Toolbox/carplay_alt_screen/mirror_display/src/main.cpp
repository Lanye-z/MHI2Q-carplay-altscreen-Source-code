#include "private111_direct_source.h"
#include "cluster_video_display.h"

#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <unistd.h>

static volatile sig_atomic_t g_stop = 0;
static const unsigned kTargetFps = 30;
static const char kBuildId[] = "carplay-private111-direct-display-v2";

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

static bool env_truth(const char *name) {
    const char *v = getenv(name);
    if (!v || !*v) return false;
    return strcmp(v, "0") != 0 &&
           strcmp(v, "NO") != 0 && strcmp(v, "no") != 0 &&
           strcmp(v, "false") != 0 && strcmp(v, "FALSE") != 0;
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
    return fclose(f) == 0;
}

/*
 * Wait for the phone to explicitly request private type111 before attaching
 * either shared-memory source.  Unlike the retired Window58 readback path, this
 * gate does not create a Screen manager context and never enumerates windows.
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
                            "direct111: PHASE=GATE_WAIT "
                            "for=PHONE_REQUEST_111 screen_context=NONE "
                            "window58_dependency=NONE hook_log=%s\n",
                            primary);
                    reported_waiting = true;
                }
                usleep(100000);
                continue;
            }

            fprintf(stderr,
                    "direct111: PHASE=GATE_LOG_ATTACHED path=%s "
                    "screen_context=NONE window58_dependency=NONE\n",
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
                            "direct111: PHASE=GATE_CONSUMED "
                            "waiting_for_next_private111_session=1\n");
                    reported_consumed = true;
                }
            } else {
                if (!persist_gate(candidate)) {
                    fprintf(stderr,
                            "direct111: ERROR PHASE=GATE_TOKEN_WRITE path=%s\n",
                            gate_token_path());
                    usleep(100000);
                    continue;
                }
                if (f) {
                    fclose(f);
                    f = 0;
                }
                fprintf(stderr,
                        "direct111: PHASE=GATE_PASS trigger=PHONE_REQUEST_111 "
                        "next=H264_TAP_AND_DECODER_SHM\n");
                return true;
            }
        }

        clearerr(f);
        usleep(read_any ? 20000 : 50000);
    }

    if (f) fclose(f);
    return false;
}

static void marker(bool on, const char *source, const char *mode) {
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
                "sink=displayable3\n"
                "context=80\n"
                "mode=%s\n"
                "window58_readback=0\n",
                (long)getpid(),
                source ? source : "private111-direct",
                mode ? mode : "direct-display");
        fclose(f);
    }

    f = fopen(base, "w");
    if (f) {
        fprintf(f,
                "ready=1\n"
                "pid=%ld\n"
                "mode=%s\n"
                "displayable=3\n"
                "window58_readback=0\n",
                (long)getpid(),
                mode ? mode : "direct-display");
        fclose(f);
    }
}

/* Java/HMI remains the sole terminal1 Context80 owner. */
static bool activate_context80() {
    fprintf(stderr,
            "direct111: PHASE=CONTEXT80_REQUEST owner=java "
            "composite=98,101,102,3 displayable=3 native_dmdt=0\n");
    return true;
}

static void restore_context80() {
    fprintf(stderr,
            "direct111: PHASE=CONTEXT80_RELEASE owner=java "
            "native_dmdt=0\n");
}

static int run_sink_grid(bool verbose) {
    Mhi2qBackendConfig cfg;
    cfg.width = 1440;
    cfg.height = 455;
    cfg.displayable_id = 3;
    cfg.verbose = verbose;

    ClusterVideoDisplay display;
    if (!display.init(cfg)) return 20;
    display.set_fullscreen_destination();
    if (!display.present_test_grid()) {
        display.shutdown();
        return 21;
    }

    fprintf(stderr,
            "direct111: PHASE=DISPLAYABLE3_FIRST_PRESENT "
            "mode=sink-test-grid displayable=3 size=1440x455 "
            "source_dependency=NONE\n");
    marker(true, "diagnostic-test-grid", "sink-test-grid");
    (void)activate_context80();

    while (!g_stop) {
        display.refresh();
        usleep(100000);
    }

    marker(false, 0, 0);
    restore_context80();
    display.shutdown();
    return 0;
}

int main(int argc, char **argv) {
    bool verbose = false;
    bool sink_test_grid = false;
    const char *grid_env = getenv("ALT111_SINK_TEST_GRID");

    if (grid_env &&
        (!strcmp(grid_env, "1") || !strcmp(grid_env, "YES") ||
         !strcmp(grid_env, "yes") || !strcmp(grid_env, "true")))
        sink_test_grid = true;

    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--verbose")) verbose = true;
        if (!strcmp(argv[i], "--sink-test-grid")) sink_test_grid = true;
    }

    signal(SIGINT, on_signal);
    signal(SIGTERM, on_signal);
    signal(SIGHUP, on_signal);
    marker(false, 0, 0);

    fprintf(stderr,
            "direct111: PHASE=BUILD id=%s "
            "target_pipeline=private111->H264_TAP->decoder->displayable3->Context80 "
            "decoder_backend=stock-omx-tap compatibility_parallel_to_h264_tap=1 "
            "shm_attach=fstat_size_guard session_identity=writer_pid+generation+cookie "
            "window58_readback=0 screen_manage_window_sidecar=0\n",
            kBuildId);

    if (sink_test_grid)
        return run_sink_grid(verbose);

    Private111DirectSource source(verbose);
    bool source_initialized = false;
    bool recovered_current_session = false;

    if (env_truth("ALT111_RECOVER_CURRENT_SESSION")) {
        if (source.init()) {
            VideoFrame recovery_probe;
            unsigned fresh_frames = 0u;
            source_initialized = true;

            /*
             * Matching active flags alone are not enough: a producer that died
             * before clearing SHM can leave stale active=1 metadata behind.
             * Require two distinct stable decoded frames while H264+decoded SHM
             * identities still match before bypassing the consumed phone gate.
             */
            for (unsigned retry = 0; retry < 80u && !g_stop; ++retry) {
                if (!source.current_session_active()) {
                    fresh_frames = 0u;
                    usleep(50000);
                    continue;
                }

                if (source.read_frame(&recovery_probe)) {
                    ++fresh_frames;
                    if (fresh_frames >= 2u) {
                        recovered_current_session = true;
                        fprintf(stderr,
                                "direct111: PHASE=GATE_RECOVER_CURRENT_SESSION "
                                "validated=1 retries=%u fresh_decoded_frames=%u "
                                "policy=matching_identity_plus_frame_progress "
                                "consumed_phone_gate_bypass=1\n",
                                retry, fresh_frames);
                        break;
                    }
                }
                usleep(50000);
            }
        }
        if (!recovered_current_session) {
            fprintf(stderr,
                    "direct111: PHASE=GATE_RECOVER_CURRENT_SESSION "
                    "validated=0 reason=no_fresh_matching_frame_progress "
                    "action=FALLBACK_TO_PHONE_REQUEST_GATE\n");
            if (source_initialized) {
                source.shutdown();
                source_initialized = false;
            }
        }
    }

    if (!recovered_current_session) {
        if (!wait_for_phone111_gate())
            return 0;
    }

    if (!source_initialized) {
        if (!source.init()) {
            fprintf(stderr,
                    "direct111: ERROR PHASE=SOURCE_INIT result=FAILED\n");
            return 2;
        }
        source_initialized = true;
    }

    VideoFrame frame;
    bool wait_reported = false;
    unsigned long wait_loops = 0;
    fprintf(stderr,
            "direct111: PHASE=PIPELINE_WAIT "
            "waiting=H264_TAP+DECODER_FIRST_FRAME "
            "source=/carplay111_decoded window58_readback=0\n");

    while (!g_stop) {
        if (source.read_frame(&frame))
            break;

        if (!wait_reported || (++wait_loops % 100u) == 0u) {
            wait_reported = true;
            fprintf(stderr,
                    "direct111: PHASE=PIPELINE_PROGRESS "
                    "h264_ready=%d h264_packets=%u h264_bytes=%u "
                    "decoder_ready=%d decoded_frames=%u "
                    "displayable3=NOT_CREATED\n",
                    source.h264_ready() ? 1 : 0,
                    (unsigned)source.h264_packets(),
                    (unsigned)source.h264_bytes(),
                    source.decoded_ready() ? 1 : 0,
                    (unsigned)source.decoded_frames());
        }
        usleep(20000);
    }

    if (g_stop) {
        source.shutdown();
        return 0;
    }

    fprintf(stderr,
            "direct111: PHASE=FIRST_DECODED_FRAME "
            "backend=stock-omx-tap format=NV12 size=%dx%d stride=%d "
            "h264_ready=%d generation=%u\n",
            frame.width, frame.height, frame.stride,
            source.h264_ready() ? 1 : 0,
            (unsigned)source.generation());

    Mhi2qBackendConfig cfg;
    cfg.width = 1440;
    cfg.height = 455;
    cfg.displayable_id = 3;
    cfg.verbose = verbose;

    ClusterVideoDisplay display;
    if (!display.init(cfg)) {
        fprintf(stderr,
                "direct111: ERROR PHASE=DISPLAYABLE3_INIT result=FAILED\n");
        source.shutdown();
        return 3;
    }
    display.set_fullscreen_destination();

    if (!display.present_frame(frame)) {
        fprintf(stderr,
                "direct111: ERROR PHASE=DISPLAYABLE3_FIRST_PRESENT "
                "result=FAILED input_format=NV12 "
                "reason=texture_upload_or_egl_swap "
                "see_EGL_SWAP_FAILED_above=1\n");
        display.shutdown();
        source.shutdown();
        return 4;
    }

    fprintf(stderr,
            "direct111: PHASE=DISPLAYABLE3_FIRST_PRESENT result=OK "
            "displayable=3 output=1440x455 source=private111-decoded "
            "window58_readback=0\n");

    marker(true, "private111-decoded-shm", "direct-display");
    if (!activate_context80()) {
        marker(false, 0, 0);
        display.shutdown();
        source.shutdown();
        return 5;
    }

    fprintf(stderr,
            "direct111: PHASE=DIRECT111_ACTIVE "
            "target_pipeline=private111->H264_TAP->decoder->displayable3->Context80 "
            "decoder_backend=stock-omx-tap h264_tap_independent=1 "
            "same_session_recovery=%d window58_readback=0 target_fps=%u\n",
            recovered_current_session ? 1 : 0, kTargetFps);

    unsigned failures = 0;
    bool in_stall = false;
    unsigned long long stall_start_us = 0;
    unsigned long source_frames = 1;
    unsigned long stats_presented_base = display.frame_count();
    unsigned long long stats_start = now_us();
    const unsigned long long frame_period_us =
        1000000ULL / (unsigned long long)kTargetFps;

    while (!g_stop) {
        const unsigned long long frame_start = now_us();

        if (source.read_frame(&frame)) {
            if (in_stall) {
                const unsigned long long now = now_us();
                const unsigned long long stall_ms =
                    (now && stall_start_us && now >= stall_start_us)
                        ? (now - stall_start_us) / 1000ULL : 0;
                fprintf(stderr,
                        "direct111: PHASE=DECODED_SOURCE_RECOVERED "
                        "stall_ms=%llu generation=%u decoded_frames=%u "
                        "h264_packets=%u\n",
                        stall_ms, (unsigned)source.generation(),
                        (unsigned)source.decoded_frames(),
                        (unsigned)source.h264_packets());
            }
            failures = 0;
            in_stall = false;
            stall_start_us = 0;
            ++source_frames;
            if (!display.present_frame(frame)) {
                fprintf(stderr,
                        "direct111: ERROR PHASE=DISPLAY_PRESENT "
                        "stopping_safely=1\n");
                break;
            }
        } else {
            ++failures;
            if (!in_stall) {
                in_stall = true;
                stall_start_us = now_us();
                fprintf(stderr,
                        "direct111: PHASE=DECODED_SOURCE_STALL "
                        "freeze_last_frame=1 failures=%u h264_packets=%u "
                        "decoded_frames=%u generation=%u\n",
                        failures, (unsigned)source.h264_packets(),
                        (unsigned)source.decoded_frames(),
                        (unsigned)source.generation());
            } else if ((failures % 250u) == 0u) {
                const unsigned long long now = now_us();
                const unsigned long long stall_ms =
                    (now && stall_start_us && now >= stall_start_us)
                        ? (now - stall_start_us) / 1000ULL : 0;
                fprintf(stderr,
                        "direct111: PHASE=DECODED_SOURCE_STALL "
                        "freeze_last_frame=1 duration_ms=%llu failures=%u "
                        "h264_packets=%u decoded_frames=%u generation=%u\n",
                        stall_ms, failures,
                        (unsigned)source.h264_packets(),
                        (unsigned)source.decoded_frames(),
                        (unsigned)source.generation());
            }
            /* No fixed ~3s auto-exit: keep freezing the last frame and let the
             * stop script / signal own teardown. Short decoded gaps are normal
             * during nav-map / phone / OMX scheduling jitter. */
            usleep(20000);
            continue;
        }

        const unsigned long long now = now_us();
        if (now && stats_start && now - stats_start >= 10000000ULL) {
            const unsigned long long span = now - stats_start;
            const unsigned long total_presented = display.frame_count();
            const unsigned long interval_presented =
                total_presented >= stats_presented_base
                    ? total_presented - stats_presented_base : 0;
            const unsigned long fps100 = span
                ? (unsigned long)(((unsigned long long)interval_presented *
                                   100000000ULL) / span)
                : 0;

            fprintf(stderr,
                    "direct111: PHASE=RUN generation=%u "
                    "h264_ready=%d h264_packets=%u h264_bytes=%u "
                    "decoded_frames=%u source_frames=%lu "
                    "presented_frames=%lu present_fps=%lu.%02lu "
                    "displayable=3 context=80 window58_readback=0\n",
                    (unsigned)source.generation(),
                    source.h264_ready() ? 1 : 0,
                    (unsigned)source.h264_packets(),
                    (unsigned)source.h264_bytes(),
                    (unsigned)source.decoded_frames(),
                    source_frames, total_presented,
                    fps100 / 100, fps100 % 100);

            stats_presented_base = total_presented;
            stats_start = now;
        }

        const unsigned long long spent = now_us() - frame_start;
        if (spent < frame_period_us)
            usleep((unsigned int)(frame_period_us - spent));
    }

    const unsigned long presented_frames = display.frame_count();
    marker(false, 0, 0);
    restore_context80();
    display.shutdown();
    source.shutdown();

    fprintf(stderr,
            "direct111: PHASE=STOP source_frames=%lu presented_frames=%lu "
            "window58_readback=0\n",
            source_frames, presented_frames);
    return 0;
}
