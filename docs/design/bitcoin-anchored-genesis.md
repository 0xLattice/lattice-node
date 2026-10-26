# Bitcoin-anchored genesis

The Nexus genesis is pinned in source as `NexusGenesis.expectedBlockHash`
(`bafyreiggtg4ezifboyekbf4gxst2jr3mpjqcxsbmopy7w6fp46g4ngpgxa`), and a node verifies
that the genesis it builds matches that value at boot. On its own the pin is a
*trusted constant*: the one link in the security model that proof-of-work does not
cover. Anyone could publish a different "golden" genesis, and nothing in the protocol
says which one is the real network.

To remove that trust, the genesis CID is committed to **Bitcoin**. It is the
`OP_RETURN` payload of a confirmed Bitcoin transaction, so the claim "this CID is the
Nexus genesis, and it existed by this time" rests on Bitcoin proof-of-work and can be
checked without trusting this repository.

## The anchor

| | |
|---|---|
| Bitcoin block | 970053 — `000000000000000000005260ddc48a2e8421fff7cb681ca999db1b65d119fdfc` |
| Transaction | `7501f77602b581f605e6bc61c310b540e17324d3cc292c18985d8a3464d23236` |
| `OP_RETURN` payload | `01711220c699b84ca0a17608a09786bca7a4c76c7a602bc82c73f1fb78afe78dc699e6b8` |

The payload is the genesis CID's raw bytes (`01` = CIDv1, `71` = dag-cbor,
`12 20` = sha2-256, then the 32-byte digest). It decodes to
`NexusGenesis.expectedBlockHash`. The same facts are recorded in code in
`BitcoinGenesisAnchor`, next to the genesis they commit.

Two earlier Bitcoin transactions, in blocks 954137 and 960894, commit earlier Nexus
genesis values that were replaced before this one. They are not this network.

## The genesis is fixed

The committed CID is derived from the genesis spec, the premine owner, and the
genesis timestamp. Changing any of them changes the CID and leaves this anchor
pointing at nothing, so those parameters are fixed. There is no procedure for
re-pinning the genesis.

## Verifying the anchor

**Trust nothing in this repository.** The recorded txid, the constants in
`BitcoinGenesisAnchor`, and any test are all controlled by whoever ships the source,
which is exactly the party this anchor is meant to check. A forged genesis would
arrive with matching forged constants and green tests.

The verification happens outside this repo, against the live Bitcoin chain:

1. **Fetch the transaction independently** by its txid from your own Bitcoin node,
   or cross-check several independent block explorers. Confirm it is mined in block
   970053 and that the block is buried under substantial later proof-of-work.
2. **Decode its `OP_RETURN` output** and confirm the pushed bytes are exactly
   `01711220c699…e6b8`, i.e. the CID
   `bafyreiggtg4ezifboyekbf4gxst2jr3mpjqcxsbmopy7w6fp46g4ngpgxa`.
3. **Confirm that CID is the genesis you run**: `nexusGenesisCID` from the node's
   `/health`, which the node derives from the genesis spec at boot.

For full rigor without trusting an explorer's "confirmed" flag, work from raw data
you fetch yourself: check that the 80-byte block header meets Bitcoin proof-of-work
and hashes to the block hash, that the transaction Merkle-proves into the header's
merkle root, and that the header extends the Bitcoin chain you already trust.
