#!/usr/bin/env bash
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$repo_root"

for script in deploy/entrypoint.sh deploy/read-replica/entrypoint.sh \
    deploy/testnet-follower/entrypoint.sh deploy/upgrade-binaries.sh; do
    sh -n "$script"
done

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/bin" "$tmp_dir/root"
printf '%s\n' '#!/bin/sh' 'printf "%s\\n" "$*" > "$LATTICE_TEST_ARGS"' \
    > "$tmp_dir/bin/lattice"
chmod +x "$tmp_dir/bin/lattice"
# The entrypoint runs as root in the image; on the runner, owning the volume
# is a no-op and dropping privileges just runs the wrapped command.
printf '%s\n' '#!/bin/sh' 'exit 0' > "$tmp_dir/bin/chown"
printf '%s\n' '#!/bin/sh' 'while [ "${1#--}" != "$1" ]; do shift; done' 'exec "$@"' \
    > "$tmp_dir/bin/setpriv"
chmod +x "$tmp_dir/bin/chown" "$tmp_dir/bin/setpriv"

PATH="$tmp_dir/bin:$PATH" \
LATTICE_ROOT="$tmp_dir/root" \
LATTICE_TEST_ARGS="$tmp_dir/args" \
NEXUS_PEERS="key-a@example.test:4001 key-b@example.test:4002" \
EXTERNAL_HOST="192.0.2.10" \
HOSTED_CHAINS="Nexus/Alpha Nexus/Alpha/Beta" \
    sh deploy/testnet-follower/entrypoint.sh

jq -e '
  .listen == 4001 and .rpc == 8080 and .publicRead == 8081 and
  .externalAddress == "192.0.2.10" and
  .peers == ["key-a@example.test:4001", "key-b@example.test:4002"] and
  .hostedChains == ["Nexus/Alpha", "Nexus/Alpha/Beta"] and
  (has("chains") | not)
' "$tmp_dir/root/lattice.json" >/dev/null

expected="up --root $tmp_dir/root --foreground"
[[ "$(cat "$tmp_dir/args")" == "$expected" ]]

! grep -R -E 'sha-21c9f0e|lattice-miner\.service|Nexus-v3' \
    deploy --exclude='check-deploy-config.sh'
grep -q 'EnvironmentFile=/etc/lattice/mining.env' \
    deploy/lattice-mining-coordinator.service
grep -q '\$RECIPIENT_ARGS' deploy/lattice-mining-coordinator.service
