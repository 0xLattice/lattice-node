#!/usr/bin/env python3
"""profile.py <sample.txt> [--top N]: where the follower's CPU went, from a
macOS `sample` call graph (native.sh PROFILE=1).

Busy samples are the samples whose innermost frame is not a wait (a thread
parked in the kernel), nor a sync to the disk (fsync, fcntl), which is
counted apart as I/O wait. Each activity's share is the busy samples under its
first matching frame on a stack, so nested matches count once; different
activities overlap where one calls another (decoding content includes the
CID parsing it does). With --top, the N frames with the most busy samples
under them are listed as well, to find what an activity should match."""
import collections, re, sys

# Innermost frames that are a thread waiting, not working.
IDLE = re.compile(r'^(__workq_kernreturn|kevent|kevent_id|mach_msg2_trap|mach_msg_trap|__psynch_cvwait|__psynch_mutexwait'
                  r'|__semwait_signal|__ulock_wait2?|semaphore_wait_trap|__select|poll|start_wqthread|syscall_thread_switch'
                  r'|__bsdthread_ctl|thread_start|_pthread_start)$')

# Innermost frames that are a thread waiting for the disk to sync.
IO_WAIT = re.compile(r'^(__fcntl|fcntl|fsync|fdatasync)$')

# Activities, by the frames that start them. Order is only the table's.
ACTIVITIES = [
    ('Wire frames decoded (ChainSyncWire.decode)', r'ChainSyncWire\.decode\(topic:payload:\)'),
    ('  of which JSON parsed and checked canonical', r'CanonicalJSONMessage\.decoded'),
    ('  of which header entries decoded (DAG-CBOR, proofs)', r'WireHeaderEntry\.decoded'),
    ('Volume store reads (SQLite)', r'CASVolumeStore\.(fetchDataLocal|loadServableData|fetchVolumeLocal)'),
    ('Volume store writes (SQLite)', r'CASVolumeStore\.storeVolumesLocal|RetainedRootIndex\.|CountedRootIndex\.'),
    ('Facts written (state.db)', r'NodeStore\.stageNodeFacts'),
    ('Execution (connect jobs)', r'NodeRuntime\.connectJob'),
    ('Derivations (child blocks from the parent)', r'ChildDeriveJob\.run'),
    ('Core decisions (NodeCore.step)', r'NodeCore\.step'),
    ('CID text parsed (CID.init from a string)', r'^(specialized )?CID\.init\(_:(base:)?\)|^CIDDigest\.init\(_:\)|CIDDigest\.words\(decoding:\)'),
    ('CID text formatted (CID to string)', r'CIDDigest\.string\.getter|^(specialized )?CID\.description|CIDIdentity\.canonicalString|^(specialized )?CID\.encoded'),
    ('CID computed for content (encode + hash)', r'computeCID\(for:codec:\)|_standardCID\(of:\)'),
    ('Content hash checked against its CID', r'verifyContentAddress|verifyData\(_:matches:\)|isCanonicalDagCBORSHA256CID'),
    ('Content read and decoded by CID (fetchAndDecodeNode)', r'fetchAndDecodeNode\(fetcher:\)'),
    ('DAG-CBOR decode', r'DagCBOR.*[Dd]ecod|CBOR.*[Dd]ecod|init\?\(data:\)|\.init\(data:\)'),
    ('DAG-CBOR encode', r'DagCBOR.*[Ee]ncod|CBOR.*[Ee]ncod|toData\(\)'),
    ('JSON decode', r'JSONDecoder|JSONScanner|JSONDecoderImpl|JSONSerialization\.jsonObject'),
    ('JSON encode', r'JSONEncoder|JSONWriter|JSONSerialization\.data|canonicalJSON'),
    ('Base64', r'Base64\.'),
    ('SHA-256', r'SHA2\.|SHA256|AccelerateCrypto_SHA256'),
    ('SQLite', r'^sqlite3_|^sqlite3[A-Z]'),
    ('Hashing for Swift dictionaries and sets', r'^Hasher\.|hash\(into:\)|_rawHashValue'),
    ('Allocation and reference counting', r'^swift_(retain|release|allocObject|bridgeObject)|malloc|^_free$|_xzm_'),
]

