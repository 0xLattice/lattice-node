#!/usr/bin/env bash
# Build and normalize the binaries that are shipped in release archives.
set -euo pipefail

cd "$(dirname "$0")/.."

PRODUCTS=(lattice-node lattice-mining-coordinator lattice-miner)
BUILD_ROOT="${RELEASE_BUILD_ROOT:-$PWD/.build}"
ARTIFACT_ROOT="${RELEASE_ARTIFACT_ROOT:-$PWD/.build}"
if [[ "${SKIP_SWIFT_BUILD:-0}" == "1" ]]; then
    BUILD_PATH="${RELEASE_PREBUILT_PATH:-$PWD/.build}"
else
    BUILD_PATH="$BUILD_ROOT/release-canonical"
fi
ARTIFACT_DIR="$ARTIFACT_ROOT/release-binaries"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct 2>/dev/null || printf '0')}"

export SOURCE_DATE_EPOCH
export ZERO_AR_DATE=1
export TZ=UTC
export LANG=C
export LC_ALL=C

normalize_release_artifact() {
    local artifact="$1"

    if [[ "$(uname -s)" == "Darwin" ]]; then
        strip -S "$artifact"
    else
        strip --strip-debug "$artifact"
        # Swift 6.1 emits this non-runtime section with a build-specific hash.
        command -v objcopy >/dev/null 2>&1 \
            && objcopy --remove-section=.swift_modhash "$artifact"
    fi
}

if [[ "${SKIP_SWIFT_BUILD:-0}" != "1" ]]; then
    rm -rf -- "$BUILD_PATH"
fi
rm -rf -- "$ARTIFACT_DIR"
mkdir -p -- "$ARTIFACT_DIR"

build_flags=(
    --disable-index-store
    -Xswiftc -file-prefix-map
    -Xswiftc "$PWD=."
    -Xswiftc -debug-prefix-map
    -Xswiftc "$PWD=."
    -Xswiftc -prefix-serialized-debugging-options
    -Xcc "-ffile-prefix-map=$PWD=."
    -Xcxx "-ffile-prefix-map=$PWD=."
)
if [[ "$(uname -s)" == "Linux" ]]; then
    # Release archives do not bundle a Swift toolchain. Link its runtime into
    # each executable so the archive runs on a plain Linux host.
    build_flags+=(--static-swift-stdlib -Xlinker --build-id=none)
fi

if [[ "${SKIP_SWIFT_BUILD:-0}" != "1" ]]; then
    swift package resolve --build-path "$BUILD_PATH"
    swift build -c release --build-path "$BUILD_PATH" "${build_flags[@]}"
fi

for product in "${PRODUCTS[@]}"; do
    binary="$BUILD_PATH/release/$product"
    [[ -x "$binary" ]] || {
        echo "missing release binary: $binary" >&2
        exit 1
    }
    cp "$binary" "$ARTIFACT_DIR/$product"
    normalize_release_artifact "$ARTIFACT_DIR/$product"
done
