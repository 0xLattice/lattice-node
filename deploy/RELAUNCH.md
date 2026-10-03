# Nexus relaunch runbook

A relaunch starts Nexus over from a new genesis on every public host: the
three backbones (`lattice-mainnet-iad`, `-ams`, `-sjc`), the read replica
(`lattice-mainnet-read`), the public follower (`lattice-mainnet-testnet`),
the Mac node, and any GPU miners. Nothing carries over except identity keys.

Run every command from a clean checkout at the relaunch commit of
`adalinxx/main`. Use absolute paths in commands; do not rely on shell
variables carried between steps.

## 1. Pin the genesis timestamp

The genesis timestamp is the chain's real launch time in Unix milliseconds.
It is the only lower bound on block 1's timestamp, and block 1 anchors the
ASERT schedule, so set it at deploy time and not earlier. If the launch slips
by more than a few hours after this step, run it again:

```bash
scripts/set-nexus-genesis-timestamp.sh now
```

The script writes the timestamp into
`Sources/LatticeNode/Configuration/NexusGenesis.swift`, recomputes the
genesis CID and the mining-worker reference vector, replaces both everywhere
they are pinned (code, `docs/protocol.md`, `docs/rpc-api.md`,
`docs/mining-workers.md`, the READMEs, the smoke script, test fixtures), and
re-runs the two pinning tests. Commit the result, open a PR, and merge it
once CI is green. Record the new genesis CID; every later check compares
against it.

## 2. Build the image and record its digest

The merge to `main` runs the Docker Build workflow, which pushes
`ghcr.io/adalinxx/lattice-node:sha-<short sha>`. Pin the digest, never the
tag:

```bash
docker buildx imagetools inspect ghcr.io/adalinxx/lattice-node:sha-<short sha>
```

The read replica and follower Dockerfiles compile the checkout they are
deployed from, so they are pinned by deploying from the same commit (step 6).

Bump the GPU miner's node pin (`lattice-miner-gpu` `Dockerfile`, both the
image tag and the `mine-supervisor.py` commit) to the relaunch commit before
any GPU host starts; an older pin runs the old genesis.

## 3. Stop every miner

Stop the Mac miner (`lattice mine stop --root ~/lattice-mac-node/nexus`) and
destroy or stop any GPU host. Nothing may mine until step 8.

## 4. Re-capture machine configs

Capture all five configs immediately before the wipe. Configs saved from an
earlier relaunch name old images and would roll machines back.

```bash
mkdir -p /tmp/relaunch
for app in lattice-mainnet-iad lattice-mainnet-ams lattice-mainnet-sjc \
           lattice-mainnet-read lattice-mainnet-testnet; do
  fly machines list -a "$app" --json > "/tmp/relaunch/$app.list.json"
  jq '.[0].config' "/tmp/relaunch/$app.list.json" > "/tmp/relaunch/$app.config.json"
  jq -r '.[0].id' "/tmp/relaunch/$app.list.json"
done
```

Confirm each backbone's current `--identity-key` is
`/data/identity/nexus.key`, the path the new command keeps; a different path
would boot the node with a fresh identity and break every pinned peer key:

```bash
for app in lattice-mainnet-iad lattice-mainnet-ams lattice-mainnet-sjc; do
  jq -r '.init.cmd | index("--identity-key") as $i | .[$i + 1]' "/tmp/relaunch/$app.config.json"
done
```

## 5. Backbones: new image, new command, wipe

The backbones run the GHCR image directly. Their command changes in this
release: `--chain-path` and `--fact-listen-port` no longer exist (the node
hosts one Nexus-rooted tree on one overlay port), so the `4002` service goes
too. Behind fly's `http` handler every public reader arrives from the proxy's
address, so the per-client read rates are disabled and the listener-wide rate
stays on.

New `cmd` for each backbone (peers are the other two backbones):

```text
lattice-node
  --data-directory /data/chains/Nexus
  --identity-key /data/identity/nexus.key
  --listen-port 4001
  --rpc-port 8080
  --public-read-port 8081
  --public-read-rate 0
  --public-read-expensive-rate 0
  --overlay-max-connections-per-netgroup 256
  --peer <other backbone>   (x2)
```

| App | `--peer` values |
|---|---|
| iad | `35edf67b…7d@lattice-mainnet-ams.fly.dev:4001`, `9cace839…4e@lattice-mainnet-sjc.fly.dev:4001` |
| ams | `139b8f36…64@lattice-mainnet-iad.fly.dev:4001`, `9cace839…4e@lattice-mainnet-sjc.fly.dev:4001` |
| sjc | `139b8f36…64@lattice-mainnet-iad.fly.dev:4001`, `35edf67b…7d@lattice-mainnet-ams.fly.dev:4001` |

