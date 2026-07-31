# External mining workers

The coordinator (`lattice-mining-coordinator`) owns templates, staleness, and
submission. A worker is a dumb nonce searcher: it receives one immutable
assignment as CLI flags, prints exactly one JSON result to stdout, and exits.
Anything that honors this contract can mine — the shipped CPU worker
(`lattice-miner`), a GPU binary, or a shim in front of remote hardware.

## Invocation

The coordinator spawns the `--worker-executable` per batch with:

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

## Reference vector

Validate any implementation against this before mining (from
`MiningWorkerContractTests`, derived from the canonical Nexus genesis block):

- preimage prefix begins
  `310000626166797265696736747066673369653766796c6132327279346d…`
- `SHA256(prefix || be64(12345))` =
  `20f5f3cd686a1287bf49fab897b39f560387282e60f2c982006b68a660137762`

Run your worker with the Nexus genesis prefix, `--target` set to that hash,
`--start-nonce 12345 --count 1`: it must report `found` at nonce `12345` with
exactly that hash. A worker that cannot reproduce the vector will mine
garbage that every node rejects.
