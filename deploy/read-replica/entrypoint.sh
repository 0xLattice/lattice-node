#!/bin/sh
# Read-replica entrypoint: the Lattice node runs as the FOREGROUND/main process
# (like every other node deployment — best signal handling and async-runtime
# behavior); nginx runs backgrounded as the public allowlist proxy in front of
# the node's loopback RPC. The node stays loopback-only; nginx exposes only the
# bounded GET read routes.
set -e

# Start nginx first (daemon mode → backgrounds itself). It 502s until the node's
# loopback RPC is up; fly's health check tolerates that during the grace period.
nginx -c /etc/nginx/nginx.conf

exec /usr/local/bin/lattice-node \
    --chain-path Nexus \
    --data-directory /data/chains/Nexus-v2 \
    --identity-key /data/identity/nexus.key \
    --listen-port 4001 \
    --fact-listen-port 4002 \
    --rpc-port 8080 \
    --overlay-max-connections-per-netgroup 256 \
    --peer 139b8f3639e7c515417c63bd3a652a5c6fd4a1a2d0baed8e33ea63047995fe64@lattice-mainnet-iad.fly.dev:4001 \
    --peer 35edf67bfe3d612aeb1f0e25da9d3f0ced44dbf79d34f00c548cf9005be6eb7d@lattice-mainnet-ams.fly.dev:4001 \
    --peer 9cace839489acb30385a9f20025cb9d6365283c81dce14cadab26507065acd4e@lattice-mainnet-sjc.fly.dev:4001 \
    --peer 57f80deb3b00da1b14b630638a4d0307be98126ec1d550476e4889087bb22d0f@lattice-mainnet-testnet.fly.dev:4001
