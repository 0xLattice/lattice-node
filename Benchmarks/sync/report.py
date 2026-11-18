#!/usr/bin/env python3
"""report.py <run-dir>...: the sync benchmark's tables from run.sh outputs.

Per block means per block synced over every level (the sum of the recorded
heights). W = header weighing jobs (proof checks + derivations), B = body
fetch, E = connect jobs, P = the step's facts transaction (one per step, all
levels). Job and fetch times are summed run times; with more than one worker
or fetches in flight they overlap, so they need not add up to wall time.
Trace figures count only lines between the follower's start and done
markers. A run without a trace (TRACE=0) shows no split. Every job label
seen is listed, so a renamed job shows up instead of reading as zero."""
import collections, os, re, sys

def fail(d, why):
    sys.exit('%s: %s' % (d, why))

def run(d):
    out = open(os.path.join(d, 'out')).read()
    r = {'name': os.path.basename(os.path.normpath(d))}
    m = re.search(r'CHILD_BENCH follow blocks (\d+) wall ([\d.]+) cpu ([\d.]+) written (\d+) KiB rss (\d+) MiB disk (\d+) MiB', out)
    if not m: fail(d, 'no follow summary: the run did not finish')
    if re.search(r': error: |Test Case .* failed', out): fail(d, 'the follower test failed (see out)')
    r['blocks'], r['wall'], r['cpu'], r['written'], r['rss'], r['disk'] = int(m[1]), float(m[2]), float(m[3]), int(m[4]), int(m[5]), int(m[6])
    r['workers'] = re.search(r'workers (\d+)', out)[1]
    r['ref'] = open(os.path.join(d, 'ref')).read()[:9]
    r['levels'] = {l[0]: dict(height=int(l[1]), wall=float(l[2])) for l in
                   re.findall(r'CHILD_BENCH level (\S+) height (\d+) wall ([\d.]+)', out)}
    v = collections.Counter()
    for line in open(os.path.join(d, 'vfs.txt')):
        f = line.split()
        p = dict(zip(f[2::2], f[3::2]))
        for k in ('writes', 'bytes', 'syncs', 'commits'): v[k] += int(p[k])
        v['syncms'] += float(p['syncms'])
    r['vfs'] = v
    r['traced'] = os.path.exists(os.path.join(d, 'trace'))
    if not r['traced']: return r
    jobs = collections.defaultdict(lambda: [0, 0.0]); bodies = collections.defaultdict(lambda: [0, 0.0])
    steps = [0, 0.0, 0.0, 0.0]; inside = None
    for line in open(os.path.join(d, 'trace'), errors='replace'):
        if '[bench] follower start' in line: inside = True; continue
        if '[bench] follower done' in line: inside = False; continue
        if not inside: continue
        m = re.search(r'\] job (\S+) (\S+) queued [\d.-]+ run ([\d.-]+) loop', line)
        if m: j = jobs[(m[1], m[2])]; j[0] += 1; j[1] += float(m[3]); continue
        m = re.search(r'\[(\S+)\] body \S+ fetch ([\d.-]+) loop', line)
        if m: b = bodies[m[1]]; b[0] += 1; b[1] += float(m[2]); continue
        m = re.search(r'node-runtime step .* core ([\d.]+) ms total ([\d.]+) ms persist ([\d.]+) ms', line)
        if m: steps[0] += 1; steps[1] += float(m[1]); steps[2] += float(m[2]); steps[3] += float(m[3])
    if inside is None: fail(d, 'no follower start marker in the trace')
    if not steps[0]: fail(d, 'no step lines with persist time in the trace')
    for label in ('proofVerified', 'connected'):
        if not any(k[0] == label for k in jobs): fail(d, 'no %s jobs in the trace' % label)
    r['jobs'], r['bodies'], r['steps'] = jobs, bodies, steps
    return r

runs = [run(d) for d in sys.argv[1:]]
dash = lambda r, x: x if r['traced'] else '-'
print('| run | ref | workers | blocks | wall s | wall ms/blk | CPU ms/blk | commits/blk | fsyncs/blk | fsync ms/blk | SQLite KB/blk | disk write KB/blk | kept MiB | peak RSS MiB | steps/blk | P ms/blk | loop ms/blk |')
print('|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|')
for r in runs:
    n, v = r['blocks'], r['vfs']
    s = r.get('steps', [0, 0, 0, 0])
    print('| %s | %s | %s | %d | %.1f | %.2f | %.2f | %.2f | %.2f | %.2f | %.1f | %.1f | %d | %d | %s | %s | %s |' % (
        r['name'], r['ref'], r['workers'], n, r['wall'], r['wall'] * 1e3 / n, r['cpu'] * 1e3 / n, v['commits'] / n, v['syncs'] / n,
        v['syncms'] / n, v['bytes'] / 1024 / n, r['written'] / n, r['disk'], r['rss'],
        dash(r, '%.2f' % (s[0] / n)), dash(r, '%.2f' % (s[3] / n)), dash(r, '%.2f' % (s[2] / n))))
traced = [r for r in runs if r['traced']]
if not traced: sys.exit()
print()
print('| run | level | blocks | at tip s | proof checks | derivations | W ms/blk | B fetches | B ms/fetch | E connects | E ms/blk |')
print('|---|---|---|---|---|---|---|---|---|---|---|')
for r in traced:
    for path, l in r['levels'].items():
        h = max(l['height'], 1); j = r['jobs']
        check, derive, conn = j.get(('proofVerified', path), [0, 0]), j.get(('derived', path), [0, 0]), j.get(('connected', path), [0, 0])
        b = r['bodies'].get(path, [0, 0])
        print('| %s | %s | %d | %.1f | %d | %d | %.2f | %d | %.2f | %d | %.2f |' % (
            r['name'], path, l['height'], l['wall'], check[0], derive[0], (check[1] + derive[1]) / h,
            b[0], b[1] / max(b[0], 1), conn[0], conn[1] / h))
print()
print('| run | job label | level | jobs | run ms total |')
print('|---|---|---|---|---|')
for r in traced:
    for (label, path), (count, ms) in sorted(r['jobs'].items()):
        print('| %s | %s | %s | %d | %.0f |' % (r['name'], label, path, count, ms))
