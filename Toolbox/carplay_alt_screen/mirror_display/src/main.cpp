#include "private111_direct_source.h"
#include "cluster_video_display.h"

#include <signal.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

static volatile sig_atomic_t g_stop = 0;
static const unsigned kTargetFps = 30;
static const char kBuildId[] = "carplay-private111-direct-display-v2";

static void make_diagnostics_nonblocking(int fd) {
    const int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) (void)fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

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

static const char *displayable_state_path() {
    return volatile_path("ALT111_DISPLAYABLE_STATE_FILE",
                         "/tmp/mmi-mirror-displayable3.state");
}

static unsigned long long now_us() {
    struct timeval tv;
    if (gettimeofday(&tv, 0) != 0) return 0;
    return (unsigned long long)(unsigned long)tv.tv_sec * 1000000ULL +
           (unsigned long long)(unsigned long)tv.tv_usec;
}

static unsigned counter_delta(unsigned current, unsigned base) {
    return current >= base ? current - base : current;
}

static void sanitize_state_value(char *s) {
    if (!s) return;
    for (; *s; ++s) {
        if (*s == '\n' || *s == '\r' || *s == '=')
            *s = ' ';
    }
}

static void publish_displayable_state(const ClusterVideoDisplay &display,
                                      const Private111DirectSource *source,
                                      const VideoFrame *frame,
                                      const char *phase) {
    Mhi2qWindowState state;
    memset(&state, 0, sizeof(state));
    (void)display.sample_window_state(&state);

    char manager[sizeof(state.manager)];
    strncpy(manager, state.manager, sizeof(manager) - 1u);
    manager[sizeof(manager) - 1u] = 0;
    sanitize_state_value(manager);

    const unsigned long long ts_us = now_us();
    const unsigned long long ts_ms = ts_us / 1000ULL;
    const uint32_t generation = source ? source->generation() : 0u;
    const uint32_t h264_packets = source ? source->h264_packets() : 0u;
    const uint32_t decoded_frames = source ? source->producer_frames() : 0u;
    const uint32_t sequence = frame ? frame->sequence : 0u;

    const char *path = displayable_state_path();
    char tmp[512];
    const int tmp_n = snprintf(tmp, sizeof(tmp), "%s.tmp", path);
    if (tmp_n > 0 && (size_t)tmp_n < sizeof(tmp)) {
        FILE *f = fopen(tmp, "w");
        if (f) {
            fprintf(f,
                    "schema=1\n"
                    "observer=DISPLAYABLE3_OWNERSHIP_V1\n"
                    "mode=OBSERVE_ONLY\n"
                    "timestamp_ms=%llu\n"
                    "phase=%s\n"
                    "backend_ready=%d\n"
                    "native_window_present=%d\n"
                    "native_window=0x%lx\n"
                    "kd_window=%d\n"
                    "displayable=%d\n"
                    "visible_valid=%d\n"
                    "visible=%d\n"
                    "manager_valid=%d\n"
                    "manager=%s\n"
                    "first_present=%d\n"
                    "presented_frames=%lu\n"
                    "generation=%u\n"
                    "sequence=%u\n"
                    "h264_packets=%u\n"
                    "decoded_frames=%u\n",
                    ts_ms,
                    phase ? phase : "periodic",
                    state.backend_ready ? 1 : 0,
                    state.native_window_present ? 1 : 0,
                    state.native_window_value,
                    state.kd_window,
                    state.displayable_id,
                    state.visible_valid ? 1 : 0,
                    state.visible,
                    state.manager_valid ? 1 : 0,
                    manager,
                    display.first_frame_presented() ? 1 : 0,
                    display.frame_count(),
                    (unsigned)generation,
                    (unsigned)sequence,
                    (unsigned)h264_packets,
                    (unsigned)decoded_frames);
            if (fclose(f) == 0) {
                if (rename(tmp, path) != 0) {
                    unlink(path);
                    if (rename(tmp, path) != 0)
                        unlink(tmp);
                }
            } else {
                unlink(tmp);
            }
        }
    }

    /*
     * Log only transitions plus a 10 s heartbeat.  The state file itself is
     * refreshed at 2 Hz so Java can correlate a Context80 drift with the
     * physical displayable3 state without flooding the SD log.
     */
    static int have_previous = 0;
    static int last_backend_ready = -1;
    static int last_native_present = -1;
    static int last_visible_valid = -1;
    static int last_visible = -999;
    static int last_manager_valid = -1;
    static unsigned long last_native_window = 0;
    static int last_kd_window = -999;
    static char last_manager[96] = "";
    static unsigned long long last_heartbeat_us = 0;

    const int changed =
        !have_previous ||
        last_backend_ready != (state.backend_ready ? 1 : 0) ||
        last_native_present != (state.native_window_present ? 1 : 0) ||
        last_visible_valid != (state.visible_valid ? 1 : 0) ||
        last_visible != state.visible ||
        last_manager_valid != (state.manager_valid ? 1 : 0) ||
        last_native_window != state.native_window_value ||
        last_kd_window != state.kd_window ||
        strcmp(last_manager, manager) != 0;
    const int heartbeat =
        !last_heartbeat_us ||
        (ts_us >= last_heartbeat_us &&
         ts_us - last_heartbeat_us >= 10000000ULL);

    if (changed || heartbeat) {
        fprintf(stderr,
                "direct111: PHASE=DISPLAYABLE3_OWNERSHIP ts_ms=%llu "
                "reason=%s backend_ready=%d native_present=%d "
                "native=0x%lx kd=%d displayable=%d "
                "visible_valid=%d visible=%d manager_valid=%d manager='%s' "
                "first_present=%d presented=%lu gen=%u seq=%u "
                "h264_packets=%u decoded_frames=%u observe_only=1\n",
                ts_ms, changed ? "change" : "heartbeat",
                state.backend_ready ? 1 : 0,
                state.native_window_present ? 1 : 0,
                state.native_window_value,
                state.kd_window,
                state.displayable_id,
                state.visible_valid ? 1 : 0,
                state.visible,
                state.manager_valid ? 1 : 0,
                manager,
                display.first_frame_presented() ? 1 : 0,
                display.frame_count(),
                (unsigned)generation,
                (unsigned)sequence,
                (unsigned)h264_packets,
                (unsigned)decoded_frames);
        last_heartbeat_us = ts_us;
    }

    have_previous = 1;
    last_backend_ready = state.backend_ready ? 1 : 0;
    last_native_present = state.native_window_present ? 1 : 0;
    last_visible_valid = state.visible_valid ? 1 : 0;
    last_visible = state.visible;
    last_manager_valid = state.manager_valid ? 1 : 0;
    last_native_window = state.native_window_value;
    last_kd_window = state.kd_window;
    strncpy(last_manager, manager, sizeof(last_manager) - 1u);
    last_manager[sizeof(last_manager) - 1u] = 0;
}

