# Running in production

How to run a node as a service: what to check first, how to supervise it,
how to upgrade it, and what to watch.

One `lattice-node` process hosts the whole tree: Nexus and every child chain
in `hostedChains`. It has one identity key, one overlay port, one operator
API and one data directory. The miner is a separate process
([Mining](mining.md)).

## Before you expose a node

1. Install all four binaries from one
   [verified release](release-verification.md).
2. Create the root with `lattice init`.
3. Protect `identity/Nexus.key` as mode `0600` and back it up separately.
4. Leave `peers` unset to use the built-in seeds, or list at least two
   independent peers of your own.
5. Set `externalAddress` when the address peers observe is not dialable.
6. Keep the operator API on loopback. Serve the public from `publicRead`, or
   a proxy that allows no more than it does
   ([Networking](networking.md#public-reads)).
7. Give the miner a recipient for every chain that should pay rewards.
8. Reserve disk for history that grows without bound, or set `blockBodies`
   and `state` ([Storage](storage.md#what-a-node-keeps)).
9. Allow enough open files and memory (below).
10. Test a clean stop, a restart and a restore before accepting traffic.

### Open files and memory

Each hosted chain's Volume store holds about thirteen open files, beside the
overlay's sockets. The node raises its own soft limit to the hard limit at
start and logs the result as `open files allowed`. Only a hard limit set low
by the host bounds the chains a node can host; the systemd units set
`LimitNOFILE=65536`.

Each Volume store keeps up to 64 MiB of write cache and 16 MiB of read cache
in memory, filled as its chain is used.

## Process managers

The node runs in the foreground and does not restart itself. A process
manager starts it again after a failure.

```bash
lattice up --root /var/lib/lattice        # runs the node in the foreground
lattice status --root /var/lib/lattice    # from another shell
lattice down --root /var/lib/lattice
```

The node logs to standard error, which the manager keeps (`journalctl`,
`docker logs`, `fly logs`). `lattice logs` reads the running node's last
lines from its memory. It writes no log file and no pidfile.

### Exit codes

| Exit | Meaning | The manager should |
|---|---|---|
| 0 | Asked to stop: `lattice down`, SIGTERM or SIGINT. | Leave it stopped. |
| 75 | Asked to restart: `lattice restart`, `lattice wipe`. | Start it again. |
| 78 | The configuration does not check. The reason is on standard error. | Leave it stopped until fixed. Only systemd can; launchd and Docker retry it. |
| 64 | A command-line error: an unknown flag or a bad value. | It starts it again; fix the unit. |
| other | A failure. | Start it again. |

Give an orderly stop 60 to 90 seconds.

### systemd

```bash
lattice emit-systemd --root /var/lib/lattice
```

prints two units: `lattice-tree.service`, and `lattice-mine.service` when the
root holds miner settings. Save each as its own file under
`/etc/systemd/system/`, then:

```bash
systemctl daemon-reload
systemctl enable --now lattice-tree lattice-mine
```

- The node's unit runs `lattice up --root <root>` with `Restart=on-failure`,
  `RestartPreventExitStatus=78` and `TimeoutStopSec=90`.
- `systemctl reload lattice-tree` re-reads the configuration (`SIGHUP`).
- Its log is the journal: `journalctl -u lattice-tree`.
- The miner's unit wants the node's rather than binding to it, so a node
  restart leaves the miner running.

The repository also carries ready-made units, described in
[Deployment](../deploy/README.md).

### launchd

A job for the current user on macOS:

```bash
lattice emit-launchd --root ~/lattice > ~/Library/LaunchAgents/build.lattice.node.plist
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/build.lattice.node.plist
```

It restarts the node on any exit but 0, at launchd's 10-second throttle. A
bad configuration (78) is therefore retried until fixed. Output goes to
`<root>/log/lattice-node.log`, which launchd does not rotate: truncate it
now and then, or add a `newsyslog.d` entry.

### Containers

Run `lattice up --root <root>` as the main process with
`docker run --restart on-failure` (Compose `restart: on-failure`). Docker
retries a bad configuration (78) at its throttle until it is fixed.

### Fly

Set `[[restart]] policy = "on-failure"` and a `kill_timeout` of 60 s or more
in `fly.toml`.

Fly counts every exit but 0 toward the Machine's restart limit
(`max_retries`, 10 by default), after which it leaves the Machine stopped. A
requested restart (75) must not spend that limit, so start the node again on
75 in the entrypoint:

```sh
while :; do
  lattice up --root /data
  status=$?
  [ "$status" -eq 75 ] || exit "$status"
done
```

Do the same in any shell entrypoint that starts sidecars beside the node.

## Health

```bash
curl -s http://127.0.0.1:8080/health | jq
curl -s 'http://127.0.0.1:8080/health?chainPath=Nexus%2FAlpha' | jq
```

`/health` returns, for the selected chain:

- `phase`: `active` when the chain has an executed tip, `awaitingGenesis`
  for a hosted child with no genesis yet
  ([Child chains](child-chains.md#a-chain-stuck-at-awaitinggenesis));
- `tipCID` and `height`;
- the Nexus genesis CID and the chain's path.

An unknown or unhosted chain path is 404, not an error in the node.

Every other operator route needs the node's cookie
([HTTP API](rpc-api.md#authentication)):

```bash
curl -s --user "$(cat <root>/chains/Nexus/.cookie)" http://127.0.0.1:8080/status | jq
curl -s --user "$(cat <root>/chains/Nexus/.cookie)" http://127.0.0.1:8080/metrics
```

## Metrics

`/metrics` is Prometheus text, on the operator API only.

Per hosted chain (label `chain`):

| Metric | Meaning |
|---|---|
| `lattice_chain_tip_height{tier="validated"\|"weighed"}` | The executed tip, and the best header. |
| `lattice_chain_tip_advanced_timestamp_seconds` | When the executed tip last moved. |
| `lattice_chain_blocked_on{on=...}` | What the tip waits on: one series per reason, 1 for the current one and 0 for the rest. The same value as `sync.blockedOn` in `/status`. |
| `lattice_chain_synced`, `lattice_chain_headers_synced` | Whether the chain has caught up. |
| `lattice_chain_jobs_queued` | Jobs waiting for a worker. |

Node-wide: `lattice_overlay_peers`, `lattice_mempool_transactions` and
`process_start_time_seconds`.

For mining, under Nexus's `chain` label:

| Metric | Meaning |
|---|---|
| `lattice_template_build_seconds{outcome=...}` | Time to answer a template request, by outcome: `ok`, or the refusal (`busy`, `executing`, `buildFailed`). |
| `lattice_work_submission_seconds{outcome=...}` | Time to answer a work submission, by outcome: `canonicalized`, `acceptedSide`, `childOnly`, `duplicate`, `invalid`, a refusal (`unknownWork`, `missesSearchTarget`), or `error`. |
| `lattice_work_submissions_stale_total` | Submissions that met their target after the tip had moved, so the block can only be a side block. |

An outcome's series appears once it has been seen.

Two queries worth keeping:

```text
# 99th percentile template build time
histogram_quantile(0.99, rate(lattice_template_build_seconds_bucket{outcome="ok"}[1h]))

# stale share of submitted work
rate(lattice_work_submissions_stale_total[1h])
  / sum without (outcome) (rate(lattice_work_submission_seconds_count{outcome=~"canonicalized|acceptedSide|childOnly|duplicate|invalid"}[1h]))
```

### Alerts

[`deploy/prometheus/lattice-alerts.yml`](../deploy/prometheus/lattice-alerts.yml)
has alert rules for: a chain behind and not moving, a chain stalled with no
reason, content no peer serves, a chain not caught up an hour after start,
no peers, and a restart loop. Their thresholds are starting points.

Also monitor storage growth, free space and backup age, which the host's
own exporter reports. Mining alerts are listed in
[Mining](mining.md#what-to-alert-on).

## Upgrades

Install all four binaries from the same release, then restart the node and
the miner.

Releases do not migrate stored data. When a release changes the storage
schema, the node refuses to start with `The node store is incompatible`, and the node must be
wiped and synced again:

```bash
systemctl stop lattice-mine lattice-tree
lattice wipe --root /var/lib/lattice    # keeps identity, configuration, specs and tokens
# Install all four binaries from the same release.
systemctl start lattice-tree lattice-mine
```

Nexus's genesis is recreated from the release. Child chains are synced from
their peers, or mined again from their specs.

Notes for specific upgrades:

- **Per-chain `peers`.** Releases before chains had their own peer lists
  read `peers` only as an array and refuse the keyed form. Before going back
  to one, rewrite `peers` as Nexus's array.
- **Mining settings.** An older `lattice.json` may hold a `mine` object. The
  node ignores it and drops it the next time it writes the file. While there
  is no `miner.json`, the miner copies it there once. So after such an
  upgrade, start the miner once before changing the node's configuration.
- **`blockBodies: none`.** Bodies stored by a release before this setting
  are not let go of. Sync the node again to drop them.
