# Transaction pool policy

What a node's transaction pool (mempool) admits, replaces, evicts and keeps
across a restart. The pool is local policy, never consensus authority: two
honest nodes may hold different pools. Each hosted chain has its own pool,
and co-hosted parent and child levels never merge theirs.

Refusal codes and fee pricing are in [Reads and transactions](api-reads-and-transactions.md#submitting-a-transaction). How
transactions travel between peers is in the
[peer protocol](protocol.md#transaction-announcements).

## Admission

1. A submitted or announced transaction arrives as a concrete body with its
   signatures. A cashew header alone is not a complete transaction payload.
2. The node binds the body back to its CID.
3. Lattice validates the transaction for its signed absolute chain path,
   which this node must host, against the executed tip.

The pool holds only transactions Lattice finds ready on the executed tip,
funds checked. A nonce ahead of the chain, or evidence this node lacks, is a
retriable refusal; such a transaction is never held.

Signature form, reward payment and the other validity rules are consensus:
see the specification's
[transaction validation](https://github.com/0xLattice/Lattice/blob/59.3.1/docs/spec.md#7-transaction-validation).

## Pool rules

| Rule | Meaning |
|---|---|
| Claimed once | A first signer's nonce, each state key written, each deposit and each receipt belong to one pooled transaction. |
| Budgeted | An account's debits across the pool never exceed its balance on the tip, so every pooled transaction executes alongside every other. |
| Conflicts go to what pays the miner more | A newcomer displaces what it conflicts with, by claim or by an account's budget, when the next block, filled in fee-rate order, then carries it and pays the relay floor (at least 1) more. |
| No time-based expiry | Capacity evicts the lowest fee rate. |

A fee rate is fee per weight: the most of a block a transaction takes of its
bytes, state growth or count, in bytes.

### Replacement

- In an uncongested pool, a newcomer must pay all the fees of what it
  displaces plus the relay floor.
- In a congested pool, what it displaces may sit anywhere in the pool and
  its own fee does not count, only the next block's. A node with a different
  backlog may judge the same replacement differently.

## When the tip moves

- Every tip move re-checks each pooled transaction's nonce, funds and
  evidence. One no longer ready leaves.
- Transactions confirmed on the new chain leave the pool.
- Ordinary transactions from removed blocks are reinserted when still
  valid.

## Policies and templates

Policies are judged at admission and by templates. A template is handed
only what the next block can carry: fee order, skipping what does not fit
its bytes, count or state growth, each charged its growth at most. What a
template's policies refuse leaves the pool.

## Across a restart

- Locally submitted transaction roots survive a restart and are revalidated
  before becoming visible again.
- Live pool roots are pinned under a process-owner VolumeBroker scope and
  unpinned on removal. Startup clears that owner before restoring only the
  durable local submissions.
- Peer transactions are therefore serveable while pooled but never become
  restart authority.

## Invariants

The pool's checked invariants are NODE-MEMPOOL-001 in
[Correctness invariants](correctness-invariants.md).
