# Chain addressing

## Rule

A chain's public and internal identity is one absolute path from the single
Nexus root. Every chain path includes `Nexus` as its first component.

```text
Nexus
Nexus/Payments
Nexus/Payments/Rollups
```

`Payments` and `Payments/Rollups` are invalid even when sent to a host that
serves Nexus. The `Nexus` component is never implicit. This keeps topology,
transaction replay protection, wire routing, storage scopes, metrics, and API
payloads on one representation.

## Directory versus chain path

A `directory` is a single edge label chosen under an already known parent. It
is intentionally parent-relative:

```text
parent path:     Nexus/Games
child directory: Payments
child path:      Nexus/Games/Payments
```

The same directory may exist under another parent, so `Payments` is never a
globally unique chain identity.

| Term | Meaning |
|---|---|
| Nexus | The single root and first component of every path |
| Chain path | Complete absolute route beginning with `Nexus` |
| Chain address | Validated internal representation of a chain path |
| Directory | One direct parent-to-child edge label |

## Validation

`ChainAddress` accepts a component array or slash-separated string only when:

1. the first and exact root component is `Nexus`;
2. its child depth fits Lattice's child-proof bound;
3. every component is 1–64 bytes of visible ASCII; and
4. no component contains Lattice's directory separator.

`ChainAddress` delegates this grammar to `ChainRuntimeContext`, so node setup,
transactions, state keys, and child proofs cannot drift. Process configuration
also requires the complete canonical handshake to fit its wire frame.

Consequently, these are invalid:

```text
Payments
/Nexus/Payments
Nexus/
Nexus//Payments
nexus/Payments
```

## Where paths are load-bearing

- `lattice.json.hostedChains` lists the child paths one process serves, parent
  first; Nexus is implicit as the root.
- `TransactionBody.chainPath` is signed replay protection and must name a path
  hosted by the receiving process.
- The handshake pins Nexus and the protocol revision; routed sync frames carry
  their level's full path on the one shared overlay.
- Mining reward routing uses full paths so each reward reaches one exact chain.
- Direct-child lookup uses the final directory only after the co-hosted parent
  relationship is established by the topology.
- Durable facts and cursors are keyed by full path, preventing leaf-name
  collisions inside the shared store.

## Nexus root bootstrap

Nexus has no parent, so an empty store constructs the one pinned unsigned
genesis locally before configured root bootstrap. It is never accepted from a
peer. The path representation is not special-cased; Nexus is simply the valid
one-component absolute path `["Nexus"]`.
