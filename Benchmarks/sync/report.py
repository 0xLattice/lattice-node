#!/usr/bin/env python3
"""report.py <run-dir>...: the sync benchmark's tables from run.sh outputs.

Per block means per block synced over every level (the sum of the recorded
heights). W = header weighing jobs (proof checks + derivations), B = body
fetch, E = connect jobs, P = the step's facts transaction (one per step, all
levels). Job and fetch times are summed run times; with more than one worker
or fetches in flight they overlap, so they need not add up to wall time.
Trace figures count only lines between the follower's start and done
markers. A run without a trace (TRACE=0) shows no split. Every job label
seen is listed, so a renamed job shows up instead of reading as zero.

Per chain: when the level's act-on tip first moved, reached half its
recorded height and reached it (the follower polls every 50 ms). Totals:
the whole sync, for comparing runs that host different numbers of chains
(HOSTED); loopback MiB is the loopback interface's bytes in one direction
over the sync, server to follower and back, plus any other local traffic.
With PAGES, the bytes written to each table and index (log frames and
checkpoint writes); with a trace, what the node handed the Volume store to
write, by kind; with TALLY, how often the node's work read each CID."""
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
    # What the follower kept: runs of different settings are told apart.
    # Runs from before the state buffer was removed also name its limit.
    kept = re.search(r'CHILD_BENCH follower .* state (\w+) bodies (\w+)(?: buffer (\d+))?', out)
    r['keeps'] = ('%s/%s' % (kept[1], kept[2]) + (' (buffer %d MiB)' % (int(kept[3]) >> 20) if kept[3] else '')
                  if kept else 'recent/all')
    r['ref'] = open(os.path.join(d, 'ref')).read()[:9]
    r['levels'] = {l[0]: dict(height=int(l[1]), wall=float(l[2])) for l in
                   re.findall(r'CHILD_BENCH level (\S+) height (\d+) wall ([\d.]+)', out)}
    v = collections.Counter()
    trees = collections.defaultdict(lambda: [0, 0])
    for line in open(os.path.join(d, 'vfs.txt')):
        f = line.split()
        if f[0] == 'tree':
            t = trees[(os.path.basename(f[1]), f[2])]; t[0] += int(f[4]); t[1] += int(f[6]); continue
        p = dict(zip(f[2::2], f[3::2]))
        for k in ('writes', 'bytes', 'syncs', 'commits'): v[k] += int(p[k])
        v['syncms'] += float(p['syncms'])
    r['vfs'], r['trees'] = v, trees
    r['hosted'] = (re.search(r'CHILD_BENCH follower .* hosted (\d+)', out) or [None, '-'])[1]
    r['levels_at'] = {l[0]: dict(height=int(l[1]), tip=float(l[2]), moved=float(l[3]), half=float(l[4])) for l in
                      re.findall(r'CHILD_BENCH level (\S+) height (\d+) wall ([\d.]+) cpu [\d.]+ moved ([\d.]+) half ([\d.]+)', out)}
    r['reads'] = re.findall(r'CHILD_BENCH (reads .*)', out)
    r['net'] = None
    net = os.path.join(d, 'net.txt')
    if os.path.exists(net):
        rows = [l.split() for l in open(net) if l.strip()]
        if len(rows) == 2: r['net'] = int(rows[1][0]) - int(rows[0][0])
    r['traced'] = os.path.exists(os.path.join(d, 'trace'))
    if not r['traced']: return r
    jobs = collections.defaultdict(lambda: [0, 0.0]); bodies = collections.defaultdict(lambda: [0, 0.0])
    stored = collections.defaultdict(lambda: [0, 0, 0, 0, 0, 0]); r['stored'] = stored
    received = collections.defaultdict(lambda: [0, 0, 0]); r['received'] = received
    fields = collections.defaultdict(lambda: collections.Counter()); r['fields'] = fields
    steps = [0, 0.0, 0.0, 0.0]; inside = None
    for line in open(os.path.join(d, 'trace'), errors='replace'):
        if '[bench] follower start' in line: inside = True; continue
        if '[bench] follower done' in line: inside = False; continue
        if not inside: continue
        m = re.search(r'\] job (\S+) (\S+) queued [\d.-]+ run ([\d.-]+) loop', line)
        if m: j = jobs[(m[1], m[2])]; j[0] += 1; j[1] += float(m[3]); continue
        m = re.search(r'\[(\S+)\] body \S+ fetch ([\d.-]+) loop', line)
        if m: b = bodies[m[1]]; b[0] += 1; b[1] += float(m[2]); continue
        m = re.search(r'stored (\w+) volumes (\d+) entries (\d+) bytes (\d+) cidBytes (\d+) retained (\d+)', line)
        if m:
            s = stored[m[1]]; s[0] += 1
            for i in range(5): s[i + 1] += int(m[i + 2])
            continue
        m = re.search(r'\] message received (\S+) bytes (\d+)', line)
        if m: x = received['message ' + m[1]]; x[0] += 1; x[1] += int(m[2]); continue
        m = re.search(r'\[(\S+)\] headers received entries (\d+) block (\d+) children (\d+) proofs (\d+) proofBytes (\d+) spec (\d+) payload (\d+)', line)
        if m:
            x = fields[m[1]]
            for k, v in zip(('entries', 'block', 'children', 'proofs', 'proofBytes', 'spec', 'payload'), m.groups()[1:]): x[k] += int(v)
            continue
        m = re.search(r'\] content received entries (\d+) bytes (\d+) cidBytes (\d+)', line)
        if m: x = received['volume entries']; x[0] += int(m[1]); x[1] += int(m[2]); x[2] += int(m[3]); continue
        m = re.search(r'node-runtime step .* core ([\d.]+) ms total ([\d.]+) ms persist ([\d.]+) ms', line)
        if m: steps[0] += 1; steps[1] += float(m[1]); steps[2] += float(m[2]); steps[3] += float(m[3])
    if inside is None: fail(d, 'no follower start marker in the trace')
    if not steps[0]: fail(d, 'no step lines with persist time in the trace')
    # Grind proofs come with child-only shares: a follower of Nexus alone
    # verifies none.
    for label in ('connected',) if r['hosted'] == '0' else ('proofsVerified', 'connected'):
        if not any(k[0] == label for k in jobs): fail(d, 'no %s jobs in the trace' % label)
    r['jobs'], r['bodies'], r['steps'] = jobs, bodies, steps
    return r

