#pragma once
/// The sync benchmark (ChildSyncBench) and power-loss tests. Installs a default SQLite VFS that
/// forwards to the platform VFS and counts, per file: xWrite calls and bytes,
/// xSync calls and the time spent in them, and for -wal files the commit
/// frames written. (SQLite's ext/misc/vfsstat.c counts the same calls; this
/// adds commits and sync time.)
int bench_vfs_install(void);
/// Writes the counters to `path` as text, one line per file.
void bench_vfs_dump(const char *path);
/// Power-loss tests. For every database file opened after this call whose
/// path starts with `prefix`, keeps the file's bytes as of each sync beside it
/// as "<path>.durable": what a power loss at any later moment is sure to
/// leave. An empty prefix stops it for files opened afterwards.
void bench_vfs_keep_synced(const char *prefix);
