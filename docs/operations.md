# Operations

## Process model

Operate each chain as an independent service. Every invocation needs one
absolute Nexus-inclusive `--chain-path`; a non-Nexus process additionally needs
the authenticated immediate parent supplied by `--parent`.

```bash
lattice-node \
  --chain-path Nexus \
  --data-directory /var/lib/lattice/chains/Nexus \
  --identity-key /var/lib/lattice/identity/nexus.key \
  --listen-port 4001 \
  --fact-listen-port 4002 \
  --rpc-port 8080 \
  --minimum-peer-key-bits 0 \
  --peer <public-key>@<host>:4001
```

RPC must remain on loopback. The same-chain overlay port may be public. Expose
the hierarchy fact port only where configured direct parents and children need
it.

## Health

```bash
curl --fail http://127.0.0.1:8080/health
```

Important fields:

- `phase`: `active`, `awaitingGenesis` for an unbootstrapped child, or
  no tip-dependent intermediate phase.
- `chainPath`: the complete path owned by this process.
- `nexusGenesisCID`: must be
  `bafyreiayw4z5qz4lt2sljf2enzn7uol3qa6bebadav7qwnqz7agxkiuwhq`.
- `tipCID` and `height`: null only while a child awaits genesis.
- `revision`: the local consensus mutation watermark.
- `mempoolCount`, `mempoolBytes`, and `pendingChildIntents`: bounded service
  pressure indicators.

## External mining services

Run one or more coordinators against a Nexus process. Each coordinator allocates
non-overlapping ranges to external `lattice-miner` workers and submits results
back to the node.

```bash
lattice-mining-coordinator \
  --node http://127.0.0.1:8080 \
  --worker-executable /usr/local/bin/lattice-miner \
  --workers 4
```

Custom workers (GPU or remote hardware) implement the contract in
[mining-workers.md](mining-workers.md) and slot in via `--worker-executable`.

If block production stalls:

1. Confirm the Nexus node is `active`.
2. Confirm the coordinator can reach the loopback HTTP endpoint.
3. Check coordinator logs for template rejection, expired work, or worker
   failure.
4. Check the worker executable path and permissions.
5. Confirm the submitted work satisfies at least one assembled chain target.

Do not daemonize the coordinator behind `nohup`+shell backgrounding on Linux:
a shell that forks with `SIGCHLD` blocked wedges Foundation's child reaping —
the coordinator hangs after one batch with zombie workers and an empty log.
Use a supervisor that spawns it with a clean signal mask (systemd, or the
reference [deploy/mine-supervisor.py](../deploy/mine-supervisor.py)).

## Mining rewards

Without a rewards file the coordinator requests empty rewards and mined blocks
pay nobody. Rewards are ordinary signed transactions validated by consensus:
credit-only account actions, fee 0, total claimed at most the spec reward at
the mined height, and the signer's nonces strictly sequential — so one signed
reward transaction is valid in exactly one block, in nonce order. Unsigned
credits exist only in genesis.

`lattice-rewards` keeps the reward key off the mining host:

```bash
lattice-rewards generate-key --out reward-key.json
lattice-rewards emit-batch \
  --key reward-key.json \
  --count 10000 \
  --out reward-batch.jsonl
```

Ship only `reward-batch.jsonl` to the miner. Each line is one complete
`--rewards-file` payload; feed line `i`, and advance to `i + 1` only after the
block paying it is accepted. A spent nonce is refused at template build
(HTTP 400 `invalidRewardTransaction`) — a supervisor's signal that the cursor
is behind, never a reason to skip ahead on other failures: a skipped nonce
permanently invalidates every later line. The reference
[deploy/mine-supervisor.py](../deploy/mine-supervisor.py) implements this
loop. Re-emit the batch before it is exhausted, and before a halving boundary
makes its amount exceed the allowed reward. Cursor advancement reflects the
current tip: a deep reorg that reverts a paid reward strands the tail of the
batch on a nonce gap — recover by re-emitting from the key's next expected
nonce.

