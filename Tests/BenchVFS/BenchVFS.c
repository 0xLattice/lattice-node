#include "BenchVFS.h"
#include <sqlite3.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <pthread.h>
#include <time.h>

#define MAX_SLOTS 256
typedef struct {
    char name[1024];
    _Atomic long long writes, bytes, syncs, syncNanos, commits;
} Slot;
static Slot slots[MAX_SLOTS];
static int nslots = 0;
static pthread_mutex_t slotLock = PTHREAD_MUTEX_INITIALIZER;
static sqlite3_vfs *orig;
static sqlite3_vfs shim;

typedef struct { sqlite3_file base; int slot; int isWal; int pageSize; sqlite3_file *real; } ShimFile;

static int slotFor(const char *name) {
    if (!name) name = "(temp)";
    pthread_mutex_lock(&slotLock);
    for (int i = 0; i < nslots; i++) if (strcmp(slots[i].name, name) == 0) { pthread_mutex_unlock(&slotLock); return i; }
    int i = nslots < MAX_SLOTS - 1 ? nslots++ : MAX_SLOTS - 1;
    strncpy(slots[i].name, name, sizeof(slots[i].name) - 1);
    pthread_mutex_unlock(&slotLock);
    return i;
}

static long long nanos(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (long long)t.tv_sec * 1000000000LL + t.tv_nsec;
}

#define R(f) (((ShimFile *)(f))->real)
static int xClose(sqlite3_file *f) { return R(f)->pMethods->xClose(R(f)); }
static int xRead(sqlite3_file *f, void *b, int n, sqlite3_int64 o) { return R(f)->pMethods->xRead(R(f), b, n, o); }
static int xWrite(sqlite3_file *f, const void *b, int n, sqlite3_int64 o) {
    ShimFile *p = (ShimFile *)f; Slot *s = &slots[p->slot];
    atomic_fetch_add(&s->writes, 1); atomic_fetch_add(&s->bytes, n);
    const unsigned char *u = b;
    if (p->isWal) {
        // WAL header (32 bytes) names the page size; each frame is a
        // 24-byte header then a page, and a commit frame names the size.
        if (o == 0 && n >= 32) p->pageSize = (u[8] << 24) | (u[9] << 16) | (u[10] << 8) | u[11];
        long long stride = 24 + (p->pageSize ? p->pageSize : 4096);
        for (long long at = 0; at + 24 <= n; at += stride) {
            long long off = o + at;
            if (off < 32 || (off - 32) % stride != 0) break;
            const unsigned char *h = u + at;
            unsigned commit = (h[4] << 24) | (h[5] << 16) | (h[6] << 8) | h[7];
            if (commit) atomic_fetch_add(&s->commits, 1);
        }
    }
    return R(f)->pMethods->xWrite(R(f), b, n, o);
}
static int xTruncate(sqlite3_file *f, sqlite3_int64 s) { return R(f)->pMethods->xTruncate(R(f), s); }
static int xSync(sqlite3_file *f, int flags) {
    Slot *s = &slots[((ShimFile *)f)->slot];
    long long start = nanos();
    int rc = R(f)->pMethods->xSync(R(f), flags);
    atomic_fetch_add(&s->syncs, 1);
    atomic_fetch_add(&s->syncNanos, nanos() - start);
    return rc;
}
static int xFileSize(sqlite3_file *f, sqlite3_int64 *s) { return R(f)->pMethods->xFileSize(R(f), s); }
static int xLock(sqlite3_file *f, int l) { return R(f)->pMethods->xLock(R(f), l); }
static int xUnlock(sqlite3_file *f, int l) { return R(f)->pMethods->xUnlock(R(f), l); }
static int xCheckReservedLock(sqlite3_file *f, int *r) { return R(f)->pMethods->xCheckReservedLock(R(f), r); }
static int xFileControl(sqlite3_file *f, int op, void *a) { return R(f)->pMethods->xFileControl(R(f), op, a); }
static int xSectorSize(sqlite3_file *f) { return R(f)->pMethods->xSectorSize(R(f)); }
static int xDeviceCharacteristics(sqlite3_file *f) { return R(f)->pMethods->xDeviceCharacteristics(R(f)); }
static int xShmMap(sqlite3_file *f, int i, int sz, int e, void volatile **pp) { return R(f)->pMethods->xShmMap(R(f), i, sz, e, pp); }
static int xShmLock(sqlite3_file *f, int o, int n, int fl) { return R(f)->pMethods->xShmLock(R(f), o, n, fl); }
static void xShmBarrier(sqlite3_file *f) { R(f)->pMethods->xShmBarrier(R(f)); }
static int xShmUnmap(sqlite3_file *f, int d) { return R(f)->pMethods->xShmUnmap(R(f), d); }
static int xFetch(sqlite3_file *f, sqlite3_int64 o, int n, void **pp) { return R(f)->pMethods->xFetch(R(f), o, n, pp); }
static int xUnfetch(sqlite3_file *f, sqlite3_int64 o, void *p) { return R(f)->pMethods->xUnfetch(R(f), o, p); }

static const sqlite3_io_methods methods = {
    3, xClose, xRead, xWrite, xTruncate, xSync, xFileSize, xLock, xUnlock, xCheckReservedLock,
    xFileControl, xSectorSize, xDeviceCharacteristics, xShmMap, xShmLock, xShmBarrier, xShmUnmap, xFetch, xUnfetch
};

static int xOpen(sqlite3_vfs *v, const char *name, sqlite3_file *f, int flags, int *out) {
    ShimFile *p = (ShimFile *)f;
    p->real = (sqlite3_file *)&p[1];
    p->slot = slotFor(name);
    p->isWal = (flags & SQLITE_OPEN_WAL) != 0;
    p->pageSize = 0;
    int rc = orig->xOpen(orig, name, p->real, flags, out);
    p->base.pMethods = p->real->pMethods ? &methods : NULL;
    return rc;
}

int bench_vfs_install(void) {
    if (orig) return SQLITE_OK;
    orig = sqlite3_vfs_find(NULL);
    shim = *orig;
    shim.szOsFile = (int)sizeof(ShimFile) + orig->szOsFile;
    shim.zName = "benchshim";
    shim.pNext = NULL;
    shim.xOpen = xOpen;
    return sqlite3_vfs_register(&shim, 1);
}

void bench_vfs_dump(const char *path) {
    FILE *out = fopen(path, "w");
    if (!out) return;
    for (int i = 0; i < nslots; i++) {
        Slot *s = &slots[i];
        fprintf(out, "file %s writes %lld bytes %lld syncs %lld syncms %.3f commits %lld\n", s->name,
                (long long)s->writes, (long long)s->bytes, (long long)s->syncs, (double)s->syncNanos / 1e6,
                (long long)s->commits);
    }
    fclose(out);
}
