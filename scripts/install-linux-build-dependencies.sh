#!/usr/bin/env bash
set -euo pipefail

if [[ "${LATTICE_RELEASE_CONTAINER:-}" != "1" \
    || ( ! -f /.dockerenv && ! -f /run/.containerenv ) ]]; then
  echo "Linux build dependencies may only be installed in the release container" >&2
  exit 2
fi

readonly apt_snapshot=20260702T024019Z

rm -rf /var/lib/apt/lists/*
printf '%s\n' \
  "deb https://snapshot.ubuntu.com/ubuntu/${apt_snapshot} jammy main" \
  "deb https://snapshot.ubuntu.com/ubuntu/${apt_snapshot} jammy-updates main" \
  "deb https://snapshot.ubuntu.com/ubuntu/${apt_snapshot} jammy-security main" \
  > /etc/apt/sources.list

apt-get update
apt-get install -y --no-install-recommends libsqlite3-dev jq curl
