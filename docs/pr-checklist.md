# Node semantics review checklist

- [ ] Lattice outcomes remain distinct at the node boundary.
- [ ] Only canonicalization publishes a new canonical tip.
- [ ] Valid side admission is retained and not labeled invalid.
- [ ] Unavailable inputs are retriable and non-punitive.
- [ ] Local durability failures are non-punitive.
- [ ] All ingress transports use the same mapping.
- [ ] Dependency branch pins are replaced by released versions before merge.
