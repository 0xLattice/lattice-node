# Public child-chain follower: the node image + the declarative follower
# entrypoint. Pin the node image by immutable sha tag (bump on release).
FROM ghcr.io/adalinxx/lattice-node:sha-83148c4

COPY entrypoint.sh /usr/local/bin/testnet-follower-entrypoint
USER root
RUN chmod +x /usr/local/bin/testnet-follower-entrypoint

# 8081 = child public read (fly maps 443/80); 4001/4101 = Nexus/child overlays.
EXPOSE 8081 4001 4101

ENTRYPOINT ["/usr/local/bin/testnet-follower-entrypoint"]