runs = [run(d) for d in sys.argv[1:]]
dash = lambda r, x: x if r['traced'] else '-'
print('| run | ref | workers | state/bodies | blocks | wall s | wall ms/blk | CPU ms/blk | commits/blk | fsyncs/blk | fsync ms/blk | SQLite KB/blk | disk write KB/blk | kept MiB | peak RSS MiB | steps/blk | P ms/blk | loop ms/blk |')
print('|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|')
for r in runs:
    n, v = r['blocks'], r['vfs']
    s = r.get('steps', [0, 0, 0, 0])
    print('| %s | %s | %s | %s | %d | %.1f | %.2f | %.2f | %.2f | %.2f | %.2f | %.1f | %.1f | %d | %d | %s | %s | %s |' % (
        r['name'], r['ref'], r['workers'], r['keeps'], n, r['wall'], r['wall'] * 1e3 / n, r['cpu'] * 1e3 / n, v['commits'] / n, v['syncs'] / n,
        v['syncms'] / n, v['bytes'] / 1024 / n, r['written'] / n, r['disk'], r['rss'],
        dash(r, '%.2f' % (s[0] / n)), dash(r, '%.2f' % (s[3] / n)), dash(r, '%.2f' % (s[2] / n))))
MiB = 1 << 20
print()
print('| run | hosted | blocks | wall s | CPU s | peak RSS MiB | kept MiB | SQLite written MiB | loopback MiB |')
print('|---|---|---|---|---|---|---|---|---|')
for r in runs:
    print('| %s | %s | %d | %.1f | %.1f | %d | %d | %.0f | %s |' % (
        r['name'], r['hosted'], r['blocks'], r['wall'], r['cpu'], r['rss'], r['disk'], r['vfs']['bytes'] / MiB,
        '%.0f' % (r['net'] / MiB) if r['net'] is not None else '-'))