Full keys are in `Sources/LatticeNode/Configuration/DefaultBootstrapPeers.swift`.

Build two configs per backbone from the captured one. The wipe config sets
the new image and command, drops the `4002` service, and wraps the real
entrypoint in a wipe; the restore config is the same without the wrapper. The
command is passed through `"$@"`, never re-quoted into the shell string.

```bash
digest='sha256:<digest from step 2>'
for app in lattice-mainnet-iad lattice-mainnet-ams lattice-mainnet-sjc; do
  case "$app" in
    lattice-mainnet-iad) peers='["35edf67bfe3d612aeb1f0e25da9d3f0ced44dbf79d34f00c548cf9005be6eb7d@lattice-mainnet-ams.fly.dev:4001","9cace839489acb30385a9f20025cb9d6365283c81dce14cadab26507065acd4e@lattice-mainnet-sjc.fly.dev:4001"]' ;;
    lattice-mainnet-ams) peers='["139b8f3639e7c515417c63bd3a652a5c6fd4a1a2d0baed8e33ea63047995fe64@lattice-mainnet-iad.fly.dev:4001","9cace839489acb30385a9f20025cb9d6365283c81dce14cadab26507065acd4e@lattice-mainnet-sjc.fly.dev:4001"]' ;;
    lattice-mainnet-sjc) peers='["139b8f3639e7c515417c63bd3a652a5c6fd4a1a2d0baed8e33ea63047995fe64@lattice-mainnet-iad.fly.dev:4001","35edf67bfe3d612aeb1f0e25da9d3f0ced44dbf79d34f00c548cf9005be6eb7d@lattice-mainnet-ams.fly.dev:4001"]' ;;
  esac
  jq --arg image "ghcr.io/adalinxx/lattice-node@$digest" --argjson peers "$peers" '
    .image = $image
    | .services |= map(select(.internal_port != 4002))
    | .init = {
        entrypoint: ["/usr/local/bin/lattice-entrypoint"],
        cmd: (["lattice-node",
               "--data-directory", "/data/chains/Nexus",
               "--identity-key", "/data/identity/nexus.key",
               "--listen-port", "4001", "--rpc-port", "8080",
               "--public-read-port", "8081",
               "--public-read-rate", "0", "--public-read-expensive-rate", "0",
               "--overlay-max-connections-per-netgroup", "256"]
              + ($peers | map("--peer", .)))
      }' "/tmp/relaunch/$app.config.json" > "/tmp/relaunch/$app.restore.json"
  jq '.init.entrypoint = ["/bin/sh", "-c",
        "rm -rf /data/chains && sleep 120 && exec \"$@\"",
        "sh", "/usr/local/bin/lattice-entrypoint"]' \
    "/tmp/relaunch/$app.restore.json" > "/tmp/relaunch/$app.wipe.json"
done
```

Apply the wipe configs to all three back to back (the operator runs these by
hand):

```bash
fly machine update <machine id> -a <app> --machine-config /tmp/relaunch/<app>.wipe.json --yes
```

The wipe removes only `/data/chains`; the identity at `/data/identity`
survives. fly-proxy auto-starts a stopped backbone on any inbound traffic,
which is why the wipe runs inside the machine's own start: whichever way it
starts, it wipes first, and the 120-second sleep keeps every backbone silent
until all three are wiped. Because the wipe config already carries the new
image and command, a backbone that starts before you restore it simply boots
the new node on empty storage.

Once all three have logged their start, apply the restore configs so a later
restart cannot wipe again:

```bash
fly machine update <machine id> -a <app> --machine-config /tmp/relaunch/<app>.restore.json --yes
```

## 6. Read replica and follower

These are built from the repository by `fly deploy`. Deploy both from the
relaunch commit, naming the Dockerfile on the command line so the path is
resolved from the repository root:

```bash
fly deploy -c deploy/read-replica/fly.toml --dockerfile deploy/read-replica/Dockerfile .
fly deploy -c deploy/testnet-follower/fly.toml --dockerfile deploy/testnet-follower/Dockerfile .
```

The new node refuses storage from another Nexus genesis ("wipe required")
and crash-loops until wiped; it never serves the old chain. The deploy also
drops the follower's retired env (`CHILD_PATHS`, `PUBLIC_READ_URLS`) and its
`4101`/`4201`/`8082` services, and the follower now writes the one-process
`lattice.json` from `HOSTED_CHAINS`.

Then wipe each one the same way: capture the deployed config, wrap its
entrypoint, start it, confirm it booted fresh, and restore `init` to `{}`:

