# Architecture-sensitive review template

Use this section in future consensus, evidence, storage, authority, or recovery PRs:

```text
Architectural laws affected:
Stable invariants affected:
Behavior deliberately changed:
Behavior required to remain equivalent:
Independent oracle:
Crash boundaries:
Fault injection:
Parent/child independence impact:
Ingress equivalence impact:
Schema and wire migration:
Rollback plan:
```

A green happy-path suite is not sufficient evidence when a change crosses availability, validity, canonicity, durability, authority, or evidence boundaries.
