#!/bin/sh
# One process follows Nexus and every configured hosted child level. The
# topology is rewritten on boot; identity and the whole storage tree persist.
set -eu

ROOT="${LATTICE_ROOT:-/data}"
NEXUS_PEERS="${NEXUS_PEERS:?space-separated publicKey@host:port peers}"
EXTERNAL_HOST="${EXTERNAL_HOST:?publicly reachable IP literal}"
HOSTED_CHAINS="${HOSTED_CHAINS:?space-separated Nexus-rooted child paths, parent first}"
# Optional: this host's public read URL, declared for every hosted level so a
# node hosting a parent can list the child at /api/chain/endpoints.
PUBLIC_READ_URL="${PUBLIC_READ_URL:-}"

mkdir -p "$ROOT"

peers_json=""
for peer in $NEXUS_PEERS; do
    peers_json="$peers_json\"$peer\","
done
peers_json="${peers_json%,}"

chains_json=""
for chain in $HOSTED_CHAINS; do
    chains_json="$chains_json\"$chain\","
done
chains_json="${chains_json%,}"

read_url_json=""
if [ -n "$PUBLIC_READ_URL" ]; then
    read_url_json="
  \"publicReadURL\": \"$PUBLIC_READ_URL\","
fi

cat > "$ROOT/lattice.json" <<EOF
{
  "externalAddress": "$EXTERNAL_HOST",
  "hostedChains": [$chains_json],
  "listen": 4001,
  "peers": [$peers_json],
  "publicRead": 8081,
  "publicReadExpensiveRate": 0,
  "publicReadRate": 0,$read_url_json
  "publicSubmit": true,
  "rpc": 8080
}
EOF

# The volume may hold files written by an earlier root-run image; hand it to
# the node's user, then drop root for the node itself.
chown -R lattice:lattice "$ROOT"
exec setpriv --reuid=lattice --regid=lattice --init-groups \
    lattice up --root "$ROOT" --foreground
