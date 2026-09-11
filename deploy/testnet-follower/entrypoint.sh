#!/bin/sh
# Public chain follower: one host running Nexus plus a descending path of
# child processes under `lattice up --foreground` (PID 1, restarts on exit).
# The topology is declarative and rewritten every boot; identities and chain
# state persist on the /data volume (lattice-node creates missing identity
# keys itself).
#
# CHILD_PATHS is that descending path, outermost first, e.g.
# "Nexus/testnet Nexus/testnet/swap". Each chain needs its immediate parent
# listed before it, because `lattice up` derives a child's parent link from
# the local parent in the same file. Ports are assigned by position, so
# appending a deeper level never renumbers the ones above it.
#
# Each child joins permissionlessly: CHILD_GENESIS_SEED_<i> (the deployer's
# seed JSON for the i-th path) is written once into that child's data
# directory; the node rebuilds the identical self-contained genesis from it
# and self-admits only after confirming its parent chain recorded that exact
# CID. The bounded public read surface (--public-read-port, enforced in code)
# is what makes a chain browsable; fly maps a TLS port to each one.
set -eu

ROOT=/data
NEXUS_PEERS="${NEXUS_PEERS:?space-separated publicKey@host:port peers}"
# No apostrophe in this message: inside `${VAR:?word}` it opens a quote
# context and the script stops parsing.
EXTERNAL_HOST="${EXTERNAL_HOST:?publicly reachable IP literal (Ivy rejects hostnames), e.g. the dedicated IPv4 of this app}"
# A single CHILD_PATH is just the one-level case of CHILD_PATHS.
CHILD_PATHS="${CHILD_PATHS:-${CHILD_PATH:?absolute child path(s), outermost first}}"
# Browsable base URLs, aligned by position with CHILD_PATHS, or empty for
# none at all. Use "-" to give one chain no URL while a later one has one:
# the alignment is positional, so a short list would silently hand a chain
# its neighbour's self-description and propagate that through the parent
# rendezvous to the explorer with no error anywhere.
PUBLIC_READ_URLS="${PUBLIC_READ_URLS:-${PUBLIC_READ_URL:-}}"

count_words() { echo $#; }
if [ -n "$PUBLIC_READ_URLS" ]; then
    path_count=$(count_words $CHILD_PATHS)
    url_count=$(count_words $PUBLIC_READ_URLS)
    if [ "$path_count" -ne "$url_count" ]; then
        echo "PUBLIC_READ_URLS has $url_count entries for $path_count chains;" \
             "they are matched by position, so give one per chain (\"-\" for none)" >&2
        exit 1
    fi
fi

peers_json=""
for peer in $NEXUS_PEERS; do
    peers_json="$peers_json\"$peer\","
done
peers_json="${peers_json%,}"

chains_json="    \"Nexus\": {
      \"listen\": 4001,
      \"fact\": 4002,
      \"rpc\": 8080,
      \"peers\": [$peers_json],
      \"externalAddress\": \"$EXTERNAL_HOST\"
    }"

index=0
for child_path in $CHILD_PATHS; do
    listen=$((4101 + index * 100))
    fact=$((4102 + index * 100))
    rpc=$((8180 + index))
    public_read=$((8081 + index))

    # The i-th word of PUBLIC_READ_URLS, if there is one.
    read_url=""
    url_index=0
    for candidate in $PUBLIC_READ_URLS; do
        if [ "$url_index" -eq "$index" ]; then
            read_url="$candidate"
            break
        fi
        url_index=$((url_index + 1))
    done
    read_url_json=""
    if [ -n "$read_url" ] && [ "$read_url" != "-" ]; then
        read_url_json=",
      \"publicReadUrl\": \"$read_url\""
    fi

    chains_json="$chains_json,
    \"$child_path\": {
      \"listen\": $listen,
      \"fact\": $fact,
      \"rpc\": $rpc,
      \"publicRead\": $public_read,
      \"externalAddress\": \"$EXTERNAL_HOST\"$read_url_json
    }"

    child_dir="$ROOT/chains/$child_path"
    mkdir -p "$child_dir"
    # `printenv` reads the value without re-parsing it; a seed is JSON full
    # of quotes, so `eval`-based indirection would mangle or execute it.
    seed=$(printenv "CHILD_GENESIS_SEED_$index" || true)
    # The unsuffixed seed names the first path, as it did when there was one.
    if [ -z "$seed" ] && [ "$index" -eq 0 ]; then
        seed="${CHILD_GENESIS_SEED:-}"
    fi
    if [ -n "$seed" ] && [ ! -f "$child_dir/child-genesis.json" ]; then
        printf '%s' "$seed" > "$child_dir/child-genesis.json"
    fi

    index=$((index + 1))
done

cat > "$ROOT/lattice.json" <<EOF
{
  "chains": {
$chains_json
  }
}
EOF

exec lattice up --root "$ROOT" --foreground
