/* p1404_firewall.c - dynamic, exact-port PF mutation for private stream111. */
#include "p1404_firewall.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define PF_CAPTURE_MAX (128u * 1024u)
static volatile unsigned g_pf_guard;
static void pf_lock(void) { while (__sync_lock_test_and_set(&g_pf_guard, 1u) != 0u) { } }
static void pf_unlock(void) { __sync_lock_release(&g_pf_guard); }

static int is_blocker(const char *line, size_t n) {
    return n >= 5u && !memcmp(line, "block", 5u) &&
           strstr(line, "in quick on carplay0") != NULL &&
           strstr(line, " all") != NULL;
}

static int is_our_rule(const char *line, size_t n, uint16_t port) {
    char a[160], b[160];
    int na = snprintf(a, sizeof(a),
        "pass in quick on carplay0 proto tcp from any to any port = %u", (unsigned)port);
    int nb = snprintf(b, sizeof(b),
        "pass in quick on carplay0 proto tcp from any to any port %u", (unsigned)port);
    if (na <= 0 || nb <= 0) return 0;
    return (n >= (size_t)na && !memcmp(line, a, (size_t)na)) ||
           (n >= (size_t)nb && !memcmp(line, b, (size_t)nb));
}

static int append_bytes(char *out, size_t cap, size_t *used,
                        const char *src, size_t n) {
    if (!out || !used || !src || *used + n + 1u > cap) return 0;
    memcpy(out + *used, src, n);
    *used += n;
    out[*used] = 0;
    return 1;
}

int p1404_alt111_firewall_rewrite(const char *rules, uint16_t port, int enable,
                                  char *out, size_t out_cap, int *changed_out) {
    const char *cur, *nl;
    size_t used = 0;
    int found = 0, blocker = 0, changed = 0;
    char rule[192];
    int rule_n;
    if (changed_out) *changed_out = 0;
    if (!rules || !port || !out || out_cap < 2u) return 0;
    out[0] = 0;
    for (cur = rules; *cur; cur = nl ? nl + 1 : cur + strlen(cur)) {
        size_t n;
        nl = strchr(cur, '\n');
        n = nl ? (size_t)(nl - cur) : strlen(cur);
        if (is_our_rule(cur, n, port)) found = 1;
        if (!nl) break;
    }
    if (enable && found) {
        if (strlen(rules) + 1u > out_cap) return 0;
        memcpy(out, rules, strlen(rules) + 1u);
        return 1;
    }
    rule_n = snprintf(rule, sizeof(rule),
        "pass in quick on carplay0 proto tcp from any to any port = %u keep state\n",
        (unsigned)port);
    if (rule_n <= 0 || (size_t)rule_n >= sizeof(rule)) return 0;
    cur = rules;
    while (*cur) {
        size_t n;
        nl = strchr(cur, '\n');
        n = nl ? (size_t)(nl - cur) : strlen(cur);
        if (!enable && is_our_rule(cur, n, port)) {
            changed = 1;
        } else {
            if (enable && !blocker && is_blocker(cur, n)) {
                if (!append_bytes(out, out_cap, &used, rule, (size_t)rule_n)) return 0;
                blocker = 1;
                changed = 1;
            }
            if (!append_bytes(out, out_cap, &used, cur, n)) return 0;
            if (nl && !append_bytes(out, out_cap, &used, "\n", 1u)) return 0;
        }
        if (!nl) break;
        cur = nl + 1;
    }
    if (enable && !blocker) return 0; /* fail closed if expected terminal block moved */
    if (changed_out) *changed_out = changed;
    return 1;
}

static char *capture_rules(void) {
    FILE *fp;
    char chunk[1024];
    char *buf;
    size_t used = 0, cap = 8192;
    fp = popen("pfctl -sr 2>/dev/null", "r");
    if (!fp) return NULL;
    buf = (char *)malloc(cap);
    if (!buf) { pclose(fp); return NULL; }
    buf[0] = 0;
    while (fgets(chunk, sizeof(chunk), fp)) {
        size_t n = strlen(chunk);
        if (used + n + 1u > PF_CAPTURE_MAX) { free(buf); pclose(fp); return NULL; }
        if (used + n + 1u > cap) {
            size_t next = cap * 2u;
            char *grown;
            while (next < used + n + 1u) next *= 2u;
            grown = (char *)realloc(buf, next);
            if (!grown) { free(buf); pclose(fp); return NULL; }
            buf = grown; cap = next;
        }
        memcpy(buf + used, chunk, n); used += n; buf[used] = 0;
    }
    if (pclose(fp) != 0 || !used) { free(buf); return NULL; }
    return buf;
}

static int apply_rule(uint16_t port, int enable) {
    char *before = NULL, *after = NULL;
    char path[96], cmd[160];
    FILE *fp = NULL;
    size_t cap;
    int changed = 0, ok = 0, n;
    if (!port) return 0;
    pf_lock();
    before = capture_rules();
    if (!before) goto done;
    cap = strlen(before) + 256u;
    after = (char *)malloc(cap);
    if (!after) goto done;
    if (!p1404_alt111_firewall_rewrite(before, port, enable, after, cap, &changed))
        goto done;
    if (!changed) { ok = 1; goto done; }
    n = snprintf(path, sizeof(path), "/tmp/carplay_alt111_pf_%ld_%u.conf",
                 (long)getpid(), (unsigned)port);
    if (n <= 0 || (size_t)n >= sizeof(path)) goto done;
    fp = fopen(path, "wb");
    if (!fp) goto done;
    if (fwrite(after, 1u, strlen(after), fp) != strlen(after) || fclose(fp) != 0) {
        fp = NULL; unlink(path); goto done;
    }
    fp = NULL;
    n = snprintf(cmd, sizeof(cmd), "pfctl -f '%s' >/dev/null 2>&1", path);
    if (n > 0 && (size_t)n < sizeof(cmd) && system(cmd) == 0) ok = 1;
    unlink(path);
done:
    if (fp) fclose(fp);
    free(after); free(before);
    pf_unlock();
    return ok;
}

int p1404_alt111_firewall_open(uint16_t port) { return apply_rule(port, 1); }
int p1404_alt111_firewall_close(uint16_t port) { return apply_rule(port, 0); }
