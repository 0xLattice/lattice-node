#!/bin/sh
# Read-replica entrypoint: the Lattice node runs as the FOREGROUND/main process
# (like every other node deployment — best signal handling and async-runtime
# behavior); nginx runs backgrounded as the public allowlist proxy in front of
# the node's public read listener (8082: the unauthenticated read routes only;
# the cookie-protected operator RPC on 8080 stays unexposed). fly publishes only
# nginx's 8081. Rate limiting is nginx's job here, so the node's own public
# read limits are off (every request arrives from nginx's one address). 8082
# binds 0.0.0.0 but is unthrottled public data reachable only through nginx:
# fly publishes nothing but 4001 and 8081 (fly.toml).
set -e

# Start nginx first (daemon mode → backgrounds itself). It 502s until the node's
# loopback RPC is up; fly's health check tolerates that during the grace period.
nginx -c /etc/nginx/nginx.conf

# The volume may hold files written by an earlier root-run image; hand it to
# the node's user, then drop root for the node itself.
chown -R lattice:lattice /data
exec setpriv --reuid=lattice --regid=lattice --init-groups \
    /usr/local/bin/lattice-node \
    --data-directory /data/chains/Nexus \
    --identity-key /data/identity/nexus.key \
    --listen-port 4001 \
    --rpc-port 8080 \
    --public-read-port 8082 \
    --public-read-rate 0 \
    --public-read-expensive-rate 0 \
    --public-read-max-rate 0 \
    --overlay-max-connections-per-netgroup 256 \
    --peer 139b8f3639e7c515417c63bd3a652a5c6fd4a1a2d0baed8e33ea63047995fe64@lattice-mainnet-iad.fly.dev:4001 \
    --peer 35edf67bfe3d612aeb1f0e25da9d3f0ced44dbf79d34f00c548cf9005be6eb7d@lattice-mainnet-ams.fly.dev:4001 \
    --peer 9cace839489acb30385a9f20025cb9d6365283c81dce14cadab26507065acd4e@lattice-mainnet-sjc.fly.dev:4001 \
    --peer 57f80deb3b00da1b14b630638a4d0307be98126ec1d550476e4889087bb22d0f@lattice-mainnet-testnet.fly.dev:4001
