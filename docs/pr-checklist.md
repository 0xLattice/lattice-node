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

- [ ] No hashed byte and no consensus decision changes.
- [ ] Weight does not wait on execution, and availability gates no other chain.
- [ ] Nothing crosses between chains except work facts and continuity facts.
- [ ] Work of a new kind runs in its own lane; nothing reorders another lane's work.
- [ ] A new wait has a typed reason and a wake, not only a timer.
- [ ] A decision is made in the core; the shell only executes effects.
- [ ] A liveness rule has a simulator scenario; a performance claim has a benchmark number.
- [ ] Nothing new waits on disk except a promise to the operator.
- [ ] Content is verified once, and modules pass verified values.
- [ ] A wire change is an addition behind a capability, and older peers are still served.
