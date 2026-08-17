#!/bin/sh
# Public child-chain follower: one host running the parent (Nexus) and one
# child process under `lattice up --foreground` (PID 1, restarts on exit).
# The topology is declarative and rewritten every boot; identities and chain
# state persist on the /data volume (lattice-node creates missing identity
# keys itself).
#
# The child joins permissionlessly: CHILD_GENESIS_SEED (the deployer's seed
# JSON) is written once into the child's data directory; the node rebuilds
# the identical self-contained genesis from it and self-admits only after
# confirming the parent chain recorded that exact CID. The child's bounded
# public read surface (--public-read-port, enforced in code) is what makes
# the chain browsable; fly maps 443/80 to it.
set -eu

ROOT=/data
CHILD_PATH="${CHILD_PATH:?absolute child path, e.g. Nexus/testnet}"
CHILD_DIR="$ROOT/chains/$CHILD_PATH"
NEXUS_PEERS="${NEXUS_PEERS:?space-separated publicKey@host:port peers}"
EXTERNAL_HOST="${EXTERNAL_HOST:?publicly reachable host, e.g. lattice-mainnet-testnet.fly.dev}"

mkdir -p "$CHILD_DIR"

peers_json=""
for peer in $NEXUS_PEERS; do
    peers_json="$peers_json\"$peer\","
done
peers_json="${peers_json%,}"

cat > "$ROOT/lattice.json" <<EOF
{
  "chains": {
    "Nexus": {
      "listen": 4001,
      "fact": 4002,
      "rpc": 8080,
      "peers": [$peers_json],
      "externalAddress": "$EXTERNAL_HOST"
    },
    "$CHILD_PATH": {
      "listen": 4101,
      "fact": 4102,
      "rpc": 8180,
      "publicRead": 8081,
      "externalAddress": "$EXTERNAL_HOST"
    }
  }
}
EOF

if [ -n "${CHILD_GENESIS_SEED:-}" ] && [ ! -f "$CHILD_DIR/child-genesis.json" ]; then
    printf '%s' "$CHILD_GENESIS_SEED" > "$CHILD_DIR/child-genesis.json"
fi

exec lattice up --root "$ROOT" --foreground
