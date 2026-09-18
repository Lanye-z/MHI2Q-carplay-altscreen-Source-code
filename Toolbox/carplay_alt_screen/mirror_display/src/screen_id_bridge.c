/*
 * Sidecar-only compatibility bridge for the already-promoted V4 Mirror ELF.
 *
 * Why this wraps dlsym rather than screen_get_window_property_iv directly:
 * the V4 observer explicitly resolves Screen entry points with
 * dlsym(libscreen_handle, ...), so a normal LD_PRELOAD function interposer can
 * be bypassed by that specific-handle lookup. This helper intercepts the
 * sidecar's dlsym request for screen_get_window_property_iv and returns one
 * narrow wrapper. Everything else is forwarded to libc's real dlsym.
 *
 * The Audi/CScreenRender identity "58" is SCREEN_PROPERTY_ID_STRING (20),
 * which is owner-defined. SCREEN_PROPERTY_ID (87) is the QNX-generated numeric
 * identity and is logged only as a diagnostic.
 */

typedef unsigned char  u8;
typedef unsigned short u16;
typedef unsigned int   u32;
typedef unsigned int   size_t;
typedef unsigned int   uintptr_t;

typedef struct {
    const char *dli_fname;
    void *dli_fbase;
    const char *dli_sname;
    void *dli_saddr;
} Dl_info;

extern int dladdr(void *, Dl_info *);
extern int strcmp(const char *, const char *);
extern int snprintf(char *, size_t, const char *, ...);
extern int write(int, const void *, size_t);

#define SCREEN_PROPERTY_ID_STRING 20
#define SCREEN_PROPERTY_ID 87

#define PT_LOAD    1
#define PT_DYNAMIC 2
#define DT_NULL    0
#define DT_HASH    4
#define DT_STRTAB  5
#define DT_SYMTAB  6
#define SHN_UNDEF  0

typedef struct {
    u8  e_ident[16];
    u16 e_type;
    u16 e_machine;
    u32 e_version;
    u32 e_entry;
    u32 e_phoff;
    u32 e_shoff;
    u32 e_flags;
    u16 e_ehsize;
    u16 e_phentsize;
    u16 e_phnum;
    u16 e_shentsize;
    u16 e_shnum;
    u16 e_shstrndx;
} Elf32_Ehdr;

typedef struct {
    u32 p_type;
    u32 p_offset;
    u32 p_vaddr;
    u32 p_paddr;
    u32 p_filesz;
    u32 p_memsz;
    u32 p_flags;
    u32 p_align;
} Elf32_Phdr;

typedef struct {
    int d_tag;
    union {
        u32 d_val;
        u32 d_ptr;
    } d_un;
} Elf32_Dyn;

typedef struct {
    u32 st_name;
    u32 st_value;
    u32 st_size;
    u8  st_info;
    u8  st_other;
    u16 st_shndx;
} Elf32_Sym;

typedef void *(*real_dlsym_fn)(void *, const char *);
typedef int (*screen_get_iv_fn)(void *, int, int *);
typedef int (*screen_get_cv_fn)(void *, int, int, char *);

static real_dlsym_fn g_real_dlsym;
static screen_get_iv_fn g_real_iv;
static screen_get_cv_fn g_real_cv;
static int g_logged_ready;
static int g_logged_target;

static int streq(const char *a, const char *b) {
    if (!a || !b) return 0;
    while (*a && *b && *a == *b) {
        ++a;
        ++b;
    }
    return *a == *b;
}

static uintptr_t runtime_ptr(uintptr_t base,
                             uintptr_t min_vaddr,
                             uintptr_t max_vaddr,
                             u32 value) {
    uintptr_t v = (uintptr_t)value;
    if (v >= min_vaddr && v < max_vaddr) return base + v;
    return v;
}

