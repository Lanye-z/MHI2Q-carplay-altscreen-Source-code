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
static const char kBuildId[] = "window58-wm-context-v3";

static const char *volatile_path(const char *key, const char *fallback) {
    const char *v = getenv(key);
    return (v && *v) ? v : fallback;
}
static const char *ready_path() { return volatile_path("ALT111_MIRROR_READY_FILE", "/tmp/MMI-Cockpit-Carplay/mirror/ready"); }
static const char *base_ready_path() { return volatile_path("ALT111_MIRROR_BASE_READY_FILE", "/tmp/MMI-Cockpit-Carplay/mirror/basevideo.ready"); }
static unsigned long long now_us() { struct timeval tv; if (gettimeofday(&tv, 0) != 0) return 0; return (unsigned long long)(unsigned long)tv.tv_sec * 1000000ULL + (unsigned long long)(unsigned long)tv.tv_usec; }
static void on_signal(int) { g_stop = 1; }
static void marker(bool on) {
    const char *ready = ready_path(); const char *base = base_ready_path();
    if (!on) { unlink(ready); unlink(base); return; }
    FILE *f = fopen(ready, "w");
    if (f) { fprintf(f, "ready=1\npid=%ld\nsource=carplay111-window58\nsink=mirror-displayable3\n", (long)getpid()); fclose(f); }
    f = fopen(base, "w"); if (f) { fprintf(f, "ready=1\npid=%ld\n", (long)getpid()); fclose(f); }
}
static int cmd(const char *s) { const int rc = system(s); fprintf(stderr, "route: '%s' rc=%d\n", s, rc); return rc; }
static bool activate() { if (cmd("/eso/bin/apps/dmdt dc 76 3") != 0) return false; if (cmd("/eso/bin/apps/dmdt sc 1 72") != 0) return false; usleep(180000); return cmd("/eso/bin/apps/dmdt sc 1 76") == 0; }
static void restore() { (void)cmd("/eso/bin/apps/dmdt dc 76 3"); (void)cmd("/eso/bin/apps/dmdt sc 1 72"); usleep(180000); (void)cmd("/eso/bin/apps/dmdt sc 1 74"); }

int main(int argc, char **argv) {
    bool verbose = false; for (int i = 1; i < argc; ++i) if (!strcmp(argv[i], "--verbose")) verbose = true;
    signal(SIGINT, on_signal); signal(SIGTERM, on_signal); signal(SIGHUP, on_signal); marker(false);
    fprintf(stderr, "carplay-mirror: BUILD id=%s source_context=window_manager_first diagnostics=first_scan_unconditional\n", kBuildId);
    CarPlayWindowSource source(58, verbose); if (!source.init()) return 2;
    VideoFrame frame;
    fprintf(stderr, "carplay-mirror: waiting for private111 window58 first frame\n");
    while (!g_stop && !source.read_frame(&frame)) usleep(100000);
    if (g_stop) { source.shutdown(); return 0; }
    fprintf(stderr, "carplay-mirror: source ready %dx%d stride=%d; starting pinned Mirror pixel plane\n", frame.width, frame.height, frame.stride);
    Mhi2qBackendConfig cfg; cfg.width = 1440; cfg.height = 455; cfg.displayable_id = 3; cfg.verbose = verbose;
    ClusterVideoDisplay display; if (!display.init(cfg)) { source.shutdown(); return 3; }
    display.set_fullscreen_destination();
    if (!display.present_frame(frame)) { display.shutdown(); source.shutdown(); return 4; }
    marker(true);
    if (!activate()) { marker(false); display.shutdown(); source.shutdown(); restore(); return 5; }
    fprintf(stderr, "carplay-mirror: ACTIVE source=window58 sink=displayable3 context=76 first_present=1 pixel_plane=lanye-pinned target_fps=%u\n", kTargetFps);
    unsigned failures = 0; unsigned long source_frames = 1; unsigned long stats_presented_base = display.frame_count(); unsigned long long stats_start = now_us();
    const unsigned long long frame_period_us = 1000000ULL / (unsigned long long)kTargetFps;
    while (!g_stop) {
        const unsigned long long frame_start = now_us();
        if (source.read_frame(&frame)) { failures = 0; ++source_frames; if (!display.present_frame(frame)) { fprintf(stderr, "carplay-mirror: display presentation failed; stopping safely\n"); break; } }
        else { ++failures; if (failures == 30) fprintf(stderr, "carplay-mirror: source temporarily unavailable; freezing last frame failures=%u\n", failures); if (failures > 150) { fprintf(stderr, "carplay-mirror: source lost; stopping safely failures=%u\n", failures); break; } usleep(100000); continue; }
        const unsigned long long now = now_us();
        if (verbose && now && stats_start && now - stats_start >= 10000000ULL) {
            const unsigned long long span = now - stats_start; const unsigned long total_presented = display.frame_count(); const unsigned long interval_presented = total_presented >= stats_presented_base ? total_presented - stats_presented_base : 0; const unsigned long fps100 = span ? (unsigned long)(((unsigned long long)interval_presented * 100000000ULL) / span) : 0;
            fprintf(stderr, "carplay-mirror: RUN source=window58 size=%dx%d stride=%d source_frames=%lu presented_frames=%lu present_fps=%lu.%02lu target_fps=%u context=76\n", frame.width, frame.height, frame.stride, source_frames, total_presented, fps100 / 100, fps100 % 100, kTargetFps);
            stats_presented_base = total_presented; stats_start = now;
        }
        const unsigned long long spent = now_us() - frame_start; if (spent < frame_period_us) usleep((unsigned int)(frame_period_us - spent));
    }
    const unsigned long presented_frames = display.frame_count(); marker(false); restore(); display.shutdown(); source.shutdown();
    fprintf(stderr, "carplay-mirror: stopped; stock context74 restored source_frames=%lu presented_frames=%lu\n", source_frames, presented_frames);
    return 0;
}
