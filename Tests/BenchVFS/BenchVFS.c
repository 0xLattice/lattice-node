#include "BenchVFS.h"
#include <sqlite3.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>
#include <time.h>

#define MAX_SLOTS 256
typedef struct {
    char name[1024];
    _Atomic long long writes, bytes, syncs, syncNanos, commits;
    // With pages on (bench_vfs_pages), bytes written per page number of a
    // database file: its log's frames and its own pages, since the last
    // attribution.
    pthread_mutex_t pageLock;
    long long *walPage, *dbPage;
    int pageCap;
} Slot;
static Slot slots[MAX_SLOTS];
static int nslots = 0;
static pthread_mutex_t slotLock = PTHREAD_MUTEX_INITIALIZER;
static sqlite3_vfs *orig;
static sqlite3_vfs shim;

typedef struct { sqlite3_file base; int slot; int isWal; int pageSize; int dbSlot; sqlite3_file *real; } ShimFile;
static _Atomic int pagesOn = 0;

static int slotFor(const char *name) {
    if (!name) name = "(temp)";
    pthread_mutex_lock(&slotLock);
    for (int i = 0; i < nslots; i++) if (strcmp(slots[i].name, name) == 0) { pthread_mutex_unlock(&slotLock); return i; }
    // Past the last slot, every other file shares it.
    int i = nslots < MAX_SLOTS - 1 ? nslots++ : MAX_SLOTS - 1;
    if (!slots[i].name[0]) {
        strncpy(slots[i].name, i == MAX_SLOTS - 1 ? "(others)" : name, sizeof(slots[i].name) - 1);
        pthread_mutex_init(&slots[i].pageLock, NULL);
    }
    pthread_mutex_unlock(&slotLock);
    return i;
}

/// Adds `bytes` to page `pgno` of a database file's log or own pages.
static void notePage(int slot, int wal, long long pgno, long long bytes) {
    if (pgno < 1 || pgno > (1 << 26)) return;
    Slot *s = &slots[slot];
    pthread_mutex_lock(&s->pageLock);
    if (pgno >= s->pageCap) {
        int cap = s->pageCap ? s->pageCap : 4096;
        while (cap <= pgno) cap *= 2;
        long long *w = calloc(cap, sizeof(long long)), *d = calloc(cap, sizeof(long long));
        if (s->pageCap) {
            memcpy(w, s->walPage, s->pageCap * sizeof(long long));
            memcpy(d, s->dbPage, s->pageCap * sizeof(long long));
            free(s->walPage); free(s->dbPage);
        }
        s->walPage = w; s->dbPage = d; s->pageCap = cap;
    }
    (wal ? s->walPage : s->dbPage)[pgno] += bytes;
    pthread_mutex_unlock(&s->pageLock);
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
            if (pagesOn && p->dbSlot >= 0) {
                unsigned pgno = ((unsigned)h[0] << 24) | (h[1] << 16) | (h[2] << 8) | h[3];
                notePage(p->dbSlot, 1, pgno, stride);
            }
        }
    } else if (pagesOn && p->dbSlot >= 0 && n >= 512 && (n & (n - 1)) == 0 && o % n == 0) {
        // A database file is written a whole page at a time.
        notePage(p->dbSlot, 0, o / n + 1, n);
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
    p->dbSlot = -1;
    if (name && (flags & SQLITE_OPEN_MAIN_DB)) p->dbSlot = p->slot;
    size_t len = name ? strlen(name) : 0;
    if (p->isWal && len > 4 && len < 1024 && strcmp(name + len - 4, "-wal") == 0) {
        char db[1024];
        memcpy(db, name, len - 4); db[len - 4] = 0;
        p->dbSlot = slotFor(db);
    }
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


/// Bytes written to each b-tree (table or index) of each database file, as
/// attributed so far: the log's frames and the checkpoint's page writes.
#define MAX_TREES 512
typedef struct { int slot; char tree[128]; long long wal, db; } Tree;
static Tree trees[MAX_TREES];
static int ntrees = 0;
static pthread_mutex_t treeLock = PTHREAD_MUTEX_INITIALIZER;

static Tree *treeFor(int slot, const char *name) {
    for (int i = 0; i < ntrees; i++) if (trees[i].slot == slot && strcmp(trees[i].tree, name) == 0) return &trees[i];
    int i = ntrees < MAX_TREES - 1 ? ntrees++ : MAX_TREES - 1;
    trees[i].slot = slot;
    strncpy(trees[i].tree, name, sizeof(trees[i].tree) - 1);
    return &trees[i];
}

void bench_vfs_pages(void) { pagesOn = 1; }

void bench_vfs_attribute(void) {
    if (!pagesOn) return;
    pthread_mutex_lock(&treeLock);
    int count = nslots;
    for (int i = 0; i < count; i++) {
        Slot *s = &slots[i];
        if (!s->pageCap) continue;
        // Which b-tree each page is in now, from SQLite's dbstat table, read
        // through a connection of its own.
        sqlite3 *db = NULL;
        char **names = NULL; int *owner = NULL; int nnames = 0, cap = 0;
        if (sqlite3_open_v2(s->name, &db, SQLITE_OPEN_READONLY, NULL) == SQLITE_OK) {
            sqlite3_busy_timeout(db, 5000);
            sqlite3_stmt *st = NULL;
            if (sqlite3_prepare_v2(db, "SELECT name, pageno FROM dbstat", -1, &st, NULL) == SQLITE_OK) {
                while (sqlite3_step(st) == SQLITE_ROW) {
                    const char *name = (const char *)sqlite3_column_text(st, 0);
                    long long pgno = sqlite3_column_int64(st, 1);
                    if (!name || pgno < 1 || pgno > (1 << 26)) continue;
                    if (pgno >= cap) {
                        int grown = cap ? cap : 4096;
                        while (grown <= pgno) grown *= 2;
                        owner = realloc(owner, grown * sizeof(int));
                        for (int k = cap; k < grown; k++) owner[k] = -1;
                        cap = grown;
                    }
                    int at = -1;
                    for (int k = nnames - 1; k >= 0; k--) if (strcmp(names[k], name) == 0) { at = k; break; }
                    if (at < 0) { names = realloc(names, (nnames + 1) * sizeof(char *)); names[nnames] = strdup(name); at = nnames++; }
                    owner[pgno] = at;
                }
            }
            sqlite3_finalize(st);
        }
        sqlite3_close(db);
        pthread_mutex_lock(&s->pageLock);
        for (int p = 1; p < s->pageCap; p++) {
            if (!s->walPage[p] && !s->dbPage[p]) continue;
            // A page in no b-tree now is free, or past the file's end.
            const char *name = p < cap && owner[p] >= 0 ? names[owner[p]] : "(free)";
            Tree *t = treeFor(i, name);
            t->wal += s->walPage[p]; t->db += s->dbPage[p];
            s->walPage[p] = 0; s->dbPage[p] = 0;
        }
        pthread_mutex_unlock(&s->pageLock);
        for (int k = 0; k < nnames; k++) free(names[k]);
        free(names); free(owner);
    }
    pthread_mutex_unlock(&treeLock);
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
    pthread_mutex_lock(&treeLock);
    for (int i = 0; i < ntrees; i++)
        fprintf(out, "tree %s %s wal %lld db %lld\n", slots[trees[i].slot].name, trees[i].tree, trees[i].wal, trees[i].db);
    pthread_mutex_unlock(&treeLock);
    fclose(out);
}
