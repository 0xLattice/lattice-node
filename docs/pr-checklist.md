# Node semantics review checklist

- [ ] Lattice outcomes remain distinct at the node boundary.
- [ ] Only canonicalization publishes a new canonical tip.
- [ ] Valid side import is retained and not labeled invalid.
- [ ] Unavailable inputs are retriable and non-punitive.
- [ ] Local durability failures are non-punitive.
- [ ] All ingress transports use the same mapping.
- [ ] Dependency branch pins are replaced by released versions before merge.

## Architecture rules

For a change to sync, storage or the wire, against
[sync architecture](design/sync-architecture.md):

- [ ] It satisfies rules 1–15 there, or changes the rule there first.
- [ ] No hashed byte and no consensus decision changes.
- [ ] Weight does not wait on execution, and availability gates no other chain.
- [ ] Nothing crosses between chains except work facts and continuity facts.
- [ ] Work of a new kind runs in its own lane, and chains do not share an execution queue; nothing reorders another lane's work.
- [ ] A new wait has a typed reason and a wake, not only a timer.
- [ ] A decision is made in the core; the shell only executes effects.
- [ ] A liveness rule has a simulator scenario; a performance claim has a benchmark number.
- [ ] Writes are made as each step ends, in one order from one place: the content a step's facts name, then the facts in one transaction. Nothing is written behind the loop, and no caller orders writes across stores.
- [ ] Content is verified once, and modules pass verified values.
- [ ] A wire change is an addition behind a capability, and older peers are still served.
