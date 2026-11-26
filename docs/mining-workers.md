# External mining workers

The miner ([lattice-miner](https://github.com/0xLattice/lattice-miner)) owns
templates, staleness, and submission. A worker is a dumb nonce searcher: it
receives one immutable assignment as CLI flags, prints exactly one JSON result
to stdout, and exits. Anything that honors this contract can mine —
lattice-miner's `lattice-miner-gpu` (CPU, Metal, CUDA, OpenCL), another GPU
binary, or a shim in front of remote hardware.

## Invocation

The miner spawns the worker its settings name (`worker` in `miner.json`) per
batch with:

```
--work-id <opaque id>
--block-hex <hex of the serialized nonce-0 Block>
--target <hex UInt256>
--start-nonce <first nonce>
--count <nonces to search>
--prefix-hex <hex of the consensus PoW preimage prefix>
```

`--prefix-hex` is the preferred input: a worker needs no block parser, only
SHA-256. `--block-hex` remains for workers that want the full block. Workers
must accept (or ignore) both.

## The search

A nonce wins when:

```
SHA256(prefix || nonce_be64) <= target
```

- `prefix` is Lattice's `Block.makeProofOfWorkPreimagePrefix` — every
  consensus field before the nonce, each terminated by a `0x00` separator.
  Never re-derive it; take `--prefix-hex` as given.
- `nonce_be64` is the nonce as exactly 8 big-endian bytes. The preimage
  length is therefore constant across attempts: hash the prefix once into a
  midstate and append only the nonce per attempt.
- The digest and `target` compare as 256-bit big-endian integers;
  equality wins.

## Result

One JSON object on stdout:

```json
{"workId":"…","status":"found","nonce":12345,"hash":"…64 hex…",
 "rangeStart":0,"rangeCount":1000000}
```

`status` is `found` or `exhausted` (`nonce`/`hash` null when exhausted).
Exit 0 in both cases; any other exit or malformed stdout is a worker failure
and the batch is retried.

## Merged work

One template can clear several chains' targets: the Nexus root and every
hosted chain it carries, at any depth. The template's `searchTarget` is the
easiest of them; `targets` lists all of them when the node built every carried
subtree itself, and only `searchTarget` otherwise. The miner first
searches the easiest. A hit that clears only some of them is `childOnly`: the
miner submits it, the node keeps the work open, and the miner
invokes the worker again over the rest of its range (`--start-nonce` just past
the hit) with `--target` set to the easiest target still uncleared. That
repeats until the hardest target is hit, the range is exhausted, or the work
goes stale (the Nexus tip moved).

Each invocation is still one immutable prefix, target, and range, but merged
work adds two requirements:

- A `found` result must report the **lowest** winning nonce in the assigned
  range. The miner resumes just past the reported nonce, so a worker that
  reports a higher winner silently skips the nonces below it for the harder
  targets.
- A worker must not assume one invocation per assigned range, or one target per
  `--work-id`.

A template request's `exclude` (see `rpc-api.md`) leaves named chains out of
the work: they get no block from any nonce, and their targets set neither
`searchTarget` nor `targets`. Use it, not `minimumWork`, to keep a chain that
is not due from advancing: a filter on a chain the work still carries stops the
whole search at that filter, since any hash for another chain could make the
declined block. Excluding a chain never holds back its ancestors: a block
for a due chain is carried by one on each ancestor, and the same hash makes
any ancestor whose target is easier advance. A node that predates `exclude`
ignores it; check the response's `chains`, and treat its absence as no
support.

## Reference vector

Validate any implementation against this before mining (from
`MiningWorkerContractTests`, derived from the canonical Nexus genesis block):

- preimage prefix begins
  `31000062616679726569663765766172756b6d7a7074636576657865686c…`
- `SHA256(prefix || be64(12345))` =
  `0179e03e9b0545582bb0aba1729d83b611b16e49abcefe44d6c1d35e85c4b3a3`

Run your worker with the Nexus genesis prefix, `--target` set to that hash,
`--start-nonce 12345 --count 1`: it must report `found` at nonce `12345` with
exactly that hash. A worker that cannot reproduce the vector will mine
garbage that every node rejects.
