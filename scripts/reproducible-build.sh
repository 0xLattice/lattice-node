#!/usr/bin/env bash
# Build release binaries twice from clean, canonical Linux containers and require
# byte-identical SHA-256 outputs. This is the same check operators can run
# against a tagged source checkout before trusting a release artifact.
set -euo pipefail

cd "$(dirname "$0")/.."

PRODUCTS=(lattice-node lattice-mining-coordinator lattice-miner)
default_build_root="$PWD/.build"
if [[ "${REPRO_IN_CONTAINER:-0}" != "1" && "$(uname -s)" == "Darwin" && "$PWD" != /Users/* ]]; then
  # Docker Desktop does not always share /private/tmp mounts back to the host.
  # Keep operator runs from temporary worktrees usable by choosing a shared path.
  default_build_root="$HOME/Library/Caches/lattice-node/reproducible-builds/$(basename "$PWD")"
fi
BUILD_ROOT="${BUILD_ROOT:-$default_build_root}"
WORK_ROOT="$BUILD_ROOT/lattice-node-reproducible"
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git log -1 --format=%ct 2>/dev/null || printf '0')}"
SWIFT_IMAGE="${SWIFT_IMAGE:-swift@sha256:f5697100d3e66326314fb63a393b1dea2eb694fdcab689b03abc5b50b514ef6e}"

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{ print $1 }'
  else
    shasum -a 256 "$1" | awk '{ print $1 }'
  fi
}

build_once_in_container() {
  if [[ "$(uname -s)" != "Linux" ]]; then
    echo "inner reproducible build must run in Linux" >&2
    exit 2
  fi

  local artifact_dir="$BUILD_ROOT/release-artifacts"
  local hashes="$BUILD_ROOT/release.sha256"
  rm -rf -- "$artifact_dir"
  mkdir -p -- "$BUILD_ROOT"
  SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" scripts/build-release-binaries.sh
  cp -a .build/release-binaries "$artifact_dir"

  : > "$hashes"
  for product in "${PRODUCTS[@]}"; do
    printf '%s  %s\n' "$(sha256_file "$artifact_dir/$product")" "$product" >> "$hashes"
  done
}

run_container_build() {
  local label="$1"
  local output_dir="$WORK_ROOT/$label"
  mkdir -p "$output_dir"

  git archive --format=tar HEAD | docker run --rm --platform linux/amd64 -i \
    -e SOURCE_DATE_EPOCH="$SOURCE_DATE_EPOCH" \
    -e REPRO_IN_CONTAINER=1 \
    -e BUILD_ROOT=/workspace/build \
    -v "$output_dir:/out" \
    "$SWIFT_IMAGE" bash -lc '
      set -euo pipefail
      mkdir -p /workspace/lattice-node
      tar -xf - -C /workspace/lattice-node
      cd /workspace/lattice-node
      LATTICE_RELEASE_CONTAINER=1 bash scripts/install-linux-build-dependencies.sh
      scripts/reproducible-build.sh
      cp /workspace/build/release.sha256 /out/sha256
      cp -a /workspace/build/release-artifacts /out/artifacts
    '

  cp "$output_dir/sha256" "$WORK_ROOT/$label.sha256"
}

if [[ "${REPRO_IN_CONTAINER:-0}" == "1" ]]; then
  build_once_in_container
  cat "$BUILD_ROOT/release.sha256"
  exit 0
fi

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required for reproducible release verification" >&2
  exit 2
fi

if ! git diff --quiet HEAD -- || ! git diff --cached --quiet --; then
  echo "warning: reproducible build uses committed HEAD; uncommitted changes are ignored" >&2
fi

rm -rf -- "$WORK_ROOT"
mkdir -p -- "$WORK_ROOT"

run_container_build first
run_container_build second

if ! diff -u "$WORK_ROOT/first.sha256" "$WORK_ROOT/second.sha256"; then
  echo "release binaries are not reproducible" >&2
  exit 1
fi

cat "$WORK_ROOT/first.sha256"