```bash
fly machines list -a lattice-mainnet-read --json | jq '.[0].config' > /tmp/relaunch/lattice-mainnet-read.deployed.json
jq '.init = {entrypoint: ["/bin/sh", "-c",
      "rm -rf /data/chains && sleep 120 && exec \"$@\"",
      "sh", "/usr/local/bin/read-replica-entrypoint"]}' \
  /tmp/relaunch/lattice-mainnet-read.deployed.json > /tmp/relaunch/lattice-mainnet-read.wipe.json
jq '.init = {}' /tmp/relaunch/lattice-mainnet-read.deployed.json > /tmp/relaunch/lattice-mainnet-read.restore.json
```

The follower is identical with `lattice-mainnet-testnet` and
`/usr/local/bin/testnet-follower-entrypoint`. Its identity is
`/data/identity/Nexus.key`; leave the old per-child key files alone. Neither
app auto-starts: after a `--machine-config` update, `fly machine start` it
and confirm it is running before restoring. A machine that stays stopped
keeps its old volume.

With no child chains deployed on the new Nexus, the follower's
`Nexus/testnet` and `Nexus/testnet/swap` levels report `awaitingGenesis`.
That is expected.

## 7. Verify height 0 and one genesis everywhere

Every host must report height 0 and the genesis CID recorded in step 1:

```bash
for host in lattice-mainnet-iad lattice-mainnet-ams lattice-mainnet-sjc \
            lattice-mainnet-read lattice-mainnet-testnet; do
  curl -s "https://$host.fly.dev/health" | jq -c '{height, nexusGenesisCID, tipCID}'
done
```

Do not mine until all five agree. A host still on the old chain shows a
different `nexusGenesisCID`, or does not answer.

## 8. Mac node

Rebuild the binaries from the relaunch commit in debug (Swift 6.3 `-O`
miscompiles this code on macOS): `xcrun swift build`, then run `lattice`
from `.build/debug` so it finds `lattice-node` and `lattice-miner` beside
it. The old `lattice.json` uses the retired per-chain schema and must be
replaced; `lattice wipe` refuses to run until it is. Keep
`identity/Nexus.key`:

```json
{
  "listen": 4001,
  "rpc": 8080,
  "peers": [
    "139b8f3639e7c515417c63bd3a652a5c6fd4a1a2d0baed8e33ea63047995fe64@lattice-mainnet-iad.fly.dev:4001",
    "35edf67bfe3d612aeb1f0e25da9d3f0ced44dbf79d34f00c548cf9005be6eb7d@lattice-mainnet-ams.fly.dev:4001",
    "9cace839489acb30385a9f20025cb9d6365283c81dce14cadab26507065acd4e@lattice-mainnet-sjc.fly.dev:4001"
  ],
  "mine": {
    "worker": "<GPU or CPU worker path>",
    "workers": 1,
    "batchSize": 10000000000,
    "recipients": { "Nexus": "<reward address>" }
  }
}
```

```bash
lattice down --root ~/lattice-mac-node/nexus
lattice wipe --root ~/lattice-mac-node/nexus
lattice up --root ~/lattice-mac-node/nexus
lattice status --root ~/lattice-mac-node/nexus
```

`reward-batch.jsonl` and the `Nexus-testnet*.key` files are unused by this
release.

## 9. Start mining

Under ASERT there are no pacing or minimum-work knobs: leave `minWork` and
`minBlockIntervalSeconds` out of `lattice.json`, and leave
`CARRIER_PACE_SECONDS` unset on GPU hosts. Pacing at the target block time
freezes the schedule; ASERT finds the hashrate on its own.

```bash
lattice mine start --root ~/lattice-mac-node/nexus
nohup caffeinate -ims -w "$(cat ~/lattice-mac-node/nexus/run/mine.pid)" >/dev/null 2>&1 &
```

A GPU host needs `RECIPIENTS=Nexus=<address>` and, for a Nexus-only launch,
an empty `HOSTED_CHAINS`.

## 10. Verify block 1 propagates

```bash
for host in lattice-mainnet-iad lattice-mainnet-ams lattice-mainnet-sjc \
            lattice-mainnet-read lattice-mainnet-testnet; do
  curl -s "https://$host.fly.dev/health" | jq -c '{height, tipCID}'
done
```

All five must show height 1 with the same block CID within a few minutes of
the miner's `accepted` log line.

## Soak gates

The relaunch genesis is a launch candidate. It is anchored on Bitcoin only
after at least four weeks in which:

- the chain is never wiped or relaunched;
- all five hosts keep agreeing on the tip, and a fresh node cold-syncs from
  genesis to the tip without intervention;
- no host crash-loops or fails closed at boot, and a stop/restart of each
  host recovers on its own;
- ASERT holds block times near the one-hour target as hashrate changes;
- public reads and the explorer stay available.