static void *find_libc_symbol(const char *wanted) {
    Dl_info info;
    uintptr_t base;
    Elf32_Ehdr *eh;
    Elf32_Phdr *ph;
    Elf32_Dyn *dyn = 0;
    uintptr_t min_vaddr = 0xffffffffu;
    uintptr_t max_vaddr = 0;
    u32 symtab_v = 0;
    u32 strtab_v = 0;
    u32 hash_v = 0;
    u32 *hash;
    Elf32_Sym *symtab;
    const char *strtab;
    u32 nchain;
    u32 i;

    if (!dladdr((void *)(uintptr_t)&dladdr, &info) || !info.dli_fbase) return 0;
    base = (uintptr_t)info.dli_fbase;
    eh = (Elf32_Ehdr *)base;

    if (eh->e_ident[0] != 0x7f || eh->e_ident[1] != 'E' ||
        eh->e_ident[2] != 'L' || eh->e_ident[3] != 'F' ||
        eh->e_phentsize != sizeof(Elf32_Phdr) || eh->e_phnum == 0) {
        return 0;
    }

    ph = (Elf32_Phdr *)(base + (uintptr_t)eh->e_phoff);
    for (i = 0; i < (u32)eh->e_phnum; ++i) {
        if (ph[i].p_type == PT_LOAD) {
            if ((uintptr_t)ph[i].p_vaddr < min_vaddr)
                min_vaddr = (uintptr_t)ph[i].p_vaddr;
            if ((uintptr_t)ph[i].p_vaddr + (uintptr_t)ph[i].p_memsz > max_vaddr)
                max_vaddr = (uintptr_t)ph[i].p_vaddr + (uintptr_t)ph[i].p_memsz;
        } else if (ph[i].p_type == PT_DYNAMIC) {
            dyn = (Elf32_Dyn *)(base + (uintptr_t)ph[i].p_vaddr);
        }
    }
    if (!dyn || min_vaddr == 0xffffffffu || max_vaddr <= min_vaddr) return 0;

    for (; dyn->d_tag != DT_NULL; ++dyn) {
        if (dyn->d_tag == DT_SYMTAB) symtab_v = dyn->d_un.d_ptr;
        else if (dyn->d_tag == DT_STRTAB) strtab_v = dyn->d_un.d_ptr;
        else if (dyn->d_tag == DT_HASH) hash_v = dyn->d_un.d_ptr;
    }
    if (!symtab_v || !strtab_v || !hash_v) return 0;

    symtab = (Elf32_Sym *)runtime_ptr(base, min_vaddr, max_vaddr, symtab_v);
    strtab = (const char *)runtime_ptr(base, min_vaddr, max_vaddr, strtab_v);
    hash = (u32 *)runtime_ptr(base, min_vaddr, max_vaddr, hash_v);
    nchain = hash[1];

    for (i = 0; i < nchain; ++i) {
        Elf32_Sym *s = &symtab[i];
        if (s->st_name == 0 || s->st_shndx == SHN_UNDEF) continue;
        if (streq(strtab + s->st_name, wanted)) {
            return (void *)runtime_ptr(
                base, min_vaddr, max_vaddr, s->st_value);
        }
    }
    return 0;
}

static void bridge_log_ready(void) {
    static const char msg[] =
        "SCREEN_ID_DLSYM_BRIDGE=READY property=ID_STRING(20) "
        "numeric_property=ID(87) sidecar_only=1\n";
    if (g_logged_ready) return;
    g_logged_ready = 1;
    (void)write(2, msg, sizeof(msg) - 1u);
}

static void bridge_log_target(int numeric_id, const char *id_string) {
    char line[224];
    int n;
    size_t len;
    if (g_logged_target) return;
    g_logged_target = 1;
    n = snprintf(line, sizeof(line),
        "WINDOW58_ID_BRIDGE numeric_id=%d id_string='%s' "
        "target=YES match=ID_STRING\n",
        numeric_id, id_string ? id_string : "");
    if (n <= 0) return;
    len = (size_t)n;
    if (len > sizeof(line)) len = sizeof(line);
    (void)write(2, line, len);
}

static int bridge_get_window_iv(void *window, int property, int *value) {
    int numeric = -1;
    int rc;
    int cv_rc;
    int i;
    char id_string[64];

    if (!g_real_iv) return -1;
    if (property != SCREEN_PROPERTY_ID || !value)
        return g_real_iv(window, property, value);

    rc = g_real_iv(window, property, &numeric);
    for (i = 0; i < (int)sizeof(id_string); ++i) id_string[i] = 0;
    cv_rc = g_real_cv
        ? g_real_cv(window, SCREEN_PROPERTY_ID_STRING,
                    (int)sizeof(id_string) - 1, id_string)
        : -1;

    if (cv_rc == 0 && strcmp(id_string, "58") == 0) {
        *value = 58;
        bridge_log_target(numeric, id_string);
        return 0;
    }

    /*
     * Fail closed: never allow a QNX-generated numeric 58 to masquerade as
     * Audi/CScreenRender owner identity "58". Preserve other numeric IDs only
     * so the legacy observer can keep ignoring non-target windows normally.
     */
    *value = (numeric == 58) ? -1 : numeric;
    return rc;
}

/*
 * Exported intentionally: the sidecar's PLT dlsym resolves here through
 * LD_PRELOAD. The actual libc dlsym address is recovered without recursively
 * calling dlsym, by inspecting libc's in-memory ELF dynamic symbol table.
 */
void *dlsym(void *handle, const char *name) {
    void *resolved;

    if (!g_real_dlsym) {
        g_real_dlsym = (real_dlsym_fn)find_libc_symbol("dlsym");
        if (!g_real_dlsym) return 0;
    }

    resolved = g_real_dlsym(handle, name);
    if (!name || !streq(name, "screen_get_window_property_iv") || !resolved)
        return resolved;

    g_real_iv = (screen_get_iv_fn)resolved;
    g_real_cv = (screen_get_cv_fn)
        g_real_dlsym(handle, "screen_get_window_property_cv");
    if (!g_real_cv) return resolved;

    bridge_log_ready();
    return (void *)(uintptr_t)&bridge_get_window_iv;
}