## Child chains

Start a child process before or after preparing its parent intent. It can safely
remain in `awaitingGenesis` until the parent carrier is accepted.

```bash
lattice-node \
  --chain-path Nexus/Payments \
  --parent <nexus-key>@10.0.0.10:4002 \
  --data-directory /var/lib/lattice/chains/Nexus/Payments \
  --identity-key /var/lib/lattice/identity/payments.key \
  --listen-port 4101 \
  --fact-listen-port 4102 \
  --rpc-port 8180
```

The parent endpoint is a live verdict boundary, not merely a bootstrap hint.
Back up the configured parent key and child process identity as operational
secrets. Losing the live parent does not revoke already admitted history or
fork choice, but new child admissions that change parent state wait until the
authenticated immediate parent can acknowledge the exact continuity or genesis
query. Same-chain peers may restore the required Volumes; they cannot relay the
parent's unsigned session-bound answer.

For application testing, deploy a normal child with test-oriented parameters.
Nexus retains its one pinned genesis.

## Storage and backups

One process directory contains both halves of durable state:

```text
<storage>/
  process.key   # unless --identity-key points elsewhere
  state.db
  volumes.db
```

Take `state.db` and `volumes.db` from the same stopped process. Copying or
restoring only one can leave retained-root metadata inconsistent with
materialized content.

For easier destructive recovery, keep long-lived identity keys outside the
chain storage directories and pass their paths explicitly.

## Required migration wipe

Legacy stores are intentionally incompatible with this architecture. Migration
is a whole-directory reset; there is no partial state rebuild and no supported
way to preserve legacy CAS volumes.

```bash
systemctl stop lattice-miner lattice-node

# Optional: preserve an identity only when it lives inside the directory.
install -m 600 /var/lib/lattice/chains/Nexus/process.key \
  /var/lib/lattice/identity/nexus.key

# Remove state.db, volumes.db, and every legacy artifact together.
rm -rf /var/lib/lattice/chains/Nexus

systemctl start lattice-node lattice-miner
```

An empty Nexus directory recreates the exact pinned genesis automatically. An
empty child directory returns to `awaitingGenesis` and must reacquire its
authenticated genesis link from its configured parent.

Before running a recursive removal, resolve and verify the explicit path. Never
target a home directory, workspace root, or an unresolved environment variable.

## Common failures

### `invalidNexusGenesis`

The recovered height-zero fact or store metadata does not match the pinned
Nexus CID. Stop the process and perform the whole-directory wipe above. Do not
try to replace only the genesis row or retain `volumes.db`.

### `missingMaterializedVolume`

`state.db` references a retained volume absent from `volumes.db`. Restore a
matched backup pair or wipe the entire process directory and resync.

### Child remains `awaitingGenesis`

- Verify its `--chain-path` is absolute and exactly matches the intended child.
- Verify `--parent` names the immediate parent's process key and fact port.
- Confirm the parent intent was followed by a separately signed parent
  `GenesisAction` transaction.
- Confirm the coordinator was run with `--deployment`; normal templates never
  include genesis actions.
- Confirm a parent carrier containing the matching child genesis was accepted.
- Check hierarchy-plane connectivity; an overlay peer cannot substitute for the
  configured parent fact link.

### No peers

- Check each `--peer` key, host, and overlay port.
- If `--minimum-peer-key-bits` is nonzero, confirm every required peer identity
  deliberately satisfies it. Generated process keys are accepted by the default
  value `0`.
- Confirm both peers advertise the same Nexus genesis CID and absolute chain
  path.

## Security

- Keep process private keys mode `0600`; startup rejects broader permissions.
- Keep RPC loopback-only. Authenticate any proxy that exposes it beyond the
  host.
- Treat `--parent` as a pinned live-verdict configuration.
- Firewall the hierarchy plane to intended parent/child hosts where possible.
- Use distinct storage and identity paths per chain process.
