# Stage 1: Build
FROM swift:6.1-jammy AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    libsqlite3-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /build
COPY Package.swift Package.resolved ./
RUN swift package resolve

COPY Sources Sources
COPY Tests Tests
RUN swift build -c release --static-swift-stdlib

# Stage 2: Runtime
FROM ubuntu:22.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    libatomic1 \
    libcurl4 \
    libsqlite3-0 \
    libxml2 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /build/.build/release/lattice-node /usr/local/bin/lattice-node
COPY --from=builder /build/.build/release/lattice-mining-coordinator /usr/local/bin/lattice-mining-coordinator
COPY --from=builder /build/.build/release/lattice-miner /usr/local/bin/lattice-miner
COPY deploy/entrypoint.sh /usr/local/bin/lattice-entrypoint
RUN chmod +x /usr/local/bin/lattice-entrypoint

RUN useradd -m -s /bin/bash lattice \
    && install -d -o lattice -g lattice /home/lattice/.lattice
USER lattice

VOLUME /home/lattice/.lattice
EXPOSE 4001
EXPOSE 4002
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD curl --fail --silent http://127.0.0.1:8080/health >/dev/null || exit 1

ENTRYPOINT ["/usr/local/bin/lattice-entrypoint"]
CMD ["lattice-node", "--chain-path", "Nexus", "--data-directory", "/home/lattice/.lattice/chains/Nexus"]
