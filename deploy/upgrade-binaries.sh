#!/bin/sh
# Upgrade a host's lattice binaries in place from a released ghcr image,
# without needing docker: crane exports the image filesystem and the
# binaries are installed from it. For bare-metal / rented-GPU hosts (e.g.
# the vast.ai miner box) that run the binaries directly.
#
#   usage: upgrade-binaries.sh <image-digest>
#   example: upgrade-binaries.sh sha256:<64 lowercase hex digits>
#
# Stop the node and miner first (`lattice mine stop`, `lattice down`);
# restart them after (`lattice up`, `lattice mine start`).
#
# This swaps binaries only — it never touches the data directory and cannot
# decide whether the target release is storage-compatible. Before an upgrade,
# stop the processes and snapshot lattice.json, identity, specs, and the whole
# chains/Nexus directory together. For an incompatible schema, consensus, or
# wire cutover, follow the release notes and run `lattice wipe` before restart;
# there is no in-place migration or mixed-database recovery.
set -eu

DIGEST="${1:?usage: upgrade-binaries.sh <sha256:image-digest>}"
if ! printf '%s\n' "$DIGEST" | grep -Eq '^sha256:[0-9a-f]{64}$'; then
    echo "image reference must be an immutable sha256 digest" >&2
    exit 2
fi
IMAGE="ghcr.io/adalinxx/lattice-node@${DIGEST}"
BIN_DIR="${BIN_DIR:-/usr/local/bin}"
BINARIES="lattice-node lattice lattice-mining-coordinator lattice-miner"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

CRANE="$(command -v crane || true)"
if [ -z "$CRANE" ]; then
    echo "crane is required; install and verify it separately before upgrading" >&2
    exit 1
fi

"$CRANE" export "$IMAGE" - \
    | tar -x -C "$WORK" $(for b in $BINARIES; do printf "usr/local/bin/%s " "$b"; done)

for b in $BINARIES; do
    install -m 0755 "$WORK/usr/local/bin/$b" "$BIN_DIR/$b"
done

"$BIN_DIR/lattice-node" --help >/dev/null
echo "installed from $IMAGE:"
for b in $BINARIES; do ls -l "$BIN_DIR/$b"; done
