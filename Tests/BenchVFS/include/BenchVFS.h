#pragma once
/// The sync benchmark (ChildSyncBench) and the crash tests. Installs a default SQLite VFS that
/// forwards to the platform VFS and counts, per file: xWrite calls and bytes,
/// xSync calls and the time spent in them, and for -wal files the commit
/// frames written. (SQLite's ext/misc/vfsstat.c counts the same calls; this
/// adds commits and sync time.)
int bench_vfs_install(void);
/// Writes the counters to `path` as text, one line per file.
void bench_vfs_dump(const char *path);
/// Counts, from now on, the bytes written to each page of each database
/// file, through its write-ahead log and to the file itself.
void bench_vfs_pages(void);
/// Attributes the page bytes counted since the last call to the b-tree
/// (table or index) each page is in now, from SQLite's dbstat table. Pages
/// are reused, so the sooner after the writes, the truer: call it often.
void bench_vfs_attribute(void);
/// Tests: a crash. After `writes` more writes to files under `prefix`, every
/// write, sync and truncate of those files fails, as in a process that died
/// there. Other files are untouched.
void bench_vfs_fail_after(const char *prefix, long long writes);
/// Writes go through again.
void bench_vfs_fail_off(void);
/// Whether the crash has come.
int bench_vfs_failed(void);
