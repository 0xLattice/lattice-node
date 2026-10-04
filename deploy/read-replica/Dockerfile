# Build the reviewed checkout directly, then add the public read allowlist.
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
    ca-certificates curl libatomic1 libcurl4 libsqlite3-0 libxml2 nginx \
    && rm -rf /var/lib/apt/lists/*
COPY --from=builder /build/.build/release/lattice-node /usr/local/bin/lattice-node
COPY deploy/read-replica/nginx.conf /etc/nginx/nginx.conf
COPY deploy/read-replica/entrypoint.sh /usr/local/bin/read-replica-entrypoint
RUN chmod +x /usr/local/bin/read-replica-entrypoint \
    && useradd -m -s /bin/bash lattice \
    && install -d -o lattice -g lattice /data

# 8081 = public nginx; 4001 = the node's tree overlay.
EXPOSE 8081 4001
ENTRYPOINT ["/usr/local/bin/read-replica-entrypoint"]
