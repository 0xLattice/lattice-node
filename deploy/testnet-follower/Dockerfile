# Build the reviewed checkout directly; deployment never inherits a stale node
# image tag whose source differs from this repository revision.
FROM swift:6.1-jammy AS builder

RUN apt-get update && apt-get install -y --no-install-recommends libsqlite3-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /build
COPY Package.swift Package.resolved ./
RUN swift package resolve
COPY Sources Sources
COPY Tests Tests
RUN swift build -c release --static-swift-stdlib

FROM ubuntu:22.04
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl libatomic1 libcurl4 libsqlite3-0 libxml2 \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /build/.build/release/lattice-node /usr/local/bin/lattice-node
COPY --from=builder /build/.build/release/lattice-mining-coordinator /usr/local/bin/lattice-mining-coordinator
COPY --from=builder /build/.build/release/lattice-miner /usr/local/bin/lattice-miner
COPY --from=builder /build/.build/release/lattice /usr/local/bin/lattice
COPY deploy/testnet-follower/entrypoint.sh /usr/local/bin/testnet-follower-entrypoint
RUN chmod +x /usr/local/bin/testnet-follower-entrypoint \
    && useradd -m -s /bin/bash lattice \
    && install -d -o lattice -g lattice /data

# One overlay and one public read listener serve the complete hosted tree.
EXPOSE 4001 8081
ENTRYPOINT ["/usr/local/bin/testnet-follower-entrypoint"]
