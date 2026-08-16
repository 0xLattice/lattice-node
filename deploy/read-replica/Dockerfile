# Read-only public replica: the Lattice node image + an nginx allowlist proxy.
# Pin the node image by immutable sha tag (bump on each read-RPC release).
FROM ghcr.io/adalinxx/lattice-node:sha-dd02314

USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends nginx \
    && rm -rf /var/lib/apt/lists/*

COPY nginx.conf /etc/nginx/nginx.conf
COPY entrypoint.sh /usr/local/bin/read-replica-entrypoint
RUN chmod +x /usr/local/bin/read-replica-entrypoint

# 8081 = public nginx (fly maps 443/80 -> 8081); 4001/4002 = node P2P/fact plane.
EXPOSE 8081 4001 4002

ENTRYPOINT ["/usr/local/bin/read-replica-entrypoint"]