static void log_frame_present_timing(const VideoFrame &frame,
                                     unsigned long long before_present_us,
                                     unsigned long long after_present_us,
                                     unsigned long long previous_present_us,
                                     uint32_t generation) {
    const unsigned present_us32 = (unsigned)after_present_us;
    const unsigned interval_us = previous_present_us &&
                                 after_present_us >= previous_present_us &&
                                 after_present_us - previous_present_us <= 5000000ULL
                                     ? (unsigned)(after_present_us - previous_present_us) : 0u;
    const unsigned present_call_us = before_present_us &&
                                     after_present_us >= before_present_us &&
                                     after_present_us - before_present_us <= 5000000ULL
                                         ? (unsigned)(after_present_us - before_present_us) : 0u;
    char line[512];
    const int written = snprintf(line, sizeof(line),
            "direct111: PHASE=FRAME_PRESENT_TIMING seq=%u gen=%u h264_seq=%u "
            "decode_proxy_us=%u readback_us=%u publish_to_copy_end_us=%u "
            "copy_us=%u copy_to_present_us=%u present_call_us=%u "
            "publish_to_present_us=%u input_to_present_proxy_us=%u "
            "present_interval_us=%u instant_fps100=%u\n",
            frame.sequence, generation, frame.h264_sequence,
            p111_timing_delta_us32(frame.render_us32, frame.h264_rx_us32),
            frame.readback_us,
            p111_timing_delta_us32((unsigned)frame.timestamp_us, frame.publish_us32),
            frame.copy_us,
            p111_timing_delta_us32(present_us32, (unsigned)frame.timestamp_us),
            present_call_us,
            p111_timing_delta_us32(present_us32, frame.publish_us32),
            p111_timing_delta_us32(present_us32, frame.h264_rx_us32),
            interval_us, interval_us ? 100000000u / interval_us : 0u);
    if (written > 0 && (size_t)written < sizeof(line))
        (void)write(STDERR_FILENO, line, (size_t)written);
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
    static const char kNamespaceHookLog[] = "/tmp/MMI-Cockpit-Carplay/altscreen_hook.log";
    char consumed[1024];
    char candidate[1024];
    char candidate_source[48];
    char line[1024];
    bool have_hook_init = false;
    bool reported_waiting = false;
    bool reported_consumed = false;
    FILE *files[3] = {0, 0, 0};
    const char *paths[3] = {
        hook_log_path(),
        volatile_path("ALT111_MIRROR_HOOK_FALLBACK_LOG", kNamespaceHookLog),
        kFlatHookLog
    };

    load_consumed_gate(consumed, sizeof(consumed));
    candidate[0] = 0;
    candidate_source[0] = 0;

    while (!g_stop) {
        bool read_any = false;
        for (unsigned source = 0; source < 3u; ++source) {
            if (source && strcmp(paths[source], paths[0]) == 0) continue;
            if (source == 2u && strcmp(paths[source], paths[1]) == 0) continue;
            FILE *&f = files[source];
            struct stat path_stat, open_stat;
            if (f && (stat(paths[source], &path_stat) != 0 ||
                      fstat(fileno(f), &open_stat) != 0 ||
                      path_stat.st_ino != open_stat.st_ino ||
                      path_stat.st_size < ftell(f))) {
                fclose(f);
                f = 0;
            }
            if (!f) {
                f = fopen(paths[source], "r");
                if (f)
                    fprintf(stderr,
                            "direct111: PHASE=GATE_LOG_ATTACHED path=%s "
                            "screen_context=NONE window58_dependency=NONE\n",
                            paths[source]);
            }
            if (!f) continue;
            while (fgets(line, sizeof(line), f)) {
                read_any = true;
                strip_eol(line);

                if (strstr(line, "PHASE=HOOK_LOG_SEGMENT")) {
                    have_hook_init = true;
                    continue;
                }
                if (strstr(line, "PHASE=HOOK_INIT")) {
                    have_hook_init = true;
                    candidate[0] = 0;
                    candidate_source[0] = 0;
                    reported_consumed = false;
                    continue;
                }

                /*
                 * PHONE_REQUESTED_ALTSCREEN=YES is a process-level marker;
                 * STREAM_111_REQUESTED=YES is emitted for each type111 setup.
                 */
                if (have_hook_init && strstr(line, "PHASE=PHONE_REQUEST_111")) {
                    if (strstr(line, "STREAM_111_REQUESTED=YES")) {
                        copy_line(candidate, sizeof(candidate), line);
                        copy_line(candidate_source, sizeof(candidate_source),
                                  "stream111-request");
                    } else if (strstr(line, "PHONE_REQUESTED_ALTSCREEN=YES")) {
                        copy_line(candidate, sizeof(candidate), line);
                        copy_line(candidate_source, sizeof(candidate_source),
                                  "phone-marker");
                    }
                }
            }
            clearerr(f);
        }

        if (!read_any && !reported_waiting) {
            fprintf(stderr,
                    "direct111: PHASE=GATE_WAIT for=PHONE_REQUEST_111 "
                    "screen_context=NONE window58_dependency=NONE hook_log=%s\n",
                    paths[0]);
            reported_waiting = true;
        }

        if (candidate[0]) {
            if (consumed[0] && strcmp(candidate, consumed) == 0) {
                if (!reported_consumed) {
                    fprintf(stderr,
                            "direct111: PHASE=GATE_CONSUMED "
                            "source=%s waiting_for_next_private111_session=1\n",
                            candidate_source[0] ? candidate_source : "unknown");
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
                for (unsigned source = 0; source < 3u; ++source)
                    if (files[source]) fclose(files[source]);
                fprintf(stderr,
                        "direct111: PHASE=GATE_PASS trigger=PHONE_REQUEST_111 "
                        "gate_source=%s policy=stream111_request_or_phone_marker "
                        "next=H264_TAP_AND_DECODER_SHM\n",
                        candidate_source[0] ? candidate_source : "unknown");
                return true;
            }
        }

        usleep(read_any ? 20000 : 50000);
    }

    for (unsigned source = 0; source < 3u; ++source)
        if (files[source]) fclose(files[source]);
    return false;
}

static void marker(bool on, const char *source, const char *mode) {
    const char *ready = ready_path();
    const char *base = base_ready_path();

    if (!on) {
        unlink(ready);
        unlink(base);
        unlink(displayable_state_path());
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
    /* The launcher may connect stdout/stderr to an SD-backed FIFO reader.
     * A stalled card must drop diagnostics, never stall decoded-frame work. */
    make_diagnostics_nonblocking(STDOUT_FILENO);
    make_diagnostics_nonblocking(STDERR_FILENO);
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
    unsigned startup_fresh_frames = 0u;
    uint32_t startup_writer = 0u;
    uint32_t startup_generation = 0u;
    uint32_t startup_cookie = 0u;
    fprintf(stderr,
            "direct111: PHASE=PIPELINE_WAIT "
            "waiting=H264_TAP+DECODER_FRESH_PROGRESS "
            "startup_frame_progress_required=2 "
            "source=/carplay111_decoded window58_readback=0\n");

    while (!g_stop) {
        if (source.read_frame(&frame)) {
            const uint32_t writer = source.writer_pid();
            const uint32_t gen = source.generation();
            const uint32_t cookie = source.stream_cookie();

            if (writer != startup_writer ||
                gen != startup_generation ||
                cookie != startup_cookie) {
                startup_writer = writer;
                startup_generation = gen;
                startup_cookie = cookie;
                startup_fresh_frames = 1u;
            } else {
                ++startup_fresh_frames;
            }

            if (startup_fresh_frames >= 2u) {
                fprintf(stderr,
                        "direct111: PHASE=PIPELINE_SOURCE_PRIMED "
                        "fresh_frames=%u writer_pid=%u generation=%u "
                        "cookie=0x%08x stale_single_frame_rejected=1\n",
                        startup_fresh_frames, (unsigned)startup_writer,
                        (unsigned)startup_generation,
                        (unsigned)startup_cookie);
                break;
            }
        }

        if (!wait_reported || (++wait_loops % 100u) == 0u) {
            wait_reported = true;
            fprintf(stderr,
                    "direct111: PHASE=PIPELINE_PROGRESS "
                    "h264_ready=%d h264_packets=%u h264_bytes=%u "
                    "decoder_ready=%d decoded_frames=%u fresh_frames=%u "
                    "displayable3=NOT_CREATED\n",
                    source.h264_ready() ? 1 : 0,
                    (unsigned)source.h264_packets(),
                    (unsigned)source.h264_bytes(),
                    source.decoded_ready() ? 1 : 0,
                    (unsigned)source.decoded_frames(),
                    startup_fresh_frames);
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

    unsigned long long before_present_us = now_us();
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
    unsigned long long last_present_us = now_us();
    log_frame_present_timing(frame, before_present_us, last_present_us,
                             0ULL, source.generation());

    fprintf(stderr,
            "direct111: PHASE=DISPLAYABLE3_FIRST_PRESENT result=OK "
            "displayable=3 output=1440x455 source=private111-decoded "
            "window58_readback=0\n");

    publish_displayable_state(display, &source, &frame, "first-present");
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
    uint32_t stats_h264_base = source.h264_packets();
    uint32_t stats_decoded_base = source.producer_frames();
    uint32_t stats_copies_base = source.consumer_copies();
    uint32_t last_present_seq = frame.sequence;
    uint32_t last_present_generation = source.generation();
    unsigned long skipped_frames = 0;
    unsigned long stats_skipped_base = 0;
    unsigned long stall_events = 0;
    unsigned long stats_stall_base = 0;
    unsigned max_decode_proxy_us = 0u;
    unsigned max_readback_us = 0u;
    unsigned max_publish_to_present_us = 0u;
    unsigned max_present_call_us = 0u;
    const unsigned long long frame_period_us =
        1000000ULL / (unsigned long long)kTargetFps;
    unsigned long long next_ownership_probe_us = now_us() + 500000ULL;

    while (!g_stop) {
        const unsigned long long frame_start = now_us();
        if (!next_ownership_probe_us ||
            (frame_start && frame_start >= next_ownership_probe_us)) {
            publish_displayable_state(display, &source, &frame, "periodic");
            next_ownership_probe_us = frame_start + 500000ULL;
        }
        if (frame_start && stats_start && frame_start >= stats_start &&
            frame_start - stats_start >= 60000000ULL) {
            clearerr(stderr);
            const unsigned long long span = frame_start - stats_start;
            const unsigned long presented = display.frame_count();
            const unsigned long interval_presented = presented - stats_presented_base;
            const unsigned long fps100 = span
                ? (unsigned long)((unsigned long long)interval_presented * 100000000ULL / span)
                : 0u;
            const unsigned long decoded_fps100 = span
                ? (unsigned long)((unsigned long long)counter_delta(source.producer_frames(), stats_decoded_base) *
                                   100000000ULL / span)
                : 0u;
            fprintf(stderr,
                    "direct111: PHASE=FRAME_CHAIN_HEALTH interval_s=%llu gen=%u "
                    "h264_packets=%u decoded_frames=%u copied_frames=%u presented_frames=%lu "
                    "present_fps=%lu.%02lu decoded_fps=%lu.%02lu skipped_sequences=%lu "
                    "h264_drops=%u h264_wraps=%u decoded_drops=%u copy_races=%u "
                    "stall_events=%lu in_stall=%d max_decode_proxy_us=%u "
                    "max_readback_us=%u max_publish_to_present_us=%u "
                    "max_present_call_us=%u\n",
                    span / 1000000ULL, (unsigned)source.generation(),
                    counter_delta(source.h264_packets(), stats_h264_base),
                    counter_delta(source.producer_frames(), stats_decoded_base),
                    counter_delta(source.consumer_copies(), stats_copies_base),
                    interval_presented, fps100 / 100u, fps100 % 100u,
                    decoded_fps100 / 100u, decoded_fps100 % 100u,
                    skipped_frames - stats_skipped_base,
                    (unsigned)source.h264_drops(), (unsigned)source.h264_wraps(),
                    (unsigned)source.decoded_drops(), (unsigned)source.copy_races(),
                    stall_events - stats_stall_base, in_stall ? 1 : 0,
                    max_decode_proxy_us, max_readback_us,
                    max_publish_to_present_us, max_present_call_us);
            stats_start = frame_start;
            stats_presented_base = presented;
            stats_h264_base = source.h264_packets();
            stats_decoded_base = source.producer_frames();
            stats_copies_base = source.consumer_copies();
            stats_skipped_base = skipped_frames;
            stats_stall_base = stall_events;
            max_decode_proxy_us = max_readback_us = 0u;
            max_publish_to_present_us = max_present_call_us = 0u;
        }

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
            if (source.generation() == last_present_generation &&
                (int32_t)(frame.sequence - last_present_seq) > 1)
                skipped_frames += (unsigned)(frame.sequence - last_present_seq - 1u);
            last_present_generation = source.generation();
            last_present_seq = frame.sequence;
            before_present_us = now_us();
            if (!display.present_frame(frame)) {
                fprintf(stderr,
                        "direct111: ERROR PHASE=DISPLAY_PRESENT "
                        "stopping_safely=1\n");
                break;
            }
            const unsigned long long after_present_us = now_us();
            log_frame_present_timing(frame, before_present_us,
                                     after_present_us, last_present_us,
                                     source.generation());
            const unsigned decode_proxy_us = p111_timing_delta_us32(
                frame.render_us32, frame.h264_rx_us32);
            const unsigned publish_to_present_us = p111_timing_delta_us32(
                (unsigned)after_present_us, frame.publish_us32);
            const unsigned present_call_us = p111_timing_delta_us32(
                (unsigned)after_present_us, (unsigned)before_present_us);
            if (decode_proxy_us > max_decode_proxy_us)
                max_decode_proxy_us = decode_proxy_us;
            if (frame.readback_us > max_readback_us)
                max_readback_us = frame.readback_us;
            if (publish_to_present_us > max_publish_to_present_us)
                max_publish_to_present_us = publish_to_present_us;
            if (present_call_us > max_present_call_us)
                max_present_call_us = present_call_us;
            last_present_us = after_present_us;
        } else {
            ++failures;
            if (!stall_start_us) stall_start_us = now_us();
            const unsigned long long stall_now = now_us();
            if (!in_stall && stall_now >= stall_start_us &&
                stall_now - stall_start_us >= 250000ULL) {
                in_stall = true;
                ++stall_events;
                fprintf(stderr,
                        "direct111: PHASE=DECODED_SOURCE_STALL "
                        "freeze_last_frame=1 failures=%u h264_packets=%u "
                        "decoded_frames=%u generation=%u\n",
                        failures, (unsigned)source.h264_packets(),
                        (unsigned)source.decoded_frames(),
                        (unsigned)source.generation());
            }
            /* No fixed ~3s auto-exit: keep freezing the last frame and let the
             * stop script / signal own teardown. Short decoded gaps are normal
             * during nav-map / phone / OMX scheduling jitter. */
            usleep(20000);
            continue;
        }

        const unsigned long long spent = now_us() - frame_start;
        if (spent < frame_period_us)
            usleep((unsigned int)(frame_period_us - spent));
    }

    const unsigned long presented_frames = display.frame_count();
    publish_displayable_state(display, &source, &frame, "pre-shutdown");
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
