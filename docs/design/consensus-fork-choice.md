# Consensus and fork-choice ownership

Consensus is defined by Lattice, not by `lattice-node`. The canonical rules are
the [protocol specification](https://github.com/adalinxx/Lattice/blob/27.0.0/docs/spec.md)
and [work and fork-choice rationale](https://github.com/adalinxx/Lattice/blob/27.0.0/docs/consensus-fork-choice.md).

The node owns only the operational boundary around those rules:

- authenticate immediate-parent and direct-child processes;
- acquire the exact sparse evidence Lattice requests;
- persist accepted fact batches before exposing their effects;
- retain and replay the same immutable facts after restart;
- derive each unique grind's work from its content-addressed child proof; and
- project the one canonical chain delta returned by Lattice.

Work observations are joined by grind identity before they are totaled. One
root contributes at most its strongest target-derived quantity to one
chain-local location; different roots sum. The contribution affects GHOST only
after its terminal child is accepted and connected. Parent admission,
canonicity, and later ancestry do not create or remove that physical work.
Exact work ties use Lattice's deterministic segment-base CID rule, never
arrival order or an incumbent preference.

The node must not implement a second fork-choice metric, accept peer-supplied
work totals, recursively choose descendant tips, or send parent canonical-tip
commands across the hierarchy plane.

## Sync trust boundary

Cold sync pays two independent costs, and only one is cheap:

- **Fork choice** (which tip is heaviest) depends only on work facts and DAG
  shape. Work facts are self-verifying from content-addressed bytes and
  deduplicated per root-CID grind (`ConsensusBlockInput`/`submitBlock` need only
  the block header and its *claimed* state CIDs — never the materialized state).
  Cumulative PoW is *objective*, so a fresh node determines the heaviest tip with
  **no weak-subjectivity checkpoint** — the property a PoW chain has and a PoS
  chain cannot. Bitcoin-anchoring the golden genesis fixes *which* genesis
  out-of-band, which is the one thing raw PoW can't self-anchor. Together they
  give a trustless, checkpoint-free fork-choice start.

- **State validity** (that `postStateCID == STF(prevState, txs)`) is *not*
  attested by work — a heavier chain can commit a wrong post-state, and content
  addressing proves only that the producer *committed* those bytes, never that
  the transition was *honest*. So canonical state is **re-executed from genesis
  by design**. There is no `assumevalid`: the only trustless anchor a fresh node
  possesses is genesis (segment-anchored catch-up trusts a node's *own*
  last-validated context, which a fresh node lacks). This is the trust model, not
  a missing optimization — and it is why "why can't we just assumevalid?" has no
  trustless answer short of succinct validity proofs (a consensus change).

Content addressing does bound the *working set*, not just integrity: canonical
re-execution fetches sparse state slices verified against each block's
`prevStateCID`, so it never materializes the full historical state — strictly
cheaper than an account-trie chain, though CPU over canonical transactions stays
inherent. The one consensus-neutral lever that remains is skipping execution of
**abandoned** forks (place side-fork blocks in the DAG on the cheap work path;
execute state only on canonical membership); its delicate requirement is that a
heaviest-but-*invalid* canonical path is always demoted to the heaviest *valid*
one — the invariant any such optimization must be tested against.
