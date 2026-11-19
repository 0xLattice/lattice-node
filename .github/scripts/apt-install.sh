#!/usr/bin/env bash
# apt-install.sh <package>...: installs packages in a CI container, and does
# not depend on one Ubuntu mirror answering.
#
# `apt-get update` exits 0 when a mirror cannot be reached: it warns, keeps
# no index, and the install then fails with "Unable to locate package"
# (exit 100) after ten minutes of connection attempts. Here an update that
# fetched no index is a failure, each connection is given 20 seconds, and
# the next mirror is tried.
set -euo pipefail

if [[ $# -eq 0 ]]; then
    echo "usage: apt-install.sh <package>..." >&2
    exit 2
fi

options=(
    -o Acquire::Retries=2
    -o Acquire::http::Timeout=20
    -o Acquire::https::Timeout=20
    -o APT::Update::Error-Mode=any
)
mirrors=(
    ""                                     # the image's own sources
    "http://azure.archive.ubuntu.com/ubuntu"
    "http://mirrors.edge.kernel.org/ubuntu"
)
sources=/etc/apt/sources.list
[[ -f "$sources" ]] && cp "$sources" "$sources.image"

for mirror in "${mirrors[@]}"; do
    if [[ -n "$mirror" ]]; then
        [[ -f "$sources.image" ]] || break
        echo "apt-install: trying $mirror"
        sed -E "s#https?://(archive|security)\.ubuntu\.com/ubuntu/?#$mirror#g" "$sources.image" > "$sources"
    fi
    if apt-get "${options[@]}" update \
        && apt-get "${options[@]}" install -y --no-install-recommends "$@"; then
        exit 0
    fi
done

echo "apt-install: no mirror answered" >&2
exit 1
