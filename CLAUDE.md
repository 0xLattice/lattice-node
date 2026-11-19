# Working on lattice-node

## Design gate: new machinery waits for a yes

Before adding any of these, stop and ask the owner first. Write no code for
it until they say yes:

- a buffer, cache or in-memory overlay of something the node also stores;
- a background writer, queue, lane, or anything that runs work behind the
  decision loop;
- a lock, mutex or shared mutable value read across tasks;
- a second write path for something that already has one;
- any rule that one write must reach disk before another, across two stores
  (`state.db` and `volumes.db`) or across two transactions.

The question to the owner names, in a few lines:

1. **The conventional equivalent, by shape.** Which established client does
   this (Bitcoin Core, geth), in which function, writing what, in what
   order, under which atomic boundary. "As Bitcoin does" counts only if the
   whole shape matches: who writes, when, in what order, inside one
   boundary. The same idea assembled differently is invention.
2. **What it is for, measured.** The gain on the sync benchmark on Linux,
   against the goal it serves, and whether that goal is already met.
3. **What it costs.** Lines added and removed, and every new ordering rule
   or invariant a caller must now keep.

If no established client has the same shape, say so plainly in the
question.

## Persistence keeps one boundary

Writes follow one order, from one place: block content first, then state,
facts and each chain's "state reflects block X" marker together. No caller
orders writes by hand. A change that needs a caller to remember to flush,
sync or wait before something else is the wrong shape; bring it to the
owner instead.

## Stop signals

- **A second review round finds a new hole of the same kind** (ordering
  between stores, a read racing a write, a release running late). Stop
  patching. Bring the design question to the owner, not a third fix.
- **The goal is met.** Performance work stops when the stated goal is met
  on Linux, unless the owner sets a new one.
- **A fix adds machinery to fix machinery.** If the fix for a component's
  problem is another component, stop and ask.

## Reviews

Every change to sync, storage or concurrency gets two independent reviews:

- **Correctness:** is it right?
- **Simplicity:** what machinery does it add, does it match an established
  client's shape, and is the codebase simpler after it? A simplicity
  finding blocks the merge like a bug does.

Give reviewers the diff and the question, never your own conclusions.

## Report without being asked

After every few merged changes, tell the owner:

- net lines added and removed in `Sources/`;
- how many review rounds each change took and what kinds of holes they found;
- for each new component, its conventional equivalent, or that it has none.

## Also

- [Sync architecture](docs/design/sync-architecture.md) and the
  [PR checklist](docs/pr-checklist.md) apply. Where they conflict with this
  file, this file wins until they are amended.
- Tests state what an operator or a peer could observe
  ([testing](docs/testing.md)).