print()
print('| run | level | height | tip first moved s | half s | at tip s | blocks/s while moving |')
print('|---|---|---|---|---|---|---|')
for r in runs:
    for path, l in r['levels_at'].items():
        span = l['tip'] - l['moved']
        print('| %s | %s | %d | %.1f | %.1f | %.1f | %s |' % (
            r['name'], path, l['height'], l['moved'], l['half'], l['tip'], '%.0f' % (l['height'] / span) if span > 0 else '-'))
for r in runs:
    if not r['trees']: continue
    total = sum(w + b for w, b in r['trees'].values())
    print()
    print('Written by table and index, %s (%.0f MiB in all, %.1f KB/blk)' % (r['name'], total / MiB, total / 1024 / r['blocks']))
    print()
    print('| file | table or index | log MiB | checkpoint MiB | total MiB | share |')
    print('|---|---|---|---|---|---|')
    for (db, tree), (w, b) in sorted(r['trees'].items(), key=lambda kv: -sum(kv[1])):
        if (w + b) * 1000 < total: continue
        print('| %s | %s | %.1f | %.1f | %.1f | %.1f%% |' % (db, tree, w / MiB, b / MiB, (w + b) / MiB, 100 * (w + b) / total))
for r in runs:
    if not r.get('stored'): continue
    print()
    print('Handed to the Volume store, %s' % r['name'])
    print()
    print('| kind | stores | volumes | entries | entry MiB | CID text MiB | roots retained |')
    print('|---|---|---|---|---|---|---|')
    for kind, s in sorted(r['stored'].items()):
        print('| %s | %d | %d | %d | %.1f | %.1f | %d |' % (kind, s[0], s[1], s[2], s[3] / MiB, s[4] / MiB, s[5]))
for r in runs:
    if not r.get('received'): continue
    print()
    print('Received from peers, %s (payloads, before transport framing; loopback carried %s MiB)' % (
        r['name'], '%.0f' % (r['net'] / MiB) if r['net'] is not None else '-'))
    print()
    print('| what | count | MiB | of which CID text MiB |')
    print('|---|---|---|---|')
    for what, x in sorted(r['received'].items(), key=lambda kv: -kv[1][1]):
        print('| %s | %d | %.1f | %s |' % (what, x[0], x[1] / MiB, '%.1f' % (x[2] / MiB) if x[2] else '-'))
for r in runs:
    if not r.get('fields'): continue
    print()
    print('Headers responses by field, %s (raw bytes; the JSON payload carries them as base64)' % r['name'])
    print()
    print('| level | entries | block KiB | child index KiB | proofs | proof KiB | spec KiB | payload KiB | payload KB/entry |')
    print('|---|---|---|---|---|---|---|---|---|')
    for path, x in sorted(r['fields'].items()):
        print('| %s | %d | %.0f | %.0f | %d | %.0f | %.0f | %.0f | %.1f |' % (
            path, x['entries'], x['block'] / 1024, x['children'] / 1024, x['proofs'], x['proofBytes'] / 1024,
            x['spec'] / 1024, x['payload'] / 1024, x['payload'] / 1000 / max(x['entries'], 1)))
for r in runs:
    if not r['reads']: continue
    print()
    print('Reads by CID, %s' % r['name'])
    print()
    for line in r['reads']: print('    ' + line)
traced = [r for r in runs if r['traced']]
if not traced: sys.exit()
print()
print('| run | level | blocks | at tip s | proof checks | derivations | W ms/blk | B fetches | B ms/fetch | E connects | E ms/blk |')
print('|---|---|---|---|---|---|---|---|---|---|---|')
for r in traced:
    for path, l in r['levels'].items():
        h = max(l['height'], 1); j = r['jobs']
        check, derive, conn = j.get(('proofsVerified', path), [0, 0]), j.get(('derived', path), [0, 0]), j.get(('connected', path), [0, 0])
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