LINE = re.compile(r'^(\s+[+!:| ]*)(\d+) (.*)$')

def symbol(text):
    text = re.sub(r'\s+\(in [^)]*\).*$', '', text)
    return re.sub(r'\s+\S+\.swift:\d+$', '', text).strip()

def parse(path):
    """The call graph as (depth, count, symbol) rows, in order."""
    rows, inside = [], False
    for line in open(path, errors='replace'):
        if line.startswith('Call graph:'): inside = True; continue
        if inside and (line.startswith('Total number') or not line.strip()):
            if rows: break
            continue
        if not inside: continue
        m = LINE.match(line.rstrip('\n'))
        if m: rows.append((len(m[1]), int(m[2]), symbol(m[3])))
    return rows

def main():
    path = sys.argv[1]
    top = int(sys.argv[sys.argv.index('--top') + 1]) if '--top' in sys.argv else 0
    rows = parse(path)
    if not rows: sys.exit('%s: no call graph' % path)
    # Self samples of a row: its count less its children's.
    n = len(rows)
    selfs = [c for _, c, _ in rows]
    stack = []
    for i, (depth, count, _) in enumerate(rows):
        while stack and rows[stack[-1]][0] >= depth: stack.pop()
        if stack: selfs[stack[-1]] -= count
        stack.append(i)
    io_wait = sum(max(selfs[i], 0) for i in range(n) if IO_WAIT.match(rows[i][2]))
    busy_self = [0 if IDLE.match(rows[i][2]) or IO_WAIT.match(rows[i][2]) else max(selfs[i], 0) for i in range(n)]
    # Busy samples under each row (its own and its descendants').
    under = busy_self[:]
    parents = [-1] * n
    stack = []
    for i, (depth, _, _) in enumerate(rows):
        while stack and rows[stack[-1]][0] >= depth: stack.pop()
        parents[i] = stack[-1] if stack else -1
        stack.append(i)
    for i in range(n - 1, -1, -1):
        if parents[i] >= 0: under[parents[i]] += under[i]
    busy = sum(busy_self)
    top_depth = min(r[0] for r in rows)
    total = sum(c for d, c, _ in rows if d == top_depth)
    patterns = [(name, re.compile(p)) for name, p in ACTIVITIES]
    shares, by_symbol = collections.Counter(), collections.Counter()
    # Rows come in stack order: keep the frames on the current stack, and
    # count a row for an activity (or its symbol) only when no frame below
    # it on the stack already did.
    stack, on_activity, on_symbol = [], collections.Counter(), collections.Counter()
    matches = {}
    for i in range(n):
        depth, _, sym = rows[i]
        while stack and rows[stack[-1]][0] >= depth:
            j = stack.pop()
            for name in matches[j]: on_activity[name] -= 1
            on_symbol[rows[j][2]] -= 1
        if sym not in matches:
            matches[sym] = [name for name, p in patterns if p.search(sym)]
        matches[i] = matches[sym]
        for name in matches[i]:
            if not on_activity[name]: shares[name] += under[i]
            on_activity[name] += 1
        if not on_symbol[sym]: by_symbol[sym] += under[i]
        on_symbol[sym] += 1
        stack.append(i)
    print('%s: %d samples, %d busy, %d in disk syncs (%.0f%% of busy)' % (path, total, busy, io_wait, 100 * io_wait / max(busy, 1)))
    print()
    print('| activity | busy samples | share of busy |')
    print('|---|---|---|')
    for name, _ in ACTIVITIES:
        print('| %s | %d | %.1f%% |' % (name, shares[name], 100 * shares[name] / max(busy, 1)))
    if top:
        print()
        print('| frame | busy samples under it | share |')
        print('|---|---|---|')
        for sym, count in by_symbol.most_common(top):
            print('| %s | %d | %.1f%% |' % (sym[:140].replace('|', '/'), count, 100 * count / max(busy, 1)))

main()
