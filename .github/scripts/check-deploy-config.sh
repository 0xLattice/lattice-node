#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"

sh -n deploy/entrypoint.sh

! grep -R -E 'sha-21c9f0e|lattice-miner\.service|Nexus-v3' \
    deploy --exclude='check-deploy-config.sh'
