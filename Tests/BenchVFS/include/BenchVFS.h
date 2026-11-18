#pragma once
/// Sync benchmark only (ChildSyncBench). Installs a default SQLite VFS that
/// forwards to the platform VFS and counts, per file: xWrite calls and bytes,
/// xSync calls and the time spent in them, and for -wal files the commit
/// frames written. (SQLite's ext/misc/vfsstat.c counts the same calls; this
/// adds commits and sync time.)
int bench_vfs_install(void);
/// Writes the counters to `path` as text, one line per file.
void bench_vfs_dump(const char *path);
