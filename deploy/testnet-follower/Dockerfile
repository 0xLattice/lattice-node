# Public child-chain follower: the node image + the declarative follower
# entrypoint. Pin the node image by immutable sha tag (bump on release).
FROM ghcr.io/adalinxx/lattice-node:sha-e2d20e2

COPY entrypoint.sh /usr/local/bin/testnet-follower-entrypoint
USER root
RUN chmod +x /usr/local/bin/testnet-follower-entrypoint

# Public read: 8081 (child, fly maps 443/80), 8082 (grandchild, fly maps 8443).
# Overlays: 4001 Nexus, 4101 child, 4201 grandchild.
EXPOSE 8081 8082 4001 4101 4201

ENTRYPOINT ["/usr/local/bin/testnet-follower-entrypoint"]
