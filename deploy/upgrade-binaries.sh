#!/bin/sh
# Upgrade a host's lattice binaries in place from a released ghcr image,
# without needing docker: crane exports the image filesystem and the
# binaries are installed from it. For bare-metal / rented-GPU hosts (e.g.
# the vast.ai miner box) that run the binaries directly.
#
#   usage: upgrade-binaries.sh <image-tag>        e.g. upgrade-binaries.sh sha-888bab7
#
# Stop the node and miner first (`lattice mine stop`, `lattice down`);
# restart them after (`lattice up`, `lattice mine start`).
set -eu

TAG="${1:?usage: upgrade-binaries.sh <image-tag, e.g. sha-888bab7>}"
IMAGE="ghcr.io/adalinxx/lattice-node:${TAG}"
BIN_DIR="${BIN_DIR:-/usr/local/bin}"
BINARIES="lattice-node lattice lattice-mining-coordinator lattice-miner lattice-rewards"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

if command -v crane >/dev/null 2>&1; then
    CRANE="$(command -v crane)"
else
    case "$(uname -m)" in
        x86_64) CRANE_ARCH="x86_64" ;;
        aarch64) CRANE_ARCH="arm64" ;;
        *) echo "unsupported arch $(uname -m)" >&2; exit 1 ;;
    esac
    curl -fsSL "https://github.com/google/go-containerregistry/releases/latest/download/go-containerregistry_Linux_${CRANE_ARCH}.tar.gz" \
        | tar -xz -C "$WORK" crane
    CRANE="$WORK/crane"
fi

"$CRANE" export "$IMAGE" - \
    | tar -x -C "$WORK" $(for b in $BINARIES; do printf "usr/local/bin/%s " "$b"; done)

for b in $BINARIES; do
    install -m 0755 "$WORK/usr/local/bin/$b" "$BIN_DIR/$b"
done

"$BIN_DIR/lattice-node" --help >/dev/null
echo "installed from $IMAGE:"
for b in $BINARIES; do ls -l "$BIN_DIR/$b"; done
