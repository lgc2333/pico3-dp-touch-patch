/*
 * picotouch_shim.so —— 在 pxrstreamingservice 里把电容触摸写进 DP 串流的 HID 报文。
 * 由 libpxrstreamingservice.so 的 DT_NEEDED 带进进程（见 docs/notes/11-magisk-module.md）。
 * 只改 GOT，不改代码页：不用 execmem，SELinux 保持 enforcing。
 */

#include <android/log.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <link.h>
#include <pthread.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define LOG_TAG "picotouch"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

/* 两个偏移都是 GOT 槽（R_AARCH64_JUMP_SLOT），不是函数首字节；换固件必须重取，
 * 校验方法见 docs/notes/11-magisk-module.md。触摸位映射与 hook.js 同一张表（docs/notes/02）。 */
#define SS_SONAME "libpxrstreamingservice.so"
#define CC_SONAME "libpxrcontrollerclient.pxr.so"
#define GOT_WRITE_CHK 0x204C0ul
#define GOT_GETKEY 0x31B50ul

#define GETKEY_SYMBOL "_ZN16pvrcontorlclient17ControllerManager10GetKeyDataEPvP17controller_data_t"

typedef ssize_t (*write_chk_fn)(int, const void *, size_t, size_t);
typedef int (*getkey_fn)(void *, void *, void *);

static write_chk_fn g_real_write_chk;
static getkey_fn g_real_getkey;

static volatile int g_hidg_fd = -1;
static dev_t g_hidg_rdev;

/* [hand][ax, by, stick, trig]，hand: 1=左 2=右 */
static volatile uint8_t g_touch[3][4];

struct find_ctx {
    const char *soname;
    void *base;
};

static int find_cb(struct dl_phdr_info *info, size_t size, void *arg) {
    struct find_ctx *ctx = arg;
    const char *name;
    const char *slash;
    (void)size;
    if (info->dlpi_name == NULL || info->dlpi_name[0] == '\0') return 0;
    slash = strrchr(info->dlpi_name, '/');
    name = slash != NULL ? slash + 1 : info->dlpi_name;
    if (strcmp(name, ctx->soname) != 0) return 0;
    ctx->base = (void *)info->dlpi_addr;
    return 1;
}

static void *module_base(const char *soname) {
    struct find_ctx ctx;
    ctx.soname = soname;
    ctx.base = NULL;
    dl_iterate_phdr(find_cb, &ctx);
    return ctx.base;
}

static int patch_got(void *base, size_t off, void *fn, void **old) {
    long page_size = sysconf(_SC_PAGESIZE);
    uintptr_t slot = (uintptr_t)base + off;
    uintptr_t page = slot & ~(uintptr_t)(page_size - 1);
    if (page_size <= 0) return -1;
    if (mprotect((void *)page, (size_t)page_size, PROT_READ | PROT_WRITE) != 0) return -1;
    if (old != NULL) *old = *(void **)slot;
    __atomic_store_n((void **)slot, fn, __ATOMIC_RELEASE);
    mprotect((void *)page, (size_t)page_size, PROT_READ);
    return 0;
}

static int is_hidg(int fd) {
    struct stat st;
    if (fd == g_hidg_fd) return 1;
    if (fstat(fd, &st) != 0) return 0;
    if (!S_ISCHR(st.st_mode) || st.st_rdev != g_hidg_rdev) return 0;
    g_hidg_fd = fd;
    return 1;
}

static void patch_report(const uint8_t *b, size_t count) {
    int hand;
    uint8_t kv;
    uint8_t nv;
    if (count < 50) return;
    hand = b[1] >> 5;
    if (hand < 1 || hand > 2) return;
    kv = b[49];
    nv = (uint8_t)(kv & ~0xAA);
    if (g_touch[hand][0]) nv |= 0x02;
    if (g_touch[hand][1]) nv |= 0x08;
    if (g_touch[hand][3]) nv |= 0x20;
    if (g_touch[hand][2]) nv |= 0x80;
    if (nv != kv) ((uint8_t *)b)[49] = nv;
}

static ssize_t my_write_chk(int fd, const void *buf, size_t count, size_t buflen) {
    if (count >= 50 && count <= 64 && is_hidg(fd)) patch_report(buf, count);
    return g_real_write_chk(fd, buf, count, buflen);
}

static int my_getkey(void *self, void *handle, void *data) {
    int r = g_real_getkey(self, handle, data);
    if (data != NULL) {
        const uint8_t *p = data;
        int hand = p[0];
        if (hand >= 1 && hand <= 2) {
            const int32_t *v = (const int32_t *)(p + 32);
            g_touch[hand][0] = v[0] != 0;
            g_touch[hand][1] = v[1] != 0;
            g_touch[hand][2] = v[2] != 0;
            g_touch[hand][3] = v[3] != 0;
        }
    }
    return r;
}

static void *wait_controller_client(void *arg) {
    int i;
    int warned = 0;
    (void)arg;
    /* 库刚映射时符号表未必可用、GOT 页也未必可写，两者都重试，别一次失败就放弃 */
    for (i = 0; i < 600; i++) {
        void *base = module_base(CC_SONAME);
        if (base != NULL) {
            void *old = NULL;
            void *handle = dlopen(CC_SONAME, RTLD_NOW | RTLD_NOLOAD);
            g_real_getkey = handle != NULL ? (getkey_fn)dlsym(handle, GETKEY_SYMBOL) : NULL;
            if (g_real_getkey != NULL && patch_got(base, GOT_GETKEY, (void *)my_getkey, &old) == 0) {
                LOGI("controller client hooked");
                return NULL;
            }
            g_real_getkey = NULL;
            if (!warned) {
                LOGE("controller client not ready, retrying");
                warned = 1;
            }
        }
        usleep(100000);
    }
    LOGE("controller client hook failed after 60s");
    return NULL;
}

__attribute__((constructor)) static void shim_init(void) {
    struct stat st;
    void *base;
    void *real;

    if (stat("/dev/hidg0", &st) == 0) {
        g_hidg_rdev = st.st_rdev;
    } else {
        LOGE("stat /dev/hidg0 failed");
    }

    base = module_base(SS_SONAME);
    if (base == NULL) {
        LOGE("libpxrstreamingservice.so not found");
        return;
    }
    real = dlsym(RTLD_DEFAULT, "__write_chk");
    if (real == NULL) {
        LOGE("__write_chk not found");
        return;
    }
    g_real_write_chk = (write_chk_fn)real;
    if (patch_got(base, GOT_WRITE_CHK, (void *)my_write_chk, NULL) != 0) {
        LOGE("patch __write_chk GOT failed");
        return;
    }
    LOGI("hid write hooked");

    {
        pthread_t thread;
        if (pthread_create(&thread, NULL, wait_controller_client, NULL) == 0) pthread_detach(thread);
    }
}
