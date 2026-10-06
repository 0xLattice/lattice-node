#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"

for script in deploy/entrypoint.sh deploy/read-replica/entrypoint.sh \
    deploy/upgrade-binaries.sh; do
    sh -n "$script"
done

! grep -R -E 'sha-21c9f0e|lattice-miner\.service|Nexus-v3' \
    deploy --exclude='check-deploy-config.sh'
grep -q 'EnvironmentFile=/etc/lattice/mining.env' \
    deploy/lattice-mining-coordinator.service
grep -q '\$RECIPIENT_ARGS' deploy/lattice-mining-coordinator.service
